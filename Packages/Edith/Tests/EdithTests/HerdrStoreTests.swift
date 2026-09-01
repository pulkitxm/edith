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

    @Test func liveAgentTabsCloseSequentiallyAndKeepCancellations() throws {
        var decisions: [ObjectIdentifier: (Bool) -> Void] = [:]
        var requested: [ObjectIdentifier] = []
        let store = seededStore { holder, completion in
            requested.append(ObjectIdentifier(holder))
            decisions[ObjectIdentifier(holder)] = completion
        }
        let keep = store.tabs[0]
        let cancel = store.tabs[1]
        let confirm = store.tabs[2]

        store.closeOthers(besides: keep.id)

        #expect(requested == [ObjectIdentifier(cancel.holder)])
        let cancelDecision = try #require(decisions[ObjectIdentifier(cancel.holder)])
        cancelDecision(false)

        #expect(store.tabs.contains { $0.id == cancel.id })
        #expect(
            requested
                == [ObjectIdentifier(cancel.holder), ObjectIdentifier(confirm.holder)])
        let confirmDecision = try #require(decisions[ObjectIdentifier(confirm.holder)])
        confirmDecision(true)

        #expect(store.tabs.map(\.id) == [keep.id, cancel.id])
        #expect(store.selectedTab == keep.id)
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

    private func seededStore(
        requestUserClose: @escaping HerdrStore.UserCloseRequester = { holder, completion in
            holder.requestUserClose(completion)
        }
    ) -> HerdrStore {
        let store = HerdrStore(requestUserClose: requestUserClose)
        store.tabs = [
            HerdrOpenTab(
                agent: agent("Claude Code", pane: "a"), machine: nil,
                holder: TerminalSessionHolder(), quinjet: HerdrQuinjetSession()),
            HerdrOpenTab(
                agent: agent("Codex", pane: "b"), machine: nil, holder: TerminalSessionHolder(),
                quinjet: HerdrQuinjetSession()),
            HerdrOpenTab(
                agent: agent("OpenCode", pane: "c"), machine: nil, holder: TerminalSessionHolder(),
                quinjet: HerdrQuinjetSession()),
        ]
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
        #expect(store.tabs.contains { $0.agent.id == updated.id && $0.agent.kind == "Claude Code" })
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
        let tab = try #require(store.tabs.first)
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
        #expect(second.tabs.first?.view == .diff)
    }

    @Test func switchingBackToTheAgentSticks() {
        let defaults = Self.scratchDefaults()
        let store = HerdrStore(defaults: defaults)
        let claude = agent("Claude Code", pane: "a")
        store.open(claude, showing: .diff)
        store.setView(.agent, for: claude.id)
        #expect(store.tabs.first?.view == .agent)
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
        #expect(store.selectedTab == claude.id)
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
        #expect(store.tabs.first?.view == .diff)
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
