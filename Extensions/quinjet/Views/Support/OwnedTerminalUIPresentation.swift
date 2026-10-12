import EdithExtensionSupport
import Foundation
import GhosttyTerminal

struct OwnedTerminalUIEvent: Codable {
    enum Action: String, Codable {
        case fontZoomIn, fontZoomOut, fontZoomReset
        case newTab, closeTab, nextTab, previousTab, windowClosed
    }
    let version: Int
    let presentationID: UUID
    let sequence: UInt64
    let active: Bool
    let key: Bool
    let visible: Bool
    let action: Action?
}

@MainActor final class OwnedTerminalUIPresentation {
    let id: UUID
    private let holders: @MainActor () -> [TerminalSessionHolder]
    private let action: @MainActor (OwnedTerminalUIEvent.Action) -> Bool
    private let paneAction: @MainActor (GhosttyPaneAction, TerminalSessionHolder) -> Void
    private let close: @MainActor () -> Void
    private var event: OwnedTerminalUIEvent?
    private var stopped = false

    init(
        id: UUID, holders: @escaping @MainActor () -> [TerminalSessionHolder],
        action: @escaping @MainActor (OwnedTerminalUIEvent.Action) -> Bool,
        paneAction: @escaping @MainActor (GhosttyPaneAction, TerminalSessionHolder) -> Void,
        close: @escaping @MainActor () -> Void
    ) {
        self.id = id; self.holders = holders; self.action = action
        self.paneAction = paneAction; self.close = close
    }

    func execute(_ input: NSDictionary) -> NSDictionary {
        guard !stopped, input["presentationID"] as? String == id.uuidString else {
            return ["ok": false]
        }
        if input["operation"] as? String == "terminalUIStatus", input.count == 2 {
            return [
                "ok": true, "presentationID": id.uuidString,
                "focused": holders().contains { $0.ghosttyView?.hasInputFocus == true },
            ]
        }
        guard input["operation"] as? String == "terminalUI", input.count == 3,
            let data = input["payload"] as? Data, data.count <= 1024,
            let next = try? JSONDecoder().decode(OwnedTerminalUIEvent.self, from: data),
            next.version == 1, next.presentationID == id,
            event.map({ next.sequence > $0.sequence }) ?? true
        else { return ["ok": false] }
        event = next
        refresh()
        guard let operation = next.action else { return ["ok": true] }
        if operation == .windowClosed { invalidate(); close(); return ["ok": true] }
        guard next.active, next.key, next.visible else { return ["ok": false] }
        let focused = holders().compactMap(\.ghosttyView).filter(\.hasInputFocus)
        guard focused.count == 1 else { return ["ok": false] }
        switch operation {
        case .fontZoomIn: return ["ok": focused[0].fontZoom(.increase)]
        case .fontZoomOut: return ["ok": focused[0].fontZoom(.decrease)]
        case .fontZoomReset: return ["ok": focused[0].fontZoom(.reset)]
        default: return ["ok": action(operation)]
        }
    }

    func refresh() {
        guard !stopped else { return }
        for holder in holders() {
            holder.setHostWindowState(
                active: event?.active ?? false, key: event?.key ?? false,
                visible: event?.visible ?? true)
            holder.nativePaneAction = { [weak self, weak holder] value in
                guard let self, let holder, !self.stopped, let event = self.event,
                    event.active, event.key, event.visible,
                    self.holders().contains(where: { $0 === holder }),
                    holder.ghosttyView?.hasInputFocus == true
                else { return }
                self.paneAction(value, holder)
            }
        }
    }

    func invalidate() {
        guard !stopped else { return }
        stopped = true
        for holder in holders() {
            holder.nativePaneAction = nil
            holder.setHostWindowState(active: false, key: false, visible: false)
        }
    }
}
