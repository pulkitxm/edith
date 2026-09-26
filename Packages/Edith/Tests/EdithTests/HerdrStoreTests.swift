import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private actor HerdrFleetConcurrencyHarness {
    private var active: Set<UUID> = []
    private var visited: Set<UUID> = []
    private var maximumActive = 0
    private var duplicateActive = false

    func collect(_ machine: Machine) async -> HerdrHostSnapshot {
        enter(machine)
        try? await Task.sleep(for: .milliseconds(15))
        leave(machine)
        return snapshot(machine)
    }

    func watch(_ machine: Machine) async {
        enter(machine)
        try? await Task.sleep(for: .milliseconds(25))
        leave(machine)
    }

    func waitForUniqueVisits(_ count: Int, timeout: Duration = .seconds(2)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while visited.count < count, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return visited.count >= count
    }

    func result() -> (maximumActive: Int, duplicateActive: Bool, visits: Int) {
        (maximumActive, duplicateActive, visited.count)
    }

    private func enter(_ machine: Machine) {
        if active.contains(machine.id) { duplicateActive = true }
        active.insert(machine.id)
        visited.insert(machine.id)
        maximumActive = max(maximumActive, active.count)
    }

    private func leave(_ machine: Machine) {
        active.remove(machine.id)
    }

    private func snapshot(_ machine: Machine) -> HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: machine.id.uuidString, name: machine.name, isLocal: false,
            sshTarget: machine.sshTarget, herdrPresent: true, reachable: true)
    }
}

private actor HerdrWatchHarness {
    private var callbacks: [@Sendable ([HerdrHostSnapshot]) -> Void] = []

    func watch(_ callback: @escaping @Sendable ([HerdrHostSnapshot]) -> Void) async {
        callbacks.append(callback)
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func waitForCallbacks(_ count: Int) async {
        while callbacks.count < count {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    func send(_ hosts: [HerdrHostSnapshot], through index: Int) {
        callbacks[index](hosts)
    }
}

@MainActor
@Suite struct HerdrStoreTests {
    @Test func fleetCollectionPreservesOrderWithinTheConcurrencyLimit() async {
        let machines = (0..<24).map { Machine(name: "machine-\($0)", host: "host-\($0)") }
        let harness = HerdrFleetConcurrencyHarness()

        let snapshots = await HerdrCollector.collectRemotes(
            machines, maximumInFlight: 3
        ) { machine in
            await harness.collect(machine)
        }

        let result = await harness.result()
        #expect(snapshots.map(\.id) == machines.map { $0.id.uuidString })
        #expect(result.maximumActive == 3)
        #expect(!result.duplicateActive)
        #expect(result.visits == machines.count)
    }

    @Test func liveFleetWatchersAreBoundedFairAndCancellationOwned() async {
        let machines = (0..<17).map { Machine(name: "machine-\($0)", host: "host-\($0)") }
        let harness = HerdrFleetConcurrencyHarness()
        let watching = Task {
            await HerdrLive.watchRemotes(machines, maximumInFlight: 4) { machine in
                await harness.watch(machine)
            }
        }

        #expect(await harness.waitForUniqueVisits(machines.count))
        let cancellationStarted = ContinuousClock.now
        watching.cancel()
        await watching.value
        let cancellationElapsed = ContinuousClock.now - cancellationStarted

        let result = await harness.result()
        #expect(result.maximumActive == 4)
        #expect(!result.duplicateActive)
        #expect(result.visits == machines.count)
        #expect(cancellationElapsed < .seconds(1))
    }

    @Test func kindPillsAccumulateLikeCheckboxes() {
        let store = HerdrStore()
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("Codex", exclusive: false)
        #expect(store.kindFilter == ["Claude Code", "Codex"])
        #expect(store.kindIsSelected("Claude Code"))
        #expect(!store.kindIsSelected("all"))
        store.selectKind("Claude Code", exclusive: false)
        #expect(store.kindFilter == ["Codex"])
        store.selectKind("Codex", exclusive: false)
        #expect(store.kindFilter.isEmpty)
        #expect(store.kindIsSelected("all"))
    }

    @Test func commandClickKeepsOnlyThatKind() {
        let store = HerdrStore()
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("Codex", exclusive: false)
        store.selectKind("OpenCode", exclusive: true)
        #expect(store.kindFilter == ["OpenCode"])
        store.selectKind("all", exclusive: true)
        #expect(store.kindFilter.isEmpty)
    }

    @Test func closeOthersKeepsTheClickedTab() {
        let store = seededStore()
        let keep = store.tabs[1].id
        store.selectedTab = store.tabs[0].id
        store.closeOthers(besides: keep)
        #expect(store.tabs.map(\.id) == [keep])
        #expect(store.selectedTab == keep)
    }

    @Test func liveAgentTabsDetachWithoutTerminalCloseRequests() {
        var requested: [ObjectIdentifier] = []
        let store = seededStore { holder, completion in
            requested.append(ObjectIdentifier(holder))
            completion(false)
        }
        let keep = store.tabs[0].id
        let first = store.sessions[1]
        let second = store.sessions[2]
        first.holder.start(executable: "/bin/cat", arguments: [], environment: [])
        second.holder.start(executable: "/bin/cat", arguments: [], environment: [])

        store.closeOthers(besides: keep)

        #expect(requested.isEmpty)
        #expect(store.tabs.map(\.id) == [keep])
        #expect(store.sessions.map(\.id) == [store.tabs[0].focused])
        #expect(store.selectedTab == keep)
        #expect(!first.holder.started)
        #expect(!second.holder.started)
    }

    @Test func herdrTerminalTabsKeepTerminalCloseConfirmation() throws {
        var decisions: [(Bool) -> Void] = []
        var requested: [ObjectIdentifier] = []
        let store = HerdrStore(
            requestUserClose: { holder, completion in
                requested.append(ObjectIdentifier(holder))
                decisions.append(completion)
            })
        let terminal = HerdrMachineTerminal.agent(
            for: .local(herdrPresent: true))
        store.open(terminal)
        let holder = try #require(store.sessions.first?.holder)

        store.close(terminal.id)

        #expect(requested == [ObjectIdentifier(holder)])
        #expect(store.sessions.map(\.id) == [terminal.id])
        decisions[0](false)
        #expect(store.sessions.map(\.id) == [terminal.id])

        store.close(terminal.id)

        #expect(requested == [ObjectIdentifier(holder), ObjectIdentifier(holder)])
        decisions[1](true)
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func closeAllReturnsToTheBoard() {
        let store = seededStore()

        #expect(store.canCloseAll)
        store.closeAll()

        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
        #expect(!store.canCloseAll)
    }

    @Test func closeToTheRightDropsLaterTabs() {
        let store = seededStore()
        let first = store.tabs[0].id
        store.selectedTab = store.tabs[2].id
        store.closeToTheRight(of: first)
        #expect(store.tabs.map(\.id) == [first])
        #expect(store.selectedTab == first)
        store.closeToTheRight(of: HerdrStore.boardID)
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func closeToTheLeftDropsEarlierTabs() {
        let store = seededStore()
        let last = store.tabs[2].id
        store.closeToTheLeft(of: last)
        #expect(store.tabs.map(\.id) == [last])
        #expect(store.canCloseToTheLeft(of: last) == false)
        #expect(store.canCloseToTheRight(of: last) == false)
    }

    @Test func cycleTabWrapsForwardAndBackwardThroughTheBoard() {
        let store = seededStore()
        let ids = store.orderedTabIDs
        #expect(ids == [HerdrStore.boardID] + store.tabs.map(\.id))

        store.selectedTab = ids.last!
        #expect(store.cycleTab(backwards: false))
        #expect(store.selectedTab == ids[0])

        #expect(store.cycleTab(backwards: true))
        #expect(store.selectedTab == ids.last!)
    }

    @Test func cycleTabFailsWithNoOpenTabs() {
        let store = HerdrStore()
        #expect(store.cycleTab(backwards: false) == false)
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func closeFocusedTabIgnoresTheBoard() {
        let store = seededStore()
        store.selectedTab = HerdrStore.boardID
        #expect(store.closeFocusedTab() == false)
        #expect(store.tabs.count == 3)
    }

    @Test func closeFocusedTabClosesTheSelectedTab() {
        let store = seededStore()
        let focused = store.tabs[2].id
        store.selectedTab = focused
        #expect(store.closeFocusedTab())
        #expect(!store.tabs.contains { $0.id == focused })
    }

    @Test func reopenLastClosedTabWalksBackThroughHistory() {
        let store = HerdrStore()
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.hosts = [.local(herdrPresent: true, agents: [claude, codex])]
        store.open(claude)
        store.open(codex)

        store.closeTab(store.tab(containing: claude.id)!.id)
        store.closeTab(store.tab(containing: codex.id)!.id)
        #expect(store.tabs.isEmpty)

        #expect(store.reopenLastClosedTab())
        #expect(store.currentTab?.agentIDs == [codex.id])

        #expect(store.reopenLastClosedTab())
        #expect(store.currentTab?.agentIDs == [claude.id])

        #expect(store.reopenLastClosedTab() == false)
    }

    @Test func reopenLastClosedTabSkipsAgentsThatAreNoLongerLive() {
        let store = HerdrStore()
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.hosts = [.local(herdrPresent: true, agents: [claude, codex])]
        store.open(claude)
        store.open(codex)

        store.closeTab(store.tab(containing: claude.id)!.id)
        store.hosts = [.local(herdrPresent: true, agents: [codex])]
        store.closeTab(store.tab(containing: codex.id)!.id)

        #expect(store.reopenLastClosedTab())
        #expect(store.currentTab?.agentIDs == [codex.id])
        #expect(store.reopenLastClosedTab() == false)
    }

    @Test func reopeningEachTabAfterABatchCloseRestoresTheOriginalOrder() {
        let store = HerdrStore()
        let one = agent("Claude Code", pane: "1")
        let two = agent("Codex", pane: "2")
        let three = agent("OpenCode", pane: "3")
        store.hosts = [.local(herdrPresent: true, agents: [one, two, three])]
        store.open(one)
        store.open(two)
        store.open(three)

        store.closeAll()
        #expect(store.reopenLastClosedTab())
        #expect(store.reopenLastClosedTab())
        #expect(store.reopenLastClosedTab())

        #expect(store.tabs.flatMap(\.agentIDs) == [one.id, two.id, three.id])
    }

    @Test func reopeningASingleClosedTabRestoresItsOriginalPosition() {
        let store = HerdrStore()
        let one = agent("Claude Code", pane: "1")
        let two = agent("Codex", pane: "2")
        let three = agent("OpenCode", pane: "3")
        store.hosts = [.local(herdrPresent: true, agents: [one, two, three])]
        store.open(one)
        store.open(two)
        store.open(three)

        store.closeTab(store.tab(containing: two.id)!.id)
        #expect(store.tabs.flatMap(\.agentIDs) == [one.id, three.id])

        #expect(store.reopenLastClosedTab())
        #expect(store.tabs.flatMap(\.agentIDs) == [one.id, two.id, three.id])
    }

    @Test func reopenLastClosedTabSkipsAnAgentThatIsAlreadyOpen() {
        let store = HerdrStore()
        let claude = agent("Claude Code", pane: "a")
        store.hosts = [.local(herdrPresent: true, agents: [claude])]
        store.open(claude)
        store.closeTab(store.selectedTab)
        store.open(claude)
        let reopenedTabID = store.selectedTab

        #expect(store.reopenLastClosedTab() == false)
        #expect(store.tabs.count == 1)
        #expect(store.currentTab?.agentIDs == [claude.id])
        #expect(store.selectedTab == reopenedTabID)

        store.selectBoard()
        #expect(store.selectedTab == HerdrStore.boardID)
    }

    @Test func reopenLastClosedTabHistoryIsBoundedToTenEntries() {
        let store = HerdrStore()
        let agents = (0..<11).map { agent("Claude Code", pane: "p\($0)") }
        store.hosts = [.local(herdrPresent: true, agents: agents)]
        for candidate in agents { store.open(candidate) }
        store.closeAll()

        for candidate in agents[1...].reversed() {
            #expect(store.reopenLastClosedTab())
            #expect(store.currentTab?.agentIDs == [candidate.id])
        }
        #expect(store.reopenLastClosedTab() == false)
        #expect(store.tabs.flatMap(\.agentIDs) == agents[1...].map(\.id))
    }

    private func seededStore(
        requestUserClose: @escaping HerdrStore.UserCloseRequester = { holder, completion in
            holder.requestUserClose(completion)
        }
    ) -> HerdrStore {
        let store = HerdrStore(requestUserClose: requestUserClose)
        store.open(agent("Claude Code", pane: "a"))
        store.open(agent("Codex", pane: "b"))
        store.open(agent("OpenCode", pane: "c"))
        store.selectedTab = store.tabs[2].id
        return store
    }

    @Test func multipleKindsPassTheBoardFilter() {
        let store = HerdrStore()
        store.hosts = [
            .local(
                herdrPresent: true,
                agents: [
                    agent("Claude Code", pane: "a"),
                    agent("Codex", pane: "b"),
                    agent("OpenCode", pane: "c"),
                ])
        ]
        store.selectKind("Claude Code", exclusive: false)
        store.selectKind("OpenCode", exclusive: false)
        #expect(Set(store.filteredAgents.map(\.kind)) == ["Claude Code", "OpenCode"])
    }

    @Test func applyReplacesHostsAndOpenTabAgents() {
        let store = seededStore()
        let updated = agent("Claude Code", pane: "a")
        store.apply([
            .local(herdrPresent: true, agents: [updated])
        ])
        #expect(store.hosts.first?.agents.map(\.id) == [updated.id])
        #expect(
            store.sessions.contains { $0.agent.id == updated.id && $0.agent.kind == "Claude Code" })
    }

    @Test func stoppedAndReplacedWatchersCannotPublish() async {
        let harness = HerdrWatchHarness()
        let store = HerdrStore { callback in await harness.watch(callback) }
        defer { store.stopWatching() }
        let old = HerdrHostSnapshot.local(
            herdrPresent: true, agents: [agent("Codex", pane: "old")])
        let fresh = HerdrHostSnapshot.local(
            herdrPresent: true, agents: [agent("Codex", pane: "fresh")])

        await store.watch()
        await harness.waitForCallbacks(1)
        store.stopWatching()
        await harness.send([old], through: 0)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(store.hosts.isEmpty)

        await store.watch()
        await harness.waitForCallbacks(2)
        await harness.send([old], through: 0)
        await harness.send([fresh], through: 1)
        try? await Task.sleep(for: HerdrStore.settleWindow * 3)
        #expect(store.hosts.first?.agents.first?.pane == "fresh")
    }

    @Test func machineChangesRebuildTheLiveFleet() async {
        let harness = HerdrWatchHarness()
        let store = HerdrStore { callback in await harness.watch(callback) }
        defer { store.stopWatching() }
        let stale = HerdrHostSnapshot.local(
            herdrPresent: true, agents: [agent("Codex", pane: "stale")])
        let fresh = HerdrHostSnapshot.local(
            herdrPresent: true, agents: [agent("Codex", pane: "fresh")])

        await store.watch()
        await harness.waitForCallbacks(1)
        await store.machinesDidChange()
        await harness.waitForCallbacks(2)
        await harness.send([stale], through: 0)
        await harness.send([fresh], through: 1)
        try? await Task.sleep(for: HerdrStore.settleWindow * 3)

        #expect(store.hosts.first?.agents.first?.pane == "fresh")
    }

    @Test func partialReplacementSnapshotsKeepConfiguredHostsVisible() async {
        let store = HerdrStore()
        let local = HerdrHostSnapshot.local(
            herdrPresent: true, agents: [agent("Codex", pane: "visible")])
        store.apply([local])

        store.settle([])
        try? await Task.sleep(for: HerdrStore.settleWindow * 3)

        #expect(store.hosts.map(\.id) == [HerdrHostSnapshot.localID])
    }

    @Test func localAgentAttachmentUsesTheRawTerminalBridge() async throws {
        let store = HerdrStore()
        let selected = agent("Codex", pane: "pane-1")
        store.open(selected)
        let tab = try #require(store.sessions.first)
        let executable = URL(fileURLWithPath: "/tmp/herdr")
        let bridge = URL(fileURLWithPath: "/tmp/ed")
        let environment = ["TERM=xterm-256color"]

        let request = try await store.attachRequest(
            for: tab, environment: environment, localExecutable: executable,
            bridgeExecutable: bridge)
        let controller = HerdrOperationExecution.localControlRequest(
            for: selected, environment: environment, executable: executable)
        let expected = try HerdrTerminalBridge.launchRequest(
            bridgeExecutable: bridge, controller: controller)

        #expect(request == expected)
    }

    @Test func openingADiffRemembersItForThatAgent() {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude, showing: .diff)
        store.open(codex)
        #expect(store.view(for: claude.id) == .diff)
        #expect(store.view(for: codex.id) == .agent)
        #expect(HerdrAgentViews.view(for: claude.id, defaults) == .diff)
    }

    @Test func reopeningAnAgentRestoresItsLastView() {
        let defaults = Self.scratchDefaults()
        let first = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        first.open(claude, showing: .diff)
        first.close(claude.id)

        let second = HerdrStore(defaults: defaults)
        second.open(claude)
        #expect(second.view(for: claude.id) == .diff)
        #expect(second.sessions.first?.view == .diff)
    }

    @Test func switchingBackToTheAgentSticks() {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        store.open(claude, showing: .diff)
        store.setView(.agent, for: claude.id)
        #expect(store.sessions.first?.view == .agent)
        #expect(HerdrAgentViews.view(for: claude.id, defaults) == .agent)
    }

    @Test func detachedAgentSwitchesViewsImmediately() throws {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        _ = store.detachedTab(for: claude)

        store.setView(.split, for: claude.id)

        #expect(store.view(for: claude.id) == .split)
        #expect(try #require(store.detachedTab(id: claude.id)).view == .split)
        #expect(HerdrAgentViews.view(for: claude.id, defaults) == .split)
    }

    @Test func openingAnAlreadyOpenAgentSwitchesItsView() {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        store.open(claude)
        store.open(agent("Codex", pane: "b"))
        store.open(claude, showing: .diff)
        #expect(store.tabs.count == 2)
        #expect(store.currentTab?.focused == claude.id)
        #expect(store.view(for: claude.id) == .diff)
    }

    @Test func viewSurvivesUnrelatedTabChurn() {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        let codex = agent("Codex", pane: "b")
        store.open(claude, showing: .diff)
        store.open(codex)
        store.close(codex.id)
        #expect(store.view(for: claude.id) == .diff)
        #expect(store.sessions.first?.view == .diff)
    }

    @Test func launchNewAgentResolvesTheLocalHostToANilMachine() async throws {
        actor Recorder {
            var calls:
                [(kind: String, machine: Machine?, space: HerdrWorkspaceSummary?, label: String?)] =
                    []
            func record(
                _ kind: String, _ machine: Machine?, _ space: HerdrWorkspaceSummary?,
                _ label: String?
            ) {
                calls.append((kind, machine, space, label))
            }
        }
        let recorder = Recorder()
        let store = HerdrStore(
            newAgentLauncher: { kind, machine, space, label in
                await recorder.record(kind, machine, space, label)
                return HerdrCreatedPane(workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1")
            })

        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: "new-space")

        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].kind == "Claude Code")
        #expect(calls[0].machine == nil)
        #expect(calls[0].space == nil)
        #expect(calls[0].label == "new-space")
        #expect(store.tabs.map(\.agentIDs) == [["local|default|w9:p1"]])
        #expect(store.currentTab?.agentIDs == ["local|default|w9:p1"])
        #expect(store.sessions.first?.agent.workspace == "new-space")
    }

    @Test func launchNewAgentResolvesARemoteHostToItsMachine() async throws {
        let machine = Machine(name: "tuf-wired", host: "tuf-wired.local")
        actor Recorder {
            var machines: [Machine?] = []
            func record(_ machine: Machine?) { machines.append(machine) }
        }
        let recorder = Recorder()
        let store = HerdrStore(
            newAgentLauncher: { _, machine, _, _ in
                await recorder.record(machine)
                return HerdrCreatedPane(workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p2")
            },
            machinesProvider: { [machine] })
        let space = HerdrWorkspaceSummary(id: "w1", label: "edith", tabCount: 1, paneCount: 1)

        try await store.launchNewAgent(
            kind: "Codex",
            host: HerdrHostSnapshot(
                id: machine.id.uuidString, name: machine.name, isLocal: false, herdrPresent: true,
                reachable: true),
            existingSpace: space, newSpaceLabel: nil)

        #expect(await recorder.machines == [machine])
        #expect(store.sessions.first?.agent.workspace == "edith")
    }

    @Test func launchNewAgentOpensBesideTheCurrentTabWhenRequested() async throws {
        let existing = agent("Claude Code", pane: "existing")
        let store = HerdrStore(
            newAgentLauncher: { _, _, _, _ in
                HerdrCreatedPane(workspaceID: "w9", tabID: "w9:t1", paneID: "w9:p1")
            })
        store.hosts = [.local(herdrPresent: true, agents: [existing])]
        store.open(existing)
        let existingTabID = store.selectedTab

        try await store.launchNewAgent(
            kind: "Codex", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: "new-space", openBeside: true)

        #expect(store.tabs.count == 1)
        #expect(store.selectedTab == existingTabID)
        #expect(store.currentTab?.isSplit == true)
        #expect(store.currentTab?.agentIDs.contains("local|default|w9:p1") == true)
    }

    @Test func aSideBySideTabGroupsItsAgentsAndMarksTheFocusedOne() {
        let first = agent("Claude Code", pane: "p1")
        let second = agent("Codex", pane: "p2")
        let other = agent("Grok", pane: "p3")
        let store = HerdrStore(defaults: Self.scratchDefaults(), liveWatcher: { _ in })
        store.hosts = [.local(herdrPresent: true, agents: [first, second, other])]
        store.open(first)
        #expect(store.openSplitAgents.isEmpty)
        #expect(store.railHighlight(for: first.id) == .solo)
        #expect(store.railHighlight(for: second.id) == .none)

        store.open(second, beside: .right)
        #expect(store.openSplitAgents.map(\.id) == [first.id, second.id])
        #expect(store.railHighlight(for: second.id) == .focused)
        #expect(store.railHighlight(for: first.id) == .grouped)
        #expect(store.railHighlight(for: other.id) == .none)

        store.focus(first.id)
        #expect(store.railHighlight(for: first.id) == .focused)
        #expect(store.railHighlight(for: second.id) == .grouped)

        store.selectedTab = HerdrStore.boardID
        #expect(store.openSplitAgents.isEmpty)
        #expect(store.railHighlight(for: first.id) == .none)
    }

    @Test func launchNewAgentPropagatesLauncherErrors() async {
        struct LaunchFailure: Error {}
        let store = HerdrStore(newAgentLauncher: { _, _, _, _ in throw LaunchFailure() })
        await #expect(throws: LaunchFailure.self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: "x")
        }
        #expect(store.tabs.isEmpty)
    }

    private static func scratchDefaults() -> UserDefaults {
        let suite = "HerdrStoreTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func agent(_ kind: String, pane: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: "")
    }
}
