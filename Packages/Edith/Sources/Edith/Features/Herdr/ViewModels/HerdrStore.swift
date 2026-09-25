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

struct HerdrClosedTabRecord: Equatable {
    let tabID: String
    let layout: HerdrLayout
    let focused: String
    let zoomed: String?
    let agents: [HerdrAgent]
    let rightNeighborID: String?
}

typealias HerdrNewAgentLauncher =
    @Sendable (
        _ kind: String, _ machine: Machine?, _ existingSpace: HerdrWorkspaceSummary?,
        _ newSpaceLabel: String?
    ) async throws -> HerdrCreatedPane

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
    typealias UserCloseRequester =
        @MainActor (
            TerminalSessionHolder, @escaping @MainActor (Bool) -> Void
        ) -> Void

    static let shared = HerdrStore()
    static let boardID = "board"

    var hosts: [HerdrHostSnapshot] = []
    var searchPresented = false
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
            guard let agent = focusedSession?.agent else { return }
            revealSpace(containing: agent)
        }
    }
    var tabs: [HerdrTab] = [] {
        didSet { scheduleTerminalRetarget(from: oldValue) }
    }
    private(set) var sessions: [HerdrOpenTab] = []
    private var closedTabHistory: [HerdrClosedTabRecord] = []
    private let closedTabHistoryLimit = 10
    var refreshing = false
    var copiedID: String?
    var detailOpen = true {
        didSet {
            guard detailOpen != oldValue else { return }
            defaults.set(detailOpen, forKey: AppStorageKeys.Herdr.detailOpen)
        }
    }
    var railOpen = true
    var animatesLayout = false {
        didSet {
            guard animatesLayout != oldValue else { return }
            defaults.set(animatesLayout, forKey: AppStorageKeys.Herdr.animatesLayout)
        }
    }
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
    private(set) var savedArrangements: [HerdrSavedArrangement] = [] {
        didSet {
            guard savedArrangements != oldValue else { return }
            defaults.set(
                try? JSONEncoder().encode(savedArrangements),
                forKey: AppStorageKeys.Herdr.savedArrangements)
        }
    }
    private(set) var collapsedSpaces: Set<String> = [] {
        didSet {
            guard collapsedSpaces != oldValue else { return }
            defaults.set(
                Array(collapsedSpaces), forKey: AppStorageKeys.Herdr.collapsedSpaces)
        }
    }

    @ObservationIgnored private let pageWindows = NSHashTable<NSWindow>.weakObjects()
    @ObservationIgnored private var tabsBeforeRetarget: [HerdrTab]?
    let terminalPanels: HerdrTerminalPanels
    private let defaults: UserDefaults
    private let liveWatcher: HerdrLiveWatcher
    private let agentCloser: HerdrAgentCloser
    private let newAgentLauncher: HerdrNewAgentLauncher
    private let machinesProvider: () -> [Machine]
    private let requestUserClose: UserCloseRequester
    private var expectedHostCount: Int
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
    @ObservationIgnored nonisolated(unsafe) private var machinesObserver: NSObjectProtocol?

    init(
        defaults: UserDefaults = SharedDefaults.store,
        liveWatcher: @escaping HerdrLiveWatcher = { yield in await HerdrLive.watch(yield) },
        agentCloser: @escaping HerdrAgentCloser = { try await HerdrAgentCloseExecution.close($0) },
        newAgentLauncher: @escaping HerdrNewAgentLauncher = {
            kind, machine, existingSpace, newSpaceLabel in
            let created: HerdrCreatedPane
            if let existingSpace {
                created = try await HerdrLaunchOperations.createTab(
                    workspaceID: existingSpace.id, on: machine)
            } else {
                created = try await HerdrLaunchOperations.createWorkspace(
                    label: newSpaceLabel ?? "New space", on: machine)
            }
            try await HerdrLaunchOperations.launchAgent(
                kind: kind,
                name: HerdrLaunchSettings.defaultHerdrSlug(for: kind) ?? kind.lowercased(),
                pane: created.paneID, on: machine)
            return created
        },
        machinesProvider: @escaping () -> [Machine] = { MachineRegistry.machines() },
        requestUserClose: @escaping UserCloseRequester = { holder, completion in
            holder.requestUserClose(completion)
        },
        terminalPanels: HerdrTerminalPanels? = nil
    ) {
        self.defaults = defaults
        self.terminalPanels = terminalPanels ?? HerdrTerminalPanels(defaults: defaults)
        self.liveWatcher = liveWatcher
        self.agentCloser = agentCloser
        self.newAgentLauncher = newAgentLauncher
        self.machinesProvider = machinesProvider
        self.requestUserClose = requestUserClose
        expectedHostCount = machinesProvider().count + 1
        railOpen = defaults.object(forKey: AppStorageKeys.Herdr.railOpen) as? Bool ?? true
        animatesLayout =
            defaults.object(forKey: AppStorageKeys.Herdr.animatesLayout) as? Bool ?? false
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
        savedArrangements =
            defaults.data(forKey: AppStorageKeys.Herdr.savedArrangements).flatMap {
                try? JSONDecoder().decode([HerdrSavedArrangement].self, from: $0)
            } ?? []
        restoringDefaults = false
        machinesObserver = IPC.observe(IPC.Name.machinesChanged) { [weak self] in
            Task { @MainActor in
                await self?.machinesDidChange()
            }
        }
    }

    deinit {
        if let machinesObserver { IPC.stopObserving(machinesObserver) }
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

    var openIDs: Set<String> { Set(sessions.map(\.id)) }

    func watch() async {
        guard watchTask == nil else { return }
        expectedHostCount = machinesProvider().count + 1
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

    func adopt(_ snapshot: SessionsSnapshot) {
        if watchTask != nil { stopWatching() }
        settling = false
        apply(snapshot.hosts)
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

    func machinesDidChange() async {
        guard watchTask != nil else { return }
        stopWatching()
        await watch()
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
        let complete = latest.count >= expectedHostCount
        apply(
            complete ? latest : retainingConfiguredHosts(in: latest),
            collapseSnapshotComplete: complete)
    }

    private func retainingConfiguredHosts(
        in snapshots: [HerdrHostSnapshot]
    ) -> [HerdrHostSnapshot] {
        var incoming: Set<String> = []
        for snapshot in snapshots { incoming.insert(snapshot.id) }
        var configured: Set<String> = [HerdrHostSnapshot.localID]
        var order = [HerdrHostSnapshot.localID: 0]
        for (index, machine) in machinesProvider().enumerated() {
            let id = machine.id.uuidString
            configured.insert(id)
            order[id] = index + 1
        }
        var merged = snapshots
        for host in hosts where configured.contains(host.id) && !incoming.contains(host.id) {
            merged.append(host)
        }
        merged.sort {
            order[$0.id, default: Int.max] < order[$1.id, default: Int.max]
        }
        return merged
    }

    func apply(_ snapshots: [HerdrHostSnapshot]) {
        apply(snapshots, collapseSnapshotComplete: true)
    }

    private func apply(_ snapshots: [HerdrHostSnapshot], collapseSnapshotComplete: Bool) {
        if hosts != snapshots { hosts = snapshots }
        for index in sessions.indices {
            if let updated = agents.first(where: { $0.id == sessions[index].id }),
                sessions[index].agent != updated
            {
                sessions[index].agent = updated
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

    func session(_ agentID: String) -> HerdrOpenTab? {
        sessions.first { $0.id == agentID }
    }

    func tab(_ id: String) -> HerdrTab? {
        tabs.first { $0.id == id }
    }

    func tab(containing agentID: String) -> HerdrTab? {
        tabs.first { $0.layout.contains(agentID) }
    }

    var currentTab: HerdrTab? { tab(selectedTab) }

    var focusedSession: HerdrOpenTab? {
        currentTab.flatMap { session($0.focused) }
    }

    func open(_ agent: HerdrAgent) {
        open(agent, showing: nil)
    }

    func open(_ request: HerdrOpenRequest) async {
        if !agents.contains(where: { $0.id == request.agentID }) { await refresh() }
        guard let agent = agents.first(where: { $0.id == request.agentID }) else { return }
        open(agent, showing: request.view)
    }

    func open(_ agent: HerdrAgent, showing view: HerdrAgentView?) {
        revealSpace(containing: agent)
        if sessions.contains(where: { $0.id == agent.id }) {
            if let view { setView(view, for: agent.id) }
            reveal(agent.id)
            return
        }
        adoptSession(for: agent, showing: view)
        let tab = HerdrTab(agentID: agent.id)
        tabs.append(tab)
        if self.view(for: agent.id) == .split { detailOpen = false }
        selectedTab = tab.id
    }

    func open(_ agent: HerdrAgent, beside side: InsertSide) {
        if session(agent.id) == nil, HerdrSpaceWindow.raise(containingAgent: agent.id) { return }
        guard let current = currentTab, !current.layout.contains(agent.id) else {
            open(agent)
            return
        }
        if sessions.contains(where: { $0.id == agent.id }) {
            detachFromLayout(agent.id)
        } else {
            adoptSession(for: agent, showing: nil)
        }
        updateTab(current.id) { tab in
            tab.layout = tab.layout.inserting(.pane(agent.id), near: tab.focused, side: side)
            tab.focused = agent.id
            tab.zoomed = nil
        }
        revealSpace(containing: agent)
        selectedTab = current.id
    }

    private func adoptSession(for agent: HerdrAgent, showing view: HerdrAgentView?) {
        if detachedTabs[agent.id] != nil {
            HerdrAgentWindow.close(agent.id)
            reattach(agent.id)
        }
        var session = makeTab(for: agent)
        if let view, !agent.isTerminal {
            session.view = view
            HerdrAgentViews.set(view, for: agent.id, defaults)
        }
        sessions.append(session)
    }

    private func reveal(_ agentID: String) {
        guard let tab = tab(containing: agentID) else { return }
        updateTab(tab.id) { tab in
            tab.focused = agentID
            if tab.zoomed != nil { tab.zoomed = agentID }
        }
        selectedTab = tab.id
    }

    func view(for id: String) -> HerdrAgentView {
        session(id)?.view ?? detachedTabs[id]?.view
            ?? HerdrAgentViews.view(for: id, defaults)
    }

    func shownView(for id: String) -> HerdrAgentView {
        let view = view(for: id)
        guard view == .split, tab(containing: id)?.isSplit == true else { return view }
        return .agent
    }

    func views(for id: String) -> [HerdrAgentView] {
        if session(id)?.agent.isTerminal == true { return [] }
        if tab(containing: id)?.isSplit == true { return [.agent, .diff] }
        return [.agent, .split, .diff]
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
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            HerdrAgentViews.set(view, for: id, defaults)
            return
        }
        guard views(for: id).contains(view) else { return }
        revealSpace(containing: sessions[index].agent)
        guard sessions[index].view != view else { return }
        sessions[index].view = view
        HerdrAgentViews.set(view, for: id, defaults)
        if view == .split { detailOpen = false }
    }

    func focus(_ agentID: String) {
        terminalPanels.releaseFocus()
        guard let tab = tab(containing: agentID), tab.focused != agentID else { return }
        updateTab(tab.id) { $0.focused = agentID }
        if let agent = session(agentID)?.agent { revealSpace(containing: agent) }
    }

    func focusNeighbor(toward side: InsertSide) {
        guard let tab = currentTab, tab.zoomed == nil,
            let next = tab.layout.neighbor(of: tab.focused, toward: side)
        else { return }
        focus(next)
    }

    func performLayoutKey(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, in window: NSWindow?
    ) -> Bool {
        guard let window, pageWindows.contains(window), let tab = currentTab, tab.isSplit,
            let key = HerdrLayoutKey.resolve(keyCode: keyCode, modifiers: modifiers)
        else { return false }
        withAnimation(layoutAnimation) {
            switch key {
            case let .focus(side): focusNeighbor(toward: side)
            case let .cycle(backwards): cycleFocus(backwards: backwards)
            case .zoom: toggleZoom(tab.focused)
            }
        }
        return true
    }

    var layoutAnimation: Animation? {
        guard animatesLayout else { return nil }
        return Motion.animation(
            Motion.glide,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    func movePage(from old: NSWindow?, to new: NSWindow?) {
        if let old { pageWindows.remove(old) }
        if let new { pageWindows.add(new) }
    }

    func cycleFocus(backwards: Bool) {
        guard let tab = currentTab, tab.isSplit,
            let index = tab.agentIDs.firstIndex(of: tab.focused)
        else { return }
        let count = tab.agentIDs.count
        let next = tab.agentIDs[(index + (backwards ? count - 1 : 1)) % count]
        updateTab(tab.id) { tab in
            tab.focused = next
            if tab.zoomed != nil { tab.zoomed = next }
        }
        if let agent = session(next)?.agent { revealSpace(containing: agent) }
    }

    func toggleZoom(_ agentID: String) {
        guard let tab = tab(containing: agentID), tab.isSplit else { return }
        updateTab(tab.id) { tab in
            tab.zoomed = tab.zoomed == agentID ? nil : agentID
            tab.focused = agentID
        }
    }

    func arrange(_ tabID: String, as arrangement: HerdrArrangement) {
        arrange(tabID, as: .builtIn(arrangement))
    }

    func arrange(_ tabID: String, as template: HerdrLayoutTemplate) {
        guard let tab = tab(tabID) else { return }
        let ordered = [tab.focused] + tab.agentIDs.filter { $0 != tab.focused }
        guard let layout = template.layout(ordered) else { return }
        updateTab(tabID) { tab in
            tab.layout = layout
            tab.zoomed = nil
        }
    }

    func templates(for count: Int) -> [HerdrLayoutTemplate] {
        HerdrLayoutTemplate.all(for: count, saved: savedArrangements)
    }

    func currentTemplate(of tabID: String) -> HerdrLayoutTemplate? {
        tab(tabID).flatMap { HerdrLayoutTemplate.matching($0.layout, saved: savedArrangements) }
    }

    @discardableResult
    func saveArrangement(of tabID: String, named name: String) -> HerdrSavedArrangement? {
        guard let tab = tab(tabID), tab.isSplit else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = HerdrSavedArrangement(
            name: trimmed.isEmpty ? "Layout \(savedArrangements.count + 1)" : trimmed,
            layout: tab.layout)
        savedArrangements.removeAll { $0.shape.geometryMatches(saved.shape, tolerance: 0.001) }
        savedArrangements.insert(saved, at: 0)
        return saved
    }

    func deleteArrangement(_ id: UUID) {
        savedArrangements.removeAll { $0.id == id }
    }

    func rotate(_ tabID: String) {
        updateTab(tabID) { $0.layout = $0.layout.rotated() }
    }

    func mirror(_ tabID: String, _ axis: SplitAxis) {
        updateTab(tabID) { $0.layout = $0.layout.mirrored(axis) }
    }

    func equalize(_ tabID: String) {
        updateTab(tabID) { $0.layout = $0.layout.equalized() }
    }

    func resize(_ tabID: String, split: UUID, index: Int, by change: Double) {
        updateTab(tabID) { $0.layout = $0.layout.resizing(split: split, index: index, by: change) }
    }

    func swap(_ first: String, _ second: String) {
        guard let tab = tab(containing: first), tab.layout.contains(second) else { return }
        updateTab(tab.id) { $0.layout = $0.layout.swapping(first, second) }
    }

    func moveToNewTab(_ agentID: String) {
        guard let source = tab(containing: agentID), source.isSplit,
            let index = tabs.firstIndex(where: { $0.id == source.id })
        else { return }
        detachFromLayout(agentID)
        let tab = HerdrTab(agentID: agentID)
        tabs.insert(tab, at: min(index + 1, tabs.count))
        selectedTab = tab.id
    }

    func separate(_ tabID: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }), tabs[index].isSplit else {
            return
        }
        let ids = tabs[index].agentIDs
        let focused = tabs[index].focused
        let singles = ids.map { HerdrTab(agentID: $0) }
        tabs.replaceSubrange(index...index, with: singles)
        selectedTab = singles.first { $0.focused == focused }?.id ?? singles[0].id
    }

    func merge(_ sourceID: String, into targetID: String) {
        guard sourceID != targetID, let source = tab(sourceID), tab(targetID) != nil else {
            return
        }
        tabs.removeAll { $0.id == sourceID }
        updateTab(targetID) { tab in
            tab.layout = Self.adding(source.agentIDs, to: tab.layout)
            tab.focused = source.focused
            tab.zoomed = nil
        }
        selectedTab = targetID
    }

    func gatherAll(into targetID: String) {
        guard let target = tab(targetID) else { return }
        let ids = target.agentIDs + tabs.filter { $0.id != targetID }.flatMap(\.agentIDs)
        let arrangement: HerdrArrangement = ids.count >= 4 ? .grid : .columns
        tabs.removeAll { $0.id != targetID }
        updateTab(targetID) { tab in
            tab.layout = arrangement.layout(ids) ?? tab.layout
            tab.zoomed = nil
        }
        selectedTab = targetID
    }

    func canMerge(_ tabID: String) -> Bool {
        tabs.count > 1 && tab(tabID) != nil
    }

    static func adding(_ ids: [String], to layout: HerdrLayout) -> HerdrLayout {
        if let current = HerdrArrangement.matching(layout),
            let order = current.slotOrder(of: layout),
            let flowed = current.layout(order + ids)
        {
            return flowed
        }
        return ids.reduce(layout) { result, id in result.inserting(.pane(id), atEdge: .right) }
    }

    private func detachFromLayout(_ agentID: String) {
        guard let index = tabs.firstIndex(where: { $0.layout.contains(agentID) }) else { return }
        guard let remaining = tabs[index].layout.removing(agentID) else {
            let removed = tabs.remove(at: index)
            if selectedTab == removed.id { selectedTab = tabs.last?.id ?? Self.boardID }
            return
        }
        tabs[index].layout = remaining
        if tabs[index].focused == agentID { tabs[index].focused = remaining.panes[0] }
        if tabs[index].zoomed == agentID || !tabs[index].isSplit { tabs[index].zoomed = nil }
    }

    private func updateTab(_ id: String, _ body: (inout HerdrTab) -> Void) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        body(&tabs[index])
        if !tabs[index].layout.contains(tabs[index].focused) {
            tabs[index].focused = tabs[index].agentIDs.first ?? tabs[index].focused
        }
        if let zoomed = tabs[index].zoomed, !tabs[index].layout.contains(zoomed) {
            tabs[index].zoomed = nil
        }
    }

    func close(_ id: String) {
        closeSequentially([id][...])
    }

    func closeTab(_ tabID: String) {
        closeTabs { _, tab in tab.id == tabID }
    }

    func closeAgent(_ agent: HerdrAgent) async throws {
        try await agentCloser(agent)
        close(agent.id)
    }

    func closeOthers(besides id: String) {
        if id == Self.boardID {
            closeTabs { _, _ in true }
            return
        }
        closeTabs { _, tab in tab.id != id }
        selectedTab = id
    }

    func closeAll() {
        closeTabs { _, _ in true }
    }

    func closeToTheRight(of id: String) {
        if id == Self.boardID {
            closeTabs { _, _ in true }
            return
        }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTabs { i, _ in i > index }
    }

    func closeToTheLeft(of id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        closeTabs { i, _ in i < index }
    }

    func canCloseOthers(besides id: String) -> Bool {
        id == Self.boardID ? !tabs.isEmpty : tabs.count > 1
    }

    var canCloseAll: Bool {
        !tabs.isEmpty
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

    private func closeTabs(_ predicate: (Int, HerdrTab) -> Bool) {
        var tabIDs: [String] = []
        for offset in tabs.indices where predicate(offset, tabs[offset]) {
            tabIDs.append(tabs[offset].id)
        }
        guard !tabIDs.isEmpty else { return }
        terminalPanels.confirmClosing(owners: tabIDs) { [weak self] in
            self?.closeTabs(withIDs: Set(tabIDs))
        }
    }

    private func closeTabs(withIDs tabIDs: Set<String>) {
        var matchedAny = false
        var ids: [String] = []
        for offset in tabs.indices {
            let tab = tabs[offset]
            guard tabIDs.contains(tab.id) else { continue }
            matchedAny = true
            let rightNeighborID = offset + 1 < tabs.count ? tabs[offset + 1].id : nil
            var agentsInTab: [HerdrAgent] = []
            for agentID in tab.agentIDs {
                guard let found = session(agentID)?.agent else { continue }
                agentsInTab.append(found)
            }
            closedTabHistory.append(
                HerdrClosedTabRecord(
                    tabID: tab.id, layout: tab.layout, focused: tab.focused, zoomed: tab.zoomed,
                    agents: agentsInTab, rightNeighborID: rightNeighborID))
            if closedTabHistory.count > closedTabHistoryLimit { closedTabHistory.removeFirst() }
            for agentID in tab.agentIDs { ids.append(agentID) }
        }
        guard matchedAny else { return }
        closeSequentially(ids[...])
    }

    private func closeSequentially(_ ids: ArraySlice<String>) {
        guard let id = ids.first else { return }
        let remaining = ids.dropFirst()
        guard let index = sessions.firstIndex(where: { $0.id == id }) else {
            closeSequentially(remaining)
            return
        }
        if !sessions[index].agent.isTerminal {
            let holder = sessions[index].holder
            holder.stop()
            removeClosedSession(id, holder: holder)
            closeSequentially(remaining)
            return
        }
        let holder = sessions[index].holder
        requestUserClose(holder) { [weak self, weak holder] confirmed in
            guard let self else { return }
            if confirmed, let holder { self.removeClosedSession(id, holder: holder) }
            self.closeSequentially(remaining)
        }
    }

    private func removeClosedSession(_ id: String, holder: TerminalSessionHolder) {
        guard let index = sessions.firstIndex(where: { $0.id == id && $0.holder === holder })
        else {
            return
        }
        sessions[index].quinjet.stop()
        sessions.remove(at: index)
        detachFromLayout(id)
    }

    func normalized(_ item: HerdrDragItem) -> HerdrDragItem {
        guard case let .tab(id) = item, let tab = tab(id), !tab.isSplit,
            let agent = session(tab.focused)?.agent
        else { return item }
        return .agent(agent)
    }

    func snapCount(for item: HerdrDragItem) -> Int? {
        guard let tab = currentTab, case let .agent(agent) = normalized(item) else { return nil }
        let count = tab.agentIDs.count + (tab.layout.contains(agent.id) ? 0 : 1)
        return count >= 2 ? count : nil
    }

    func proposedLayout(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> HerdrLayout? {
        let item = normalized(item)
        guard let tab = currentTab, let dragged = draggedNode(item) else { return nil }
        if case let .tab(id) = item, id == tab.id { return nil }
        let ids = dragged.node.panes
        let base = ids.reduce(Optional(tab.layout)) { layout, id in layout?.removing(id) }
        switch target {
        case let .edge(pane, side):
            guard let base, !ids.contains(pane), base.contains(pane) else { return nil }
            return base.inserting(dragged.node, near: pane, side: side)
        case let .outerEdge(side):
            return base?.inserting(dragged.node, atEdge: side)
        case let .center(pane):
            guard case let .agent(agent) = item, agent.id != pane, tab.layout.contains(pane)
            else { return nil }
            return tab.layout.contains(agent.id)
                ? tab.layout.swapping(agent.id, pane) : tab.layout.replacing(pane, with: agent.id)
        case let .slot(template, index):
            guard case let .agent(agent) = item else { return nil }
            var order = base?.panes ?? []
            order.insert(agent.id, at: min(max(0, index), order.count))
            return template.layout(order)
        case .tabBar, .intoTab, .newTab, .window:
            return nil
        }
    }

    func accepts(_ item: HerdrDragItem, _ target: HerdrDropTarget) -> Bool {
        let item = normalized(item)
        if case let .agent(agent) = item, session(agent.id) == nil,
            HerdrSpaceWindow.holds(agent: agent.id)
        {
            return false
        }
        switch target {
        case .edge, .outerEdge, .center, .slot:
            return proposedLayout(item, target) != nil
        case let .tabBar(index):
            let moving: String?
            switch item {
            case let .tab(id):
                moving = id
            case let .agent(agent):
                let source = tab(containing: agent.id)
                moving = source?.isSplit == false ? source?.id : nil
            }
            guard let moving, let from = tabs.firstIndex(where: { $0.id == moving }) else {
                return true
            }
            return index != from && index != from + 1
        case let .intoTab(id):
            guard let destination = tab(id) else { return false }
            switch item {
            case let .tab(source): return source != id
            case let .agent(agent): return !destination.layout.contains(agent.id)
            }
        case .newTab, .window:
            if case .agent = item { return true }
            return false
        }
    }

    func drop(_ item: HerdrDragItem, on target: HerdrDropTarget) {
        let item = normalized(item)
        guard accepts(item, target) else { return }
        switch target {
        case .edge, .outerEdge, .center, .slot:
            place(item, target)
        case let .tabBar(index):
            insertTab(item, at: index)
        case let .intoTab(id):
            switch item {
            case let .tab(source): merge(source, into: id)
            case let .agent(agent): add(agent, into: id)
            }
        case .newTab:
            guard case let .agent(agent) = item else { return }
            if tab(containing: agent.id)?.isSplit == true {
                moveToNewTab(agent.id)
            } else {
                open(agent)
            }
        case .window:
            break
        }
    }

    func moveTab(_ id: String, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        let destination = index > from ? index - 1 : index
        tabs.insert(tab, at: min(max(0, destination), tabs.count))
    }

    private func draggedNode(_ item: HerdrDragItem) -> (node: HerdrLayout, focus: String)? {
        switch item {
        case let .agent(agent):
            return (.pane(agent.id), agent.id)
        case let .tab(id):
            guard let tab = tab(id) else { return nil }
            return (tab.layout, tab.focused)
        }
    }

    private func place(_ item: HerdrDragItem, _ target: HerdrDropTarget) {
        guard let current = currentTab, let layout = proposedLayout(item, target),
            let dragged = draggedNode(item)
        else { return }
        var displaced: String?
        switch item {
        case let .agent(agent):
            if session(agent.id) == nil {
                adoptSession(for: agent, showing: nil)
                if case let .center(pane) = target { displaced = pane }
            } else if let source = tab(containing: agent.id), source.id != current.id {
                if case let .center(pane) = target {
                    updateTab(source.id) { tab in
                        tab.layout = tab.layout.replacing(agent.id, with: pane)
                        if tab.focused == agent.id { tab.focused = pane }
                        if tab.zoomed == agent.id { tab.zoomed = pane }
                    }
                } else {
                    detachFromLayout(agent.id)
                }
            }
            revealSpace(containing: agent)
        case let .tab(id):
            tabs.removeAll { $0.id == id }
        }
        updateTab(current.id) { tab in
            tab.layout = layout
            tab.focused = dragged.focus
            tab.zoomed = nil
        }
        if let displaced, let index = tabs.firstIndex(where: { $0.id == current.id }) {
            tabs.insert(HerdrTab(agentID: displaced), at: index + 1)
        }
        selectedTab = current.id
    }

    private func insertTab(_ item: HerdrDragItem, at index: Int) {
        switch item {
        case let .tab(id):
            moveTab(id, to: index)
            selectedTab = id
        case let .agent(agent):
            if let source = tab(containing: agent.id), !source.isSplit {
                moveTab(source.id, to: index)
                selectedTab = source.id
                return
            }
            if session(agent.id) == nil {
                adoptSession(for: agent, showing: nil)
            } else {
                detachFromLayout(agent.id)
            }
            let tab = HerdrTab(agentID: agent.id)
            tabs.insert(tab, at: min(max(0, index), tabs.count))
            revealSpace(containing: agent)
            selectedTab = tab.id
        }
    }

    private func add(_ agent: HerdrAgent, into tabID: String) {
        if session(agent.id) == nil {
            adoptSession(for: agent, showing: nil)
        } else {
            detachFromLayout(agent.id)
        }
        updateTab(tabID) { tab in
            tab.layout = Self.adding([agent.id], to: tab.layout)
            tab.focused = agent.id
            tab.zoomed = nil
        }
        revealSpace(containing: agent)
        selectedTab = tabID
    }

    func selectBoard() {
        selectedTab = Self.boardID
    }

    var orderedTabIDs: [String] { [Self.boardID] + tabs.map(\.id) }

    @discardableResult
    func cycleTab(backwards: Bool) -> Bool {
        let ids = orderedTabIDs
        guard ids.count > 1, let index = ids.firstIndex(of: selectedTab) else { return false }
        let next = backwards ? (index - 1 + ids.count) % ids.count : (index + 1) % ids.count
        selectedTab = ids[next]
        return true
    }

    @discardableResult
    func closeFocusedTab() -> Bool {
        guard selectedTab != Self.boardID else { return false }
        if let tab = currentTab, tab.isSplit {
            close(tab.focused)
        } else {
            closeTab(selectedTab)
        }
        return true
    }

    @discardableResult
    func reopenLastClosedTab() -> Bool {
        while let candidate = closedTabHistory.popLast() {
            let liveAgents = candidate.agents.filter { recorded in
                agents.contains { $0.id == recorded.id }
            }
            guard !liveAgents.isEmpty else { continue }
            openReopenedTab(candidate, liveAgents: liveAgents)
            return true
        }
        return false
    }

    private func openReopenedTab(_ record: HerdrClosedTabRecord, liveAgents: [HerdrAgent]) {
        for agent in liveAgents where !sessions.contains(where: { $0.id == agent.id }) {
            adoptSession(for: agent, showing: nil)
        }
        let liveIDs = Set(liveAgents.map(\.id))
        var layout = record.layout
        for pane in record.layout.panes where !liveIDs.contains(pane) {
            layout = layout.removing(pane) ?? layout
        }
        var tab = HerdrTab(id: record.tabID, agentID: liveAgents[0].id)
        tab.layout = layout
        tab.focused = liveIDs.contains(record.focused) ? record.focused : liveAgents[0].id
        tab.zoomed = record.zoomed.flatMap { liveIDs.contains($0) ? $0 : nil }
        if let rightNeighborID = record.rightNeighborID,
            let index = tabs.firstIndex(where: { $0.id == rightNeighborID })
        {
            tabs.insert(tab, at: index)
        } else {
            tabs.append(tab)
        }
        revealSpace(containing: liveAgents[0])
        selectedTab = tab.id
    }

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
        return try await QuinjetRemote.connected(
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
        try await uploadDroppedFiles(urls, to: tab.machine)
    }

    func uploadDroppedFiles(_ urls: [URL], to machine: Machine?) async throws -> [String] {
        guard let machine else { throw HerdrQuinjetError.machineUnavailable }
        return try await TerminalDropTransfer.upload(urls, over: connection(for: machine))
    }

    func machine(for host: HerdrHostSnapshot) -> Machine? {
        host.isLocal ? nil : machinesProvider().first { $0.id.uuidString == host.id }
    }

    func launchNewAgent(
        kind: String, host: HerdrHostSnapshot, existingSpace: HerdrWorkspaceSummary?,
        newSpaceLabel: String?, openBeside: Bool = false
    ) async throws {
        let created = try await newAgentLauncher(
            kind, machine(for: host), existingSpace, newSpaceLabel)
        let placeholder = HerdrAgent.make(
            machineID: host.id, machineName: host.name, machineIsLocal: host.isLocal,
            sshTarget: host.sshTarget, session: "default", pane: created.paneID, kind: kind,
            status: .unknown, title: kind,
            workspace: existingSpace?.label ?? newSpaceLabel ?? "", cwd: "")
        if openBeside {
            open(placeholder, beside: .right)
        } else {
            open(placeholder)
        }
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
        return try await controlRequest(
            for: tab.agent, machine: tab.machine, environment: environment,
            localExecutable: localExecutable, bridgeExecutable: bridgeExecutable,
            mouse: .buttons)
    }

    func attachRequest(
        for terminal: HerdrPanelTerminal, environment: [String],
        localExecutable: URL? = HerdrCollector.executable(),
        bridgeExecutable: URL? = HerdrTerminalBridge.executable()
    ) async throws -> TerminalLaunchRequest {
        guard let agent = terminal.bridgeAgent else {
            throw HerdrTerminalBridgeError.invalidSpecification
        }
        return try await controlRequest(
            for: agent, machine: terminal.host.machine, environment: environment,
            localExecutable: localExecutable, bridgeExecutable: bridgeExecutable,
            mouse: terminalSettings.mouse)
    }

    var terminalSettings: HerdrTerminalSettings { HerdrTerminalSettings.load(defaults) }

    private func controlRequest(
        for agent: HerdrAgent, machine: Machine?, environment: [String],
        localExecutable: URL?, bridgeExecutable: URL?, mouse: HerdrTerminalMouse
    ) async throws -> TerminalLaunchRequest {
        guard let bridgeExecutable else {
            throw HerdrTerminalBridgeError.executableUnavailable
        }
        let controller: TerminalLaunchRequest
        if agent.machineIsLocal {
            controller = HerdrOperationExecution.localControlRequest(
                for: agent, environment: environment, executable: localExecutable)
        } else {
            guard let machine else {
                throw HerdrQuinjetError.machineUnavailable
            }
            let connection = try await connection(for: machine)
            let platform = await connection.remotePlatform ?? .linux
            controller = HerdrOperationExecution.remoteControlRequest(
                for: agent, connection: connection, environment: environment,
                platform: platform)
        }
        return try HerdrTerminalBridge.launchRequest(
            bridgeExecutable: bridgeExecutable, controller: controller, mouse: mouse)
    }

    func terminalOrigins(for owner: String) -> [HerdrTerminalOrigin] {
        guard owner != Self.boardID, let tab = tab(owner) else { return [.local] }
        let startFolder = terminalSettings.startFolder
        var origins: [HerdrTerminalOrigin] = []
        for agentID in tab.agentIDs {
            guard let session = session(agentID) else { continue }
            origins.append(HerdrTerminalOrigin(session, startFolder: startFolder))
        }
        return origins.isEmpty ? [.local] : origins
    }

    func terminalOrigin(for owner: String) -> HerdrTerminalOrigin {
        let origins = terminalOrigins(for: owner)
        let focused = tab(owner)?.focused
        return origins.first { $0.id == focused } ?? origins[0]
    }

    func openTerminal(in owner: String, from origin: HerdrTerminalOrigin) {
        terminalPanels.newTerminal(in: owner, host: origin.host, cwd: origin.cwd)
    }

    func performTerminalPanelKey(
        keyCode: UInt16, characters: String?, modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard
            let key = HerdrTerminalPanelKey.resolve(
                keyCode: keyCode, characters: characters, modifiers: modifiers)
        else { return false }
        perform(key)
        return true
    }

    func perform(_ key: HerdrTerminalPanelKey) {
        let owner = selectedTab
        let origin = terminalOrigin(for: owner)
        switch key {
        case .toggle:
            terminalPanels.toggle(owner, host: origin.host, cwd: origin.cwd)
        case .visibility:
            terminalPanels.toggleVisibility(owner, host: origin.host, cwd: origin.cwd)
        case .new:
            openTerminal(in: owner, from: origin)
        }
    }

    private func scheduleTerminalRetarget(from previous: [HerdrTab]) {
        guard !terminalPanels.isEmpty, tabsBeforeRetarget == nil else { return }
        tabsBeforeRetarget = previous
        Task { @MainActor [weak self] in self?.retargetTerminals() }
    }

    func retargetTerminals() {
        guard let previous = tabsBeforeRetarget else { return }
        tabsBeforeRetarget = nil
        terminalPanels.retarget(previous: previous, current: tabs, fallback: Self.boardID)
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

struct HerdrTab: Identifiable, Equatable {
    let id: String
    var layout: HerdrLayout
    var focused: String
    var zoomed: String?

    init(id: String = UUID().uuidString, agentID: String) {
        self.id = id
        layout = .pane(agentID)
        focused = agentID
    }

    var agentIDs: [String] { layout.panes }
    var isSplit: Bool { layout.paneCount > 1 }
}

enum HerdrLayoutKey: Equatable {
    case focus(InsertSide)
    case cycle(backwards: Bool)
    case zoom

    static func resolve(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> HerdrLayoutKey? {
        let flags = modifiers.chordOnly
        if flags == [.command, .shift], keyCode == 36 { return .zoom }
        if keyCode == 50, flags == .option { return .cycle(backwards: false) }
        if keyCode == 50, flags == [.option, .shift] { return .cycle(backwards: true) }
        guard flags == [.command, .option] else { return nil }
        switch keyCode {
        case 123: return .focus(.left)
        case 124: return .focus(.right)
        case 125: return .focus(.bottom)
        case 126: return .focus(.top)
        default: return nil
        }
    }
}
