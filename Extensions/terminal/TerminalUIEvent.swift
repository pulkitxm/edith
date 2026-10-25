import EdithExtensionSupport
import Foundation
import GhosttyTerminal

struct TerminalUIEvent: Codable {
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

struct TerminalUIEventTracker {
    let presentationID: UUID
    private(set) var sequence: UInt64?

    mutating func accept(_ data: Data) throws -> TerminalUIEvent {
        guard data.count <= 1_024 else { throw ExtensionPeerError.invalidRequest }
        let event = try JSONDecoder().decode(TerminalUIEvent.self, from: data)
        guard event.version == 1, event.presentationID == presentationID,
            sequence.map({ event.sequence > $0 }) ?? true
        else {
            throw ExtensionPeerError.invalidRequest
        }
        sequence = event.sequence
        return event
    }
}

extension TerminalTabsModel {
    func applyUIEvent(_ event: TerminalUIEvent) -> Bool {
        applyHostWindowState(active: event.active, key: event.key)
        guard let action = event.action else { return true }
        if action == .windowClosed { windowClosed(); return true }
        guard event.active, event.key, event.visible else { return false }
        if [.fontZoomIn, .fontZoomOut, .fontZoomReset].contains(action),
            selectedTab?.holder.ghosttyView?.hasInputFocus != true
        {
            return false
        }
        switch action {
        case .fontZoomIn: return selectedTab?.holder.ghosttyView?.fontZoom(.increase) ?? false
        case .fontZoomOut: return selectedTab?.holder.ghosttyView?.fontZoom(.decrease) ?? false
        case .fontZoomReset: return selectedTab?.holder.ghosttyView?.fontZoom(.reset) ?? false
        case .newTab: addTab()
        case .closeTab: if let selected { closeTab(selected) }
        case .nextTab: selectNext(backwards: false)
        case .previousTab: selectNext(backwards: true)
        case .windowClosed: break
        }
        return true
    }
}
