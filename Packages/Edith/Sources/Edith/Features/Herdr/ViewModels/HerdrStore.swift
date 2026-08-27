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
    var detailOpen = true {
        didSet {
            guard detailOpen != oldValue else { return }
            defaults.set(detailOpen, forKey: AppStorageKeys.Herdr.detailOpen)
        }
    }
    var railOpen = true
    var agentsCollapsed = false {
        didSet {
            guard agentsCollapsed != oldValue else { return }
            defaults.set(agentsCollapsed, forKey: AppStorageKeys.Herdr.agentsCollapsed)
        }
    }
    var terminalsCollapsed = false {
        didSet {
            guard terminalsCollapsed != oldValue else { return }
            defaults.set(terminalsCollapsed, forKey: AppStorageKeys.Herdr.terminalsCollapsed)
        }
    }

    private let defaults: UserDefaults
    private let liveWatcher: HerdrLiveWatcher
    private var connections: [UUID: SSHConnection] = [:]
    private var watchTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var pendingHosts: [HerdrHostSnapshot]?
    private var detachedTabs: [String: HerdrOpenTab] = [:]
    private var watchGeneration = 0

    init(
        defaults: UserDefaults = SharedDefaults.store,
        liveWatcher: @escaping HerdrLiveWatcher = { yield in await HerdrLive.watch(yield) }
    ) {
        self.defaults = defaults
        self.liveWatcher = liveWatcher
        railOpen = defaults.object(forKey: AppStorageKeys.Herdr.railOpen) as? Bool ?? true
        detailOpen = defaults.object(forKey: AppStorageKeys.Herdr.detailOpen) as? Bool ?? true
        agentsCollapsed =
            defaults.object(forKey: AppStorageKeys.Herdr.agentsCollapsed) as? Bool ?? false
        terminalsCollapsed =
            defaults.object(forKey: AppStorageKeys.Herdr.terminalsCollapsed) as? Bool ?? false
    }

    var agents: [HerdrAgent] { hosts.flatMap(\.agents) }

    var listedAgents: [HerdrAgent] {
        filteredAgents.isEmpty && kindFilter.isEmpty ? agents : filteredAgents
    }

    var machineTerminals: [HerdrAgent] {
        var terminals: [HerdrAgent] = []
        for host in hosts where host.herdrPresent {
            let terminal = HerdrMachineTerminal.agent(for: host)
            switch machineFilter {
            case "all": terminals.append(terminal)
            case "local" where terminal.machineIsLocal: terminals.append(terminal)
            case terminal.machineID: terminals.append(terminal)
            default: break
            }
        }
        return terminals
    }

    var machineChoices: [(id: String, name: String)] {
        [("all", "All machines"), ("local", "This Mac")]
            + hosts.filter { !$0.isLocal }.map { ($0.id, $0.name) }
    }

    var kindChoices: [String] {
        var labels = HerdrKind.filterLabels
        for kind in Set(agents.map(\.kind)).sorted() where !labels.contains(kind) {
            labels.append(kind)
        }
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
        if hosts.isEmpty { settling = true }
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
                    self.settle(hosts)
                }
            }
        }
    }

    func stopWatching() {
        watchGeneration += 1
        watchTask?.cancel()
        watchTask = nil
        settleTask?.cancel()
        settleTask = nil
        pendingHosts = nil
        settling = false
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        apply(await HerdrSessionOperationExecution.list())
        refreshing = false
    }

    static let settleWindow = Duration.milliseconds(400)

    private(set) var settling = false

    func settle(_ snapshots: [HerdrHostSnapshot]) {
        pendingHosts = snapshots
        guard settleTask == nil else { return }
        if !settling { flush() }
        let generation = watchGeneration
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.settleWindow)
            guard !Task.isCancelled else { return }
            guard let self, self.watchGeneration == generation else { return }
            self.settleTask = nil
            self.settling = false
            self.flush()
        }
    }

    private func flush() {
        guard let latest = pendingHosts else { return }
        pendingHosts = nil
        apply(latest)
    }

    func apply(_ snapshots: [HerdrHostSnapshot]) {
        hosts = snapshots
        for index in tabs.indices {
            if let updated = agents.first(where: { $0.id == tabs[index].id }) {
                tabs[index].agent = updated
            }
        }
    }

    var detachedIDs: Set<String> { Set(detachedTabs.keys) }

    func detachedTab(for agent: HerdrAgent) -> HerdrOpenTab {
        if let existing = detachedTabs[agent.id] { return existing }
        var resolved = HerdrAgentViews.view(for: agent.id, defaults)
        if agent.isTerminal { resolved = .agent }
        let tab = HerdrOpenTab(
            agent: agent, machine: machine(for: agent), view: resolved,
            holder: TerminalSessionHolder(), quinjet: HerdrQuinjetSession())
        detachedTabs[agent.id] = tab
        return tab
    }

    func reattach(_ id: String) {
        detachedTabs[id]?.holder.stop()
        detachedTabs[id]?.quinjet.stop()
        detachedTabs.removeValue(forKey: id)
    }

    private func machine(for agent: HerdrAgent) -> Machine? {
        agent.machineIsLocal
            ? nil
            : MachineRegistry.machines().first { $0.id.uuidString == agent.machineID }
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
        let machine: Machine? = machine(for: agent)
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

    var orderedTabIDs: [String] { [Self.boardID] + tabs.map(\.id) }

    func moveTab(_ id: String, toIndexOf target: String) {
        guard id != target, id != Self.boardID else { return }
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let to: Int
        if target == Self.boardID {
            to = 0
        } else if let index = tabs.firstIndex(where: { $0.id == target }) {
            to = index
        } else {
            return
        }
        guard from != to else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(to, tabs.count))
    }

    func selectTab(number: Int) {
        let ids = orderedTabIDs
        guard !ids.isEmpty else { return }
        guard number != 9 else {
            selectedTab = ids[ids.count - 1]
            return
        }
        let index = number - 1
        guard index >= 0, index < ids.count else { return }
        selectedTab = ids[index]
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

    func uploadDroppedFiles(_ urls: [URL], for tab: HerdrOpenTab) async throws -> [String] {
        guard let machine = tab.machine else { throw HerdrQuinjetError.machineUnavailable }
        let connection = try await connection(for: machine)
        var paths: [String] = []
        for url in urls {
            let path = HerdrDropTransfer.remotePath(for: url)
            try await connection.upload(localURL: url, toRemotePath: path)
            paths.append(path)
        }
        return paths
    }

    func attachRequest(
        for tab: HerdrOpenTab, environment: [String],
        localExecutable: URL? = HerdrCollector.executable()
    ) async throws -> TerminalLaunchRequest {
        if tab.agent.isTerminal {
            return HerdrMachineTerminal.launchRequest(
                for: tab.agent, environment: environment, executable: localExecutable)
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
