import AppKit
import EdithKit
import Observation
import SwiftTerm
import SwiftUI

typealias HerdrLiveWatcher =
    @Sendable (
        @escaping @Sendable ([HerdrHostSnapshot]) -> Void
    ) async -> Void

typealias HerdrAgentCloser = @Sendable (HerdrAgent) async throws -> Void

struct HerdrAgentSpace: Identifiable, Equatable {
    let id: String
    let title: String
    let agents: [HerdrAgent]

    static func group(_ agents: [HerdrAgent]) -> [HerdrAgentSpace] {
        Dictionary(grouping: agents, by: spaceID)
            .map { HerdrAgentSpace(id: $0.key, title: $0.key, agents: $0.value) }
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    static func counts(_ spaces: [HerdrAgentSpace]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: spaces.map { ($0.id, $0.agents.count) })
    }

    static func spaceID(_ agent: HerdrAgent) -> String {
        let title = agent.workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Unassigned" : title
    }
}

enum HerdrPaneSizing {
    static let railDefault = 252.0
    static let railMinimum = 180.0
    static let railMaximum = 420.0
    static let detailDefault = 260.0
    static let detailMinimum = 220.0
    static let detailMaximum = 520.0

    static func rail(_ width: Double) -> Double {
        min(railMaximum, max(railMinimum, width))
    }

    static func detail(_ width: Double) -> Double {
        min(detailMaximum, max(detailMinimum, width))
    }
}

@MainActor
@Observable
final class HerdrStore {
    static let shared = HerdrStore()
    static let boardID = "board"

    var hosts: [HerdrHostSnapshot] = []
    var machineFilter = "all" {
        didSet {
            guard machineFilter != oldValue else { return }
            reconcileCollapseCountsIfReady()
        }
    }
    var kindFilter: Set<String> = [] {
        didSet {
            guard kindFilter != oldValue else { return }
            reconcileCollapseCountsIfReady()
        }
    }
    var selectedTab = boardID {
        didSet {
            guard selectedTab != oldValue else { return }
            guard
                let agent = tabs.first(where: { $0.id == selectedTab })?.agent
                    ?? detachedTabs[selectedTab]?.agent
            else { return }
            revealSpace(containing: agent)
        }
    }
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
    var railWidth = HerdrPaneSizing.railDefault {
        didSet {
            guard railWidth != oldValue else { return }
            defaults.set(railWidth, forKey: AppStorageKeys.Herdr.railWidth)
        }
    }
    var detailWidth = HerdrPaneSizing.detailDefault {
        didSet {
            guard detailWidth != oldValue else { return }
            defaults.set(detailWidth, forKey: AppStorageKeys.Herdr.detailWidth)
        }
    }
    var agentsCollapsed = false {
        didSet {
            guard agentsCollapsed != oldValue else { return }
            guard !restoringDefaults else { return }
            defaults.set(agentsCollapsed, forKey: AppStorageKeys.Herdr.agentsCollapsed)
            if agentsCollapsed {
                let count = listedAgents.count
                agentsCollapsedCount = count
                defaults.set(count, forKey: AppStorageKeys.Herdr.agentsCollapsedCount)
            } else {
                agentsCollapsedCount = nil
                defaults.removeObject(forKey: AppStorageKeys.Herdr.agentsCollapsedCount)
            }
        }
    }
    var terminalsCollapsed = false {
        didSet {
            guard terminalsCollapsed != oldValue else { return }
            guard !restoringDefaults else { return }
            defaults.set(terminalsCollapsed, forKey: AppStorageKeys.Herdr.terminalsCollapsed)
            if terminalsCollapsed {
                let count = machineTerminals.count
                terminalsCollapsedCount = count
                defaults.set(count, forKey: AppStorageKeys.Herdr.terminalsCollapsedCount)
            } else {
                terminalsCollapsedCount = nil
                defaults.removeObject(forKey: AppStorageKeys.Herdr.terminalsCollapsedCount)
            }
        }
    }
    var spaceGroupingEnabled = false {
        didSet {
            guard spaceGroupingEnabled != oldValue else { return }
            defaults.set(
                spaceGroupingEnabled, forKey: AppStorageKeys.Herdr.spaceGroupingEnabled)
        }
    }
    private(set) var collapsedSpaces: Set<String> = [] {
        didSet {
            guard collapsedSpaces != oldValue else { return }
            defaults.set(
                Array(collapsedSpaces), forKey: AppStorageKeys.Herdr.collapsedSpaces)
        }
    }

    private let defaults: UserDefaults
    private let liveWatcher: HerdrLiveWatcher
    private let agentCloser: HerdrAgentCloser
    private let expectedHostCount: Int
    private var restoringDefaults = true
    private var collapseCountsReady = false
    private var agentsCollapsedCount: Int?
    private var terminalsCollapsedCount: Int?
    private var collapsedSpaceCounts: [String: Int] = [:]
    private var connections: [UUID: SSHConnection] = [:]
    private var watchTask: Task<Void, Never>?
    private var settleTask: Task<Void, Never>?
    private var pendingHosts: [HerdrHostSnapshot]?
    private var detachedTabs: [String: HerdrOpenTab] = [:]
    private var watchGeneration = 0

    init(
        defaults: UserDefaults = SharedDefaults.store,
        liveWatcher: @escaping HerdrLiveWatcher = { yield in await HerdrLive.watch(yield) },
        expectedHostCount: Int = MachineRegistry.machines().count + 1,
        agentCloser: @escaping HerdrAgentCloser = { try await HerdrAgentCloseExecution.close($0) }
    ) {
        self.defaults = defaults
        self.liveWatcher = liveWatcher
        self.expectedHostCount = expectedHostCount
        self.agentCloser = agentCloser
        railOpen = defaults.object(forKey: AppStorageKeys.Herdr.railOpen) as? Bool ?? true
        railWidth = HerdrPaneSizing.rail(
            defaults.object(forKey: AppStorageKeys.Herdr.railWidth) as? Double
                ?? HerdrPaneSizing.railDefault)
        detailOpen = defaults.object(forKey: AppStorageKeys.Herdr.detailOpen) as? Bool ?? true
        detailWidth = HerdrPaneSizing.detail(
            defaults.object(forKey: AppStorageKeys.Herdr.detailWidth) as? Double
                ?? HerdrPaneSizing.detailDefault)
        agentsCollapsed =
            defaults.object(forKey: AppStorageKeys.Herdr.agentsCollapsed) as? Bool ?? false
        terminalsCollapsed =
            defaults.object(forKey: AppStorageKeys.Herdr.terminalsCollapsed) as? Bool ?? false
        agentsCollapsedCount = Self.optionalInt(
            defaults, key: AppStorageKeys.Herdr.agentsCollapsedCount)
        terminalsCollapsedCount = Self.optionalInt(
            defaults, key: AppStorageKeys.Herdr.terminalsCollapsedCount)
        spaceGroupingEnabled =
            defaults.object(forKey: AppStorageKeys.Herdr.spaceGroupingEnabled) as? Bool ?? false
        collapsedSpaces = Set(
            defaults.stringArray(forKey: AppStorageKeys.Herdr.collapsedSpaces) ?? [])
        collapsedSpaceCounts = Self.spaceCounts(
            defaults.dictionary(forKey: AppStorageKeys.Herdr.collapsedSpaceCounts) ?? [:])
        restoringDefaults = false
    }

    var agents: [HerdrAgent] { hosts.flatMap(\.agents) }

    var listedAgents: [HerdrAgent] {
        filteredAgents.isEmpty && kindFilter.isEmpty ? agents : filteredAgents
    }

    var agentSpaces: [HerdrAgentSpace] {
        HerdrAgentSpace.group(listedAgents)
    }

    func spaceIsCollapsed(_ id: String) -> Bool {
        collapsedSpaces.contains(id)
    }

    func toggleSpace(_ id: String) {
        if collapsedSpaces.contains(id) {
            collapsedSpaces.remove(id)
            collapsedSpaceCounts.removeValue(forKey: id)
        } else {
            collapsedSpaces.insert(id)
            collapsedSpaceCounts[id] = agentSpaces.first { $0.id == id }?.agents.count ?? 0
        }
        persistCollapsedSpaceCounts()
    }

    var allAgentSpacesCollapsed: Bool {
        let spaceIDs = Set(agentSpaces.map(\.id))
        return !spaceIDs.isEmpty && spaceIDs.isSubset(of: collapsedSpaces)
    }

    func setAllAgentSpacesCollapsed(_ collapsed: Bool) {
        for space in agentSpaces {
            if collapsed {
                collapsedSpaces.insert(space.id)
                collapsedSpaceCounts[space.id] = space.agents.count
            } else {
                collapsedSpaces.remove(space.id)
                collapsedSpaceCounts.removeValue(forKey: space.id)
            }
        }
        persistCollapsedSpaceCounts()
    }

    func revealSpace(containing agent: HerdrAgent) {
        guard !agent.isTerminal else { return }
        let spaceID = HerdrAgentSpace.spaceID(agent)
        guard collapsedSpaces.remove(spaceID) != nil else { return }
        collapsedSpaceCounts.removeValue(forKey: spaceID)
        persistCollapsedSpaceCounts()
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
        apply(latest, collapseSnapshotComplete: latest.count >= expectedHostCount)
    }

    func apply(_ snapshots: [HerdrHostSnapshot]) {
        apply(snapshots, collapseSnapshotComplete: true)
    }

    private func apply(_ snapshots: [HerdrHostSnapshot], collapseSnapshotComplete: Bool) {
        hosts = snapshots
        for index in tabs.indices {
            if let updated = agents.first(where: { $0.id == tabs[index].id }) {
                tabs[index].agent = updated
            }
        }
        if collapseSnapshotComplete {
            collapseCountsReady = true
            reconcileCollapseCounts()
        }
    }

    private func reconcileCollapseCountsIfReady() {
        guard collapseCountsReady else { return }
        reconcileCollapseCounts()
    }

    private func reconcileCollapseCounts() {
        if agentsCollapsed, agentsCollapsedCount != listedAgents.count {
            agentsCollapsed = false
        }
        if terminalsCollapsed, terminalsCollapsedCount != machineTerminals.count {
            terminalsCollapsed = false
        }
        let currentSpaceCounts = HerdrAgentSpace.counts(agentSpaces)
        let changedSpaces = collapsedSpaces.filter {
            collapsedSpaceCounts[$0] != currentSpaceCounts[$0, default: 0]
        }
        guard !changedSpaces.isEmpty else { return }
        for id in changedSpaces {
            collapsedSpaces.remove(id)
            collapsedSpaceCounts.removeValue(forKey: id)
        }
        persistCollapsedSpaceCounts()
    }

    private func persistCollapsedSpaceCounts() {
        defaults.set(collapsedSpaceCounts, forKey: AppStorageKeys.Herdr.collapsedSpaceCounts)
    }

    private static func spaceCounts(_ values: [String: Any]) -> [String: Int] {
        values.reduce(into: [:]) { result, entry in
            if let number = entry.value as? NSNumber { result[entry.key] = number.intValue }
        }
    }

    private static func optionalInt(_ defaults: UserDefaults, key: String) -> Int? {
        defaults.object(forKey: key) == nil ? nil : defaults.integer(forKey: key)
    }

    var detachedIDs: Set<String> { Set(detachedTabs.keys) }

    func makeTab(for agent: HerdrAgent) -> HerdrOpenTab {
        var resolved = HerdrAgentViews.view(for: agent.id, defaults)
        if agent.isTerminal { resolved = .agent }
        return HerdrOpenTab(
            agent: agent, machine: machine(for: agent), view: resolved,
            holder: TerminalSessionHolder(), quinjet: HerdrQuinjetSession())
    }

    func detachedTab(for agent: HerdrAgent) -> HerdrOpenTab {
        revealSpace(containing: agent)
        if let existing = detachedTabs[agent.id] { return existing }
        let tab = makeTab(for: agent)
        detachedTabs[agent.id] = tab
        return tab
    }

    func detachedTab(id: String) -> HerdrOpenTab? {
        detachedTabs[id]
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
        revealSpace(containing: agent)
        if let index = tabs.firstIndex(where: { $0.id == agent.id }) {
            if let view { apply(view, at: index) }
            selectedTab = agent.id
            return
        }
        var tab = makeTab(for: agent)
        if let view, !agent.isTerminal { tab.view = view }
        let resolved = tab.view
        tabs.append(tab)
        if view != nil { HerdrAgentViews.set(resolved, for: agent.id, defaults) }
        if resolved == .split { detailOpen = false }
        selectedTab = agent.id
    }

    func view(for id: String) -> HerdrAgentView {
        tabs.first { $0.id == id }?.view ?? detachedTabs[id]?.view
            ?? HerdrAgentViews.view(for: id, defaults)
    }

    func setView(_ view: HerdrAgentView, for id: String) {
        if var tab = detachedTabs[id] {
            revealSpace(containing: tab.agent)
            guard tab.view != view else { return }
            tab.view = view
            detachedTabs[id] = tab
            HerdrAgentViews.set(view, for: id, defaults)
            if view == .split { detailOpen = false }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            HerdrAgentViews.set(view, for: id, defaults)
            return
        }
        revealSpace(containing: tabs[index].agent)
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

    func closeAgent(_ agent: HerdrAgent) async throws {
        try await agentCloser(agent)
        close(agent.id)
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
        return await QuinjetRemote.connected(
            machineID: machine.id, machineName: machine.name, target: machine.sshTarget,
            connection: connection)
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
        localExecutable: URL? = HerdrCollector.executable(),
        bridgeExecutable: URL? = HerdrTerminalBridge.executable()
    ) async throws -> TerminalLaunchRequest {
        if tab.agent.isTerminal {
            if !tab.agent.machineIsLocal {
                guard let machine = tab.machine else {
                    throw HerdrQuinjetError.machineUnavailable
                }
                let connection = try await connection(for: machine)
                if await connection.remotePlatform == .windows {
                    return HerdrMachineTerminal.windowsLaunchRequest(
                        connection: connection, environment: environment)
                }
            }
            return HerdrMachineTerminal.launchRequest(
                for: tab.agent, environment: environment, executable: localExecutable)
        }
        guard let bridgeExecutable else {
            throw HerdrTerminalBridgeError.executableUnavailable
        }
        let controller: TerminalLaunchRequest
        if tab.agent.machineIsLocal {
            controller = HerdrOperationExecution.localControlRequest(
                for: tab.agent, environment: environment, executable: localExecutable)
        } else {
            guard let machine = tab.machine else {
                throw HerdrQuinjetError.machineUnavailable
            }
            let connection = try await connection(for: machine)
            let platform = await connection.remotePlatform ?? .linux
            controller = HerdrOperationExecution.remoteControlRequest(
                for: tab.agent, connection: connection, environment: environment,
                platform: platform)
        }
        return try HerdrTerminalBridge.launchRequest(
            bridgeExecutable: bridgeExecutable, controller: controller)
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
