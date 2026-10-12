import EdithExtensionSupport
import Foundation
import GhosttyTerminal
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
    private var broadcasts: [UUID: Task<TerminalBroadcastDelivery, Error>] = [:]
    private var retirements: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var retirement: Task<Void, Never>?
    private var didEnsureFirstTab = false
    private var preferenceRevision = 0
    private var hostWindowState: (active: Bool, key: Bool)?

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
        settings = client.snapshot.preferences
        let sessions = client.snapshot.sessions
        let removed = tabs.filter { tab in
            !sessions.contains(where: {
                $0.id == tab.id && $0.generation == tab.holder.generation
            })
        }
        guard retirements.count + removed.count <= Self.maximumTabs else { return }
        for tab in removed { retire(tab.holder) }
        tabs = sessions.map { session in
            if let previous = tabs.first(where: {
                $0.id == session.id && $0.holder.generation == session.generation
            }) {
                previous.holder.update(session)
                previous.holder.fontSize = settings.fontSize
                return previous
            }
            let holder = TerminalSessionHolder(
                session: session, client: client,
                onClose: { [weak self] in self?.closeTab(session.id, confirm: false) },
                onPaneAction: { [weak self] action in
                    guard let self else { return }
                    switch action {
                    case .newTab: self.addTab()
                    case let .selectTab(index):
                        if index == -1 {
                            self.selectNext(backwards: true)
                        } else if index == -2 {
                            self.selectNext(backwards: false)
                        } else if index == -3, let last = self.tabs.last {
                            self.select(last.id)
                        } else if index > 0, Int(index) <= self.tabs.count {
                            self.select(self.tabs[Int(index) - 1].id)
                        }
                    default: break
                    }
                })
            if let hostWindowState {
                holder.setHostWindowState(active: hostWindowState.active, key: hostWindowState.key)
            }
            holder.fontSize = settings.fontSize
            return Tab(id: session.id, holder: holder)
        }
        selected = sessions.first(where: \.selected)?.id
        error = client.error
    }

    func applyHostWindowState(active: Bool, key: Bool) {
        guard !stopped else { return }
        hostWindowState = (active, key)
        for tab in tabs { tab.holder.setHostWindowState(active: active, key: key) }
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
        guard !stopped, retirements.count < Self.maximumTabs,
            let tab = tabs.first(where: { $0.id == id })
        else { return }
        let holder = tab.holder
        retire(holder)
        perform { model in
            await holder.stopAndWait()
            await model.client.restart(holder.session)
        }
    }

    func closeTab(_ id: UUID, confirm: Bool = true) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let close: @MainActor (Bool) -> Void = { [weak self, holder = tab.holder] confirmed in
            guard confirmed, let self, !self.stopped else { return }
            self.retire(holder)
            self.perform { model in
                await holder.stopAndWait()
                await model.client.close(holder.session)
            }
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
        guard !stopped, actions.count + broadcasts.count < 32 else {
            throw ExtensionEngineError.unavailable
        }
        let id = UUID(), client = client
        let task = Task {
            try Task.checkCancellation()
            return try await client.broadcast(plan.command)
        }
        broadcasts[id] = task
        defer { broadcasts[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func windowClosed() {
        guard !stopped else { return }
        let holders = tabs.map(\.holder)
        for holder in holders { retire(holder) }
        perform { model in
            for holder in holders { await holder.stopAndWait() }
            await model.client.closeAll()
        }
    }

    func queuePreferences(_ settings: TerminalSettings) {
        perform { await $0.savePreferencesOwned(settings) }
    }

    func savePreferences(_ settings: TerminalSettings) async {
        guard let task = launch({ await $0.savePreferencesOwned(settings) }) else { return }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func savePreferencesOwned(_ settings: TerminalSettings) async {
        guard !stopped, !Task.isCancelled else { return }
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
        for task in actions.values { task.cancel() }
        for task in broadcasts.values { task.cancel() }
        client.stop()
        for tab in tabs { retire(tab.holder) }
        tabs.removeAll()
        selected = nil
        let polling = polling, actions = Array(actions.values)
        let broadcasts = Array(broadcasts.values), holders = Array(retirements.values)
        retirement = Task { [self, polling, actions, broadcasts, holders] in
            await polling?.value
            for task in actions { await task.value }
            for task in broadcasts { _ = try? await task.value }
            for task in holders { await task.value }
            await client.stopAndWait()
            self.polling = nil
        }
    }

    func stopAllAndWait() async {
        stopAll()
        await retirement?.value
    }

    private func retire(_ holder: TerminalSessionHolder) {
        let id = ObjectIdentifier(holder)
        guard retirements[id] == nil else { return }
        holder.stop()
        retirements[id] = Task { [self, holder] in
            defer { retirements[id] = nil }
            await holder.stopAndWait()
        }
    }

    private func perform(_ action: @escaping @MainActor (TerminalTabsModel) async -> Void) {
        _ = launch { model in
            await action(model)
            guard !Task.isCancelled, !model.stopped else { return }
            model.synchronize()
        }
    }

    private func launch(_ action: @escaping @MainActor (TerminalTabsModel) async -> Void)
        -> Task<Void, Never>?
    {
        guard !stopped, actions.count + broadcasts.count < 32 else { return nil }
        let token = UUID()
        let task = Task { [self] in
            defer { actions[token] = nil }
            guard !Task.isCancelled, !stopped else { return }
            await action(self)
        }
        actions[token] = task
        return task
    }
}
