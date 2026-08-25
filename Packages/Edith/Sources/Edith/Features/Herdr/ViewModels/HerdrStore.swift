import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

typealias HerdrLiveWatcher =
    @Sendable (
        @escaping @Sendable ([HerdrHostSnapshot]) -> Void
    ) async -> Void

@MainActor
@Observable
final class HerdrStore {
    static let shared = HerdrStore()
    static let boardID = "board"

    var hosts: [HerdrHostSnapshot] = []
    var machineFilter = "all"
    var kindFilter: Set<String> = []
    var selectedTab = boardID
    var tabs: [HerdrOpenTab] = []
    var refreshing = false
    var copiedID: String?
    var detailOpen = true
    var railOpen = true
    var creating = false
    var createError: String?

    private let defaults: UserDefaults
    private let liveWatcher: HerdrLiveWatcher
    private var connections: [UUID: SSHConnection] = [:]
    private var watchTask: Task<Void, Never>?
    private var watchGeneration = 0

    init(
        defaults: UserDefaults = SharedDefaults.store,
        liveWatcher: @escaping HerdrLiveWatcher = { yield in await HerdrLive.watch(yield) }
    ) {
        self.defaults = defaults
        self.liveWatcher = liveWatcher
        railOpen = defaults.object(forKey: AppStorageKeys.Herdr.railOpen) as? Bool ?? true
    }

    var agents: [HerdrAgent] { hosts.flatMap(\.agents) }

    var listedAgents: [HerdrAgent] { filtered.filter { !$0.isTerminal } }

    var listedTerminals: [HerdrAgent] { filtered.filter(\.isTerminal) }

    private var filtered: [HerdrAgent] {
        filteredAgents.isEmpty && kindFilter.isEmpty ? agents : filteredAgents
    }

    var machineChoices: [(id: String, name: String)] {
        [("all", "All machines"), ("local", "This Mac")]
            + hosts.filter { !$0.isLocal }.map { ($0.id, $0.name) }
    }

    var kindChoices: [String] {
        var labels = HerdrKind.filterLabels
        let live = Set(agents.filter { !$0.isTerminal }.map(\.kind)).sorted()
        for kind in live where !labels.contains(kind) {
            labels.append(kind)
        }
        labels.append(HerdrKind.terminalLabel)
        return labels
    }

    var filteredAgents: [HerdrAgent] {
        agents.filter { agent in
            switch machineFilter {
            case "all": break
            case "local":
                if !agent.machineIsLocal { return false }
            default:
                if agent.machineID != machineFilter { return false }
            }
            if !kindFilter.isEmpty, !kindFilter.contains(agent.kind) { return false }
            return true
        }
    }

    func kindIsSelected(_ id: String) -> Bool {
        id == "all" ? kindFilter.isEmpty : kindFilter.contains(id)
    }

    func selectKind(_ id: String) {
        selectKind(id, exclusive: NSEvent.modifierFlags.contains(.command))
    }

    func selectKind(_ id: String, exclusive: Bool) {
        if id == "all" {
            kindFilter = []
            return
        }
        if exclusive {
            kindFilter = [id]
            return
        }
        if kindFilter.contains(id) {
            kindFilter.remove(id)
        } else {
            kindFilter.insert(id)
        }
    }

    var columns: [HerdrAgentStatus] { HerdrAgentStatus.allCases }

    func setRailOpen(_ open: Bool) {
        guard railOpen != open else { return }
        railOpen = open
        defaults.set(open, forKey: AppStorageKeys.Herdr.railOpen)
    }

    func splitFraction(for id: String) -> Double {
        HerdrSplitFraction.fraction(for: id, defaults)
    }

    func setSplitFraction(_ fraction: Double, for id: String) {
        HerdrSplitFraction.set(fraction, for: id, defaults)
    }

    var openIDs: Set<String> { Set(tabs.map(\.id)) }

    func watch() async {
        guard watchTask == nil else { return }
        watchGeneration += 1
        let generation = watchGeneration
        let liveWatcher = liveWatcher
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            await liveWatcher { hosts in
                Task { @MainActor in
                    guard !Task.isCancelled else { return }
                    guard let self, self.watchGeneration == generation, self.watchTask != nil else {
                        return
                    }
                    self.apply(hosts)
                }
            }
        }
    }

    func stopWatching() {
        watchGeneration += 1
        watchTask?.cancel()
        watchTask = nil
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        apply(await HerdrSessionOperationExecution.list())
        refreshing = false
    }

    func apply(_ snapshots: [HerdrHostSnapshot]) {
        hosts = snapshots
        for index in tabs.indices {
            if let updated = agents.first(where: { $0.id == tabs[index].id }) {
                tabs[index].agent = updated
            }
        }
    }

    func open(_ agent: HerdrAgent) {
        open(agent, showing: nil)
    }

    func open(_ agent: HerdrAgent, showing view: HerdrAgentView?) {
        if let index = tabs.firstIndex(where: { $0.id == agent.id }) {
            if let view { apply(view, at: index) }
            selectedTab = agent.id
            return
        }
        let machine: Machine? =
            agent.machineIsLocal
            ? nil
            : MachineRegistry.machines().first { $0.id.uuidString == agent.machineID }
        var resolved = view ?? HerdrAgentViews.view(for: agent.id, defaults)
        if agent.isTerminal { resolved = .agent }
        tabs.append(
            HerdrOpenTab(
                agent: agent, machine: machine, view: resolved,
                holder: TerminalSessionHolder(), quinjet: HerdrQuinjetSession()))
        if view != nil { HerdrAgentViews.set(resolved, for: agent.id, defaults) }
        if resolved == .split { detailOpen = false }
        selectedTab = agent.id
    }

    func view(for id: String) -> HerdrAgentView {
        tabs.first { $0.id == id }?.view ?? HerdrAgentViews.view(for: id, defaults)
    }

    func setView(_ view: HerdrAgentView, for id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            HerdrAgentViews.set(view, for: id, defaults)
            return
        }
        apply(view, at: index)
    }

    private func apply(_ view: HerdrAgentView, at index: Int) {
        guard tabs[index].view != view else { return }
        tabs[index].view = view
        HerdrAgentViews.set(view, for: tabs[index].id, defaults)
        if view == .split { detailOpen = false }
    }

    func close(_ id: String) {
        closeWhere { _, tab in tab.id == id }
    }

    func closeOthers(besides id: String) {
        if id == Self.boardID {
            closeWhere { _, _ in true }
            return
        }
        closeWhere { _, tab in tab.id != id }
        selectedTab = id
    }

    func closeToTheRight(of id: String) {
        if id == Self.boardID {
            closeWhere { _, _ in true }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeWhere { i, _ in i > index }
    }

    func closeToTheLeft(of id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeWhere { i, _ in i < index }
    }

    func canCloseOthers(besides id: String) -> Bool {
        id == Self.boardID ? !tabs.isEmpty : tabs.count > 1
    }

    func canCloseToTheRight(of id: String) -> Bool {
        if id == Self.boardID { return !tabs.isEmpty }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index < tabs.count - 1
    }

    func canCloseToTheLeft(of id: String) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        return index > 0
    }

    private func closeWhere(_ predicate: (Int, HerdrOpenTab) -> Bool) {
        let ids = tabs.enumerated().compactMap { item in
            predicate(item.offset, item.element) ? item.element.id : nil
        }
        guard !ids.isEmpty else { return }
        let selectedClosed = ids.contains(selectedTab)
        for id in ids {
            guard let index = tabs.firstIndex(where: { $0.id == id }) else { continue }
            tabs[index].holder.stop()
            tabs[index].quinjet.stop()
            tabs.remove(at: index)
        }
        if selectedClosed {
            selectedTab = tabs.last?.id ?? Self.boardID
        }
    }

    func selectBoard() {
        selectedTab = Self.boardID
    }

    func connection(for machine: Machine) async throws -> SSHConnection {
        if let existing = connections[machine.id] {
            try await existing.connect()
            return existing
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        connections[machine.id] = connection
        return connection
    }

    func quinjetRemote(for tab: HerdrOpenTab) async throws -> QuinjetRemote? {
        guard !tab.agent.machineIsLocal else { return nil }
        guard let machine = tab.machine else {
            throw HerdrQuinjetError.machineUnavailable
        }
        let connection = try await connection(for: machine)
        return QuinjetRemote(
            machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
            controlPath: connection.controlSocketPath)
    }

    func quinjetConfiguration(appearance: QuinjetAppearance) -> QuinjetLaunchConfiguration {
        var configuration = QuinjetLaunchConfiguration.preferred(
            sharedDefaults: defaults, standardDefaults: .standard)
        configuration.terminal = .embedded
        configuration.appearance = appearance
        return configuration
    }

    func createTerminal(
        on machine: Machine?, request: HerdrTerminalRequest
    ) async -> HerdrAgent? {
        guard !creating else { return nil }
        creating = true
        createError = nil
        defer { creating = false }
        do {
            let pane: String
            let machineID: String
            if let machine {
                let connection = try await connection(for: machine)
                pane = try await HerdrTerminalOperationExecution.createRemotely(
                    request, connection: connection)
                machineID = machine.id.uuidString
            } else {
                pane = try await HerdrTerminalOperationExecution.createLocally(request)
                machineID = HerdrHostSnapshot.localID
            }
            await refresh()
            let id = "\(machineID)|\(request.session)|\(pane)"
            if let created = agents.first(where: { $0.id == id }) {
                open(created)
                return created
            }
            let placeholder = HerdrAgent.make(
                machineID: machineID, machineName: machine?.name ?? "This Mac",
                machineIsLocal: machine == nil, sshTarget: machine?.sshTarget,
                session: request.session, pane: pane, kind: HerdrKind.terminalLabel,
                status: .unknown, title: request.label ?? pane, workspace: "",
                cwd: request.cwd ?? "", category: .terminal)
            open(placeholder)
            return placeholder
        } catch {
            createError = error.localizedDescription
            return nil
        }
    }

    func workspaceChoices(for machineID: String) -> [(id: String, name: String)] {
        var seen: [String: String] = [:]
        for agent in agents where agent.machineID == machineID {
            guard !agent.workspace.isEmpty else { continue }
            seen[agent.workspace] = agent.workspace
        }
        return seen.keys.sorted().map { ($0, $0) }
    }

    func attachRequest(
        for tab: HerdrOpenTab, environment: [String],
        localExecutable: URL? = HerdrCollector.executable()
    ) async throws -> TerminalLaunchRequest {
        if tab.agent.isTerminal {
            return try await terminalRequest(
                for: tab, environment: environment, localExecutable: localExecutable)
        }
        if tab.agent.machineIsLocal {
            return HerdrOperationExecution.localAttachRequest(
                for: tab.agent, environment: environment, executable: localExecutable)
        }
        guard let machine = tab.machine else {
            throw HerdrQuinjetError.machineUnavailable
        }
        let connection = try await connection(for: machine)
        return HerdrOperationExecution.remoteAttachRequest(
            for: tab.agent, connection: connection, environment: environment)
    }

    private func terminalRequest(
        for tab: HerdrOpenTab, environment: [String], localExecutable: URL?
    ) async throws -> TerminalLaunchRequest {
        let focus = HerdrTerminalOperationExecution.focusShellLine(
            session: tab.agent.session, pane: tab.agent.pane)
        if tab.agent.machineIsLocal {
            _ = await LocalMachineCommandExecution.run(focus, timeout: 6)
            return HerdrTerminalOperationExecution.localClientRequest(
                for: tab.agent, environment: environment, executable: localExecutable)
        }
        guard let machine = tab.machine else {
            throw HerdrQuinjetError.machineUnavailable
        }
        let connection = try await connection(for: machine)
        _ = try? await connection.run(focus, timeout: 6)
        return HerdrTerminalOperationExecution.remoteClientRequest(
            for: tab.agent, target: machine.sshTarget, environment: environment,
            executable: localExecutable)
    }

    func copyAttachCommand(for agent: HerdrAgent) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(HerdrAttachCommand.line(for: agent), forType: .string)
        copiedID = agent.id
        let id = agent.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.2))
            if copiedID == id { copiedID = nil }
        }
    }
}

enum HerdrQuinjetError: LocalizedError {
    case machineUnavailable

    var errorDescription: String? {
        "That machine is no longer in Edith."
    }
}

struct HerdrOpenTab: Identifiable {
    var id: String { agent.id }
    var agent: HerdrAgent
    var machine: Machine?
    var view: HerdrAgentView = .agent
    let holder: TerminalSessionHolder
    let quinjet: HerdrQuinjetSession
}
