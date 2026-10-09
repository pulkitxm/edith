import Foundation
import Observation

struct TerminalBroadcastPlan: Equatable, Sendable {
    let command: String

    var terminalInput: String { command + "\n" }

    static func make(command: String) -> Result<TerminalBroadcastPlan, TerminalBroadcastError> {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .failure(.emptyCommand) }
        guard normalized.utf8.count <= 4_096, !normalized.utf8.contains(0) else {
            return .failure(.invalidCommand)
        }
        return .success(TerminalBroadcastPlan(command: normalized))
    }
}

enum TerminalBroadcastError: LocalizedError, Equatable, Sendable {
    case emptyCommand
    case invalidCommand
    case noTabs

    var errorDescription: String? {
        switch self {
        case .emptyCommand: "Give a command to run."
        case .invalidCommand: "The command is too long or contains a null character."
        case .noTabs: "No terminal tabs are open."
        }
    }
}

struct TerminalBroadcastDelivery: Equatable, Sendable {
    let sent: Int
    let unavailable: Int

    var isComplete: Bool { sent > 0 && unavailable == 0 }

    var failureMessage: String? {
        if sent == 0 && unavailable == 0 { return TerminalBroadcastError.noTabs.errorDescription }
        if sent == 0 { return "No open terminal tab is running a shell." }
        if unavailable > 0 {
            return
                "Sent to \(sent) tab\(sent == 1 ? "" : "s"). \(unavailable) tab\(unavailable == 1 ? " was" : "s were") not running."
        }
        return nil
    }
}

@MainActor
@Observable
final class TerminalTabsModel {
    typealias UserCloseRequester =
        @MainActor (TerminalSessionHolder, @escaping @MainActor (Bool) -> Void) -> Void

    @MainActor struct Tab: Identifiable {
        let id: UUID
        var title: String
        let holder: TerminalSessionHolder

        var displayTitle: String { holder.currentTitle ?? title }
    }

    static let maximumTabs = 32

    private(set) var tabs: [Tab] = []
    var selected: UUID?
    var broadcast = false
    private var nextNumber = 1
    private let requestUserClose: UserCloseRequester
    private let makeHolder: @MainActor () -> TerminalSessionHolder

    init(
        requestUserClose: @escaping UserCloseRequester = { holder, completion in
            guard TerminalSettings.load().confirmClose else {
                holder.stop()
                completion(true)
                return
            }
            holder.requestUserClose(completion)
        },
        makeHolder: @escaping @MainActor () -> TerminalSessionHolder = {
            TerminalSessionHolder()
        }
    ) {
        self.requestUserClose = requestUserClose
        self.makeHolder = makeHolder
    }

    var selectedTab: Tab? { tabs.first { $0.id == selected } }

    func ensureFirstTab() {
        guard tabs.isEmpty else { return }
        addTab()
    }

    @discardableResult
    func addTab() -> Tab? {
        guard tabs.count < Self.maximumTabs else { return nil }
        let tab = Tab(id: UUID(), title: "Shell \(nextNumber)", holder: makeHolder())
        nextNumber += 1
        tabs.append(tab)
        selected = tab.id
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selected = id
    }

    func closeTab(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let holder = tabs[index].holder
        requestUserClose(holder) { [weak self, weak holder] confirmed in
            guard confirmed, let self, let holder else { return }
            self.removeTab(id, holder: holder)
        }
    }

    private func removeTab(_ id: UUID, holder: TerminalSessionHolder) {
        guard let index = tabs.firstIndex(where: { $0.id == id && $0.holder === holder }) else {
            return
        }
        holder.stop()
        tabs.remove(at: index)
        if selected == id { selected = tabs.last?.id }
    }

    func selectNext(backwards: Bool) {
        guard let selected, let index = tabs.firstIndex(where: { $0.id == selected }),
            tabs.count > 1
        else { return }
        let next =
            backwards ? (index - 1 + tabs.count) % tabs.count : (index + 1) % tabs.count
        self.selected = tabs[next].id
    }

    @discardableResult
    func sendBroadcast(
        _ plan: TerminalBroadcastPlan,
        isLive: @MainActor (TerminalSessionHolder) -> Bool = { $0.started },
        send: @MainActor (TerminalSessionHolder, String) -> Void = { $0.sendInput($1) }
    ) -> TerminalBroadcastDelivery {
        var sent = 0
        var unavailable = 0
        for tab in tabs {
            guard isLive(tab.holder) else {
                unavailable += 1
                continue
            }
            send(tab.holder, plan.terminalInput)
            sent += 1
        }
        return TerminalBroadcastDelivery(sent: sent, unavailable: unavailable)
    }

    func stopAll() {
        for tab in tabs { tab.holder.stop() }
        tabs = []
        selected = nil
        broadcast = false
    }
}
