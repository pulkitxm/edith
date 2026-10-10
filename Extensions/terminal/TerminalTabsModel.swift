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

@MainActor @Observable final class TerminalTabsModel {
    @MainActor struct Tab: Identifiable {
        let id: UUID
        let holder: TerminalSessionHolder
        var displayTitle: String { holder.currentTitle ?? holder.session.title }
    }

    static let maximumTabs = 32
    private(set) var tabs: [Tab] = []
    private(set) var selected: UUID?
    var broadcast = false
    private(set) var settings = TerminalSettings()
    private(set) var error: String?
    let client: TerminalRemoteClient
    private var stopped = false
    private var polling: Task<Void, Never>?
    private var actions: [UUID: Task<Void, Never>] = [:]
    private var didEnsureFirstTab = false
    private var preferenceRevision = 0

    init(client: TerminalRemoteClient) { self.client = client }

    var selectedTab: Tab? { tabs.first { $0.id == selected } }

    func ensureFirstTab() {
        guard !stopped, polling == nil else { return }
        polling = Task { [weak self] in
            guard let self else { return }
            do { self.settings = try await self.client.preferences() } catch {
                self.error = "Terminal preferences are unavailable."
            }
            await self.client.refresh()
            if !self.didEnsureFirstTab, self.client.snapshot.sessions.isEmpty {
                self.didEnsureFirstTab = true
                await self.client.open()
            }
            self.synchronize()
            while !Task.isCancelled, !self.stopped {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
                await self.client.refresh()
                self.synchronize()
            }
        }
    }

    func synchronize() {
        guard !stopped else { return }
        let sessions = client.snapshot.sessions
        for tab in tabs
        where !sessions.contains(where: {
            $0.id == tab.id && $0.generation == tab.holder.generation
        }) { tab.holder.stop() }
        tabs = sessions.map { session in
            if let previous = tabs.first(where: {
                $0.id == session.id && $0.holder.generation == session.generation
            }) {
                previous.holder.update(session)
                previous.holder.fontSize = settings.fontSize
                return previous
            }
            let holder = TerminalSessionHolder(session: session, client: client) { [weak self] in
                self?.closeTab(session.id, confirm: false)
            }
            holder.fontSize = settings.fontSize
            return Tab(id: session.id, holder: holder)
        }
        selected = sessions.first(where: \.selected)?.id
        error = client.error
    }

    func addTab() {
        guard tabs.count < Self.maximumTabs else { return }
        perform { await $0.client.open() }
    }

    func select(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        perform { await $0.client.select(tab.holder.session) }
    }

    func restart(_ id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.holder.stop()
        perform { await $0.client.restart(tab.holder.session) }
    }

    func closeTab(_ id: UUID, confirm: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let close: @MainActor (Bool) -> Void = { [weak self, weak holder = tab.holder] confirmed in
            guard confirmed, let self, let holder else { return }
            holder.stop()
            self.perform { await $0.client.close(holder.session) }
        }
        if confirm && settings.confirmClose {
            tab.holder.requestUserClose(close)
        } else {
            close(true)
        }
    }

    func selectNext(backwards: Bool) {
        guard let selected, let index = tabs.firstIndex(where: { $0.id == selected }),
            tabs.count > 1
        else { return }
        select(tabs[(index + (backwards ? tabs.count - 1 : 1)) % tabs.count].id)
    }

    func sendBroadcast(_ plan: TerminalBroadcastPlan) async throws -> TerminalBroadcastDelivery {
        try await client.broadcast(plan.command)
    }

    func windowClosed() {
        for tab in tabs { tab.holder.stop() }
        perform { await $0.client.closeAll() }
    }

    func queuePreferences(_ settings: TerminalSettings) {
        perform { await $0.savePreferences(settings) }
    }

    func savePreferences(_ settings: TerminalSettings) async {
        preferenceRevision += 1
        let revision = preferenceRevision
        do {
            let saved = try await client.savePreferences(settings)
            guard !stopped, revision == preferenceRevision else { return }
            self.settings = saved
            for tab in tabs { tab.holder.fontSize = saved.fontSize }
            error = nil
        } catch {
            guard !stopped, revision == preferenceRevision else { return }
            self.error = "Terminal preferences could not be saved."
        }
    }

    func stopAll() {
        guard !stopped else { return }
        stopped = true
        polling?.cancel()
        polling = nil
        for task in actions.values { task.cancel() }
        actions.removeAll()
        client.stop()
        for tab in tabs { tab.holder.stop() }
        tabs.removeAll()
        selected = nil
    }

    private func perform(_ action: @escaping @MainActor (TerminalTabsModel) async -> Void) {
        guard !stopped, actions.count < 32 else { return }
        let token = UUID()
        actions[token] = Task { [weak self] in
            guard let self else { return }
            defer { self.actions[token] = nil }
            guard !Task.isCancelled, !self.stopped else { return }
            await action(self)
            guard !Task.isCancelled, !self.stopped else { return }
            self.synchronize()
        }
    }
}
