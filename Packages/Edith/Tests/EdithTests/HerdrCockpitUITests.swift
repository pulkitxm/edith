import AppKit
import EdithKit
import Testing

@testable import Edith

@MainActor
@Suite struct HerdrCockpitUITests {
    @Test func oneTerminalIsOfferedPerMachineThatHasHerdr() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote, missing])
        #expect(store.listedAgents.map(\.pane) == ["w2:p1"])
        #expect(store.machineTerminals.map(\.machineName) == ["This Mac", "tuf-wired"])
        #expect(store.machineTerminals.filter(\.isTerminal).count == 2)
    }

    @Test func theMachineFilterAlsoNarrowsTheTerminals() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote])
        store.machineFilter = "local"
        #expect(store.machineTerminals.map(\.machineName) == ["This Mac"])
        store.machineFilter = remote.id
        #expect(store.machineTerminals.map(\.machineName) == ["tuf-wired"])
        store.machineFilter = "all"
        #expect(store.machineTerminals.count == 2)
    }

    @Test func openingASplitClosesTheDetailPane() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        store.detailOpen = true
        store.open(agent, showing: .split)
        #expect(store.detailOpen == false)
        #expect(store.view(for: agent.id) == .split)
    }

    @Test func aTerminalTabNeverOpensInTheDiffView() {
        let suite = defaults()
        let store = HerdrStore(defaults: suite, liveWatcher: { _ in })
        store.apply([host])
        let terminal = HerdrMachineTerminal.agent(for: host)
        HerdrAgentViews.set(.diff, for: terminal.id, suite)
        store.open(terminal)
        #expect(store.view(for: terminal.id) == .agent)
    }

    @Test func closingAnAgentRunsItsControlAndClosesOnlyTheEdithTab() async throws {
        let capture = HerdrCloseCapture()
        let store = HerdrStore(
            defaults: defaults(), liveWatcher: { _ in },
            agentCloser: { agent in await capture.append(agent.id) })
        store.apply([host])
        store.open(agent)
        #expect(store.selectedTab == agent.id)

        try await store.closeAgent(agent)

        #expect(await capture.ids() == [agent.id])
        #expect(store.tabs.isEmpty)
        #expect(store.selectedTab == HerdrStore.boardID)
        #expect(store.hosts.first?.agents == [agent])
    }

    @Test func tabsReorderTheWayTheyAreDragged() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote])
        let first = HerdrMachineTerminal.agent(for: host)
        let second = HerdrMachineTerminal.agent(for: remote)
        store.open(agent)
        store.open(first)
        store.open(second)
        #expect(store.tabs.map(\.id) == [agent.id, first.id, second.id])
        store.moveTab(second.id, toIndexOf: agent.id)
        #expect(store.tabs.map(\.id) == [second.id, agent.id, first.id])
        store.moveTab(second.id, toIndexOf: HerdrStore.boardID)
        #expect(store.tabs.map(\.id) == [second.id, agent.id, first.id])
        store.moveTab(agent.id, toIndexOf: first.id)
        #expect(store.tabs.map(\.id) == [second.id, first.id, agent.id])
    }

    @Test func theBoardNeverMovesAndUnknownTabsAreIgnored() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        store.open(agent)
        store.moveTab(HerdrStore.boardID, toIndexOf: agent.id)
        store.moveTab("nowhere", toIndexOf: agent.id)
        store.moveTab(agent.id, toIndexOf: "nowhere")
        #expect(store.tabs.map(\.id) == [agent.id])
    }

    @Test func optionNumbersWalkTheTabsAndNineIsTheLast() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote])
        store.open(agent)
        store.open(HerdrMachineTerminal.agent(for: host))
        store.open(HerdrMachineTerminal.agent(for: remote))
        store.selectTab(number: 1)
        #expect(store.selectedTab == HerdrStore.boardID)
        store.selectTab(number: 3)
        #expect(store.selectedTab == store.tabs[1].id)
        store.selectTab(number: 9)
        #expect(store.selectedTab == store.tabs[2].id)
        store.selectTab(number: 8)
        #expect(store.selectedTab == store.tabs[2].id)
    }

    @Test func aHoveredCardReadsStrongerThanARestingOne() {
        let resting = HerdrStatusColor.fill(agent, dark: true, selected: false)
        let hovered = HerdrStatusColor.fill(agent, dark: true, selected: true)
        #expect(resting != hovered)
        #expect(
            HerdrStatusColor.stroke(agent, dark: true, selected: false)
                != HerdrStatusColor.stroke(agent, dark: true, selected: true))
    }

    @Test func theBoardStillOffersTheMachineTerminals() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote])
        store.selectBoard()
        #expect(store.selectedTab == HerdrStore.boardID)
        #expect(store.machineTerminals.count == 2)
        let terminal = store.machineTerminals[0]
        store.open(terminal)
        #expect(store.selectedTab == terminal.id)
        #expect(store.tabs.map(\.id) == [terminal.id])
    }

    @Test func bothPanesSurviveARestart() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(first.detailOpen)
        #expect(first.railOpen)
        first.detailOpen = false
        first.setRailOpen(false)

        let second = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(!second.detailOpen)
        #expect(!second.railOpen)

        second.detailOpen = true
        let third = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(third.detailOpen)
        #expect(!third.railOpen)
    }

    @Test func paneWidthsAreClampedAndSurviveARestart() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(first.railWidth == HerdrPaneSizing.railDefault)
        #expect(first.detailWidth == HerdrPaneSizing.detailDefault)

        first.railWidth = 340
        first.detailWidth = 410
        let second = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(second.railWidth == 340)
        #expect(second.detailWidth == 410)

        suite.set(10, forKey: AppStorageKeys.Herdr.railWidth)
        suite.set(900, forKey: AppStorageKeys.Herdr.detailWidth)
        let third = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(third.railWidth == HerdrPaneSizing.railMinimum)
        #expect(third.detailWidth == HerdrPaneSizing.detailMaximum)
    }

    @Test func eachRailSectionCollapsesAndSurvivesARestart() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(!first.terminalsCollapsed)
        #expect(!first.agentsCollapsed)
        first.terminalsCollapsed = true

        let second = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(second.terminalsCollapsed)
        #expect(!second.agentsCollapsed)

        second.agentsCollapsed = true
        second.terminalsCollapsed = false
        let third = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(third.agentsCollapsed)
        #expect(!third.terminalsCollapsed)
    }

    @Test func collapsedSectionsReopenOnlyWhenTheirCountsChange() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        first.apply([host])
        first.terminalsCollapsed = true
        first.agentsCollapsed = true
        #expect(suite.integer(forKey: AppStorageKeys.Herdr.terminalsCollapsedCount) == 1)
        #expect(suite.integer(forKey: AppStorageKeys.Herdr.agentsCollapsedCount) == 1)

        let same = HerdrStore(defaults: suite, liveWatcher: { _ in })
        same.apply([host])
        #expect(same.terminalsCollapsed)
        #expect(same.agentsCollapsed)

        let added = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p2", kind: "Codex", status: .idle,
            title: "Second agent", workspace: "edith", cwd: "/repo")
        let changedAgents = HerdrStore(defaults: suite, liveWatcher: { _ in })
        changedAgents.apply([.local(herdrPresent: true, agents: [agent, added])])
        #expect(changedAgents.terminalsCollapsed)
        #expect(!changedAgents.agentsCollapsed)

        let changedTerminals = HerdrStore(defaults: suite, liveWatcher: { _ in })
        changedTerminals.apply([host, remote])
        #expect(!changedTerminals.terminalsCollapsed)
    }

    @Test func agentsCanBeGroupedIntoNamedSpaces() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        let second = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p2", kind: "OpenCode", status: .idle,
            title: "Second agent", workspace: "edith", cwd: "/repo")
        let unassigned = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p3", kind: "OpenCode", status: .idle,
            title: "Third agent", workspace: "  ", cwd: "/repo")
        store.apply([.local(herdrPresent: true, agents: [unassigned, second, agent])])

        #expect(store.agentSpaces.map(\.title) == ["edith", "Unassigned"])
        #expect(store.agentSpaces[0].agents.map(\.pane) == ["w2:p2", "w2:p1"])
        #expect(store.agentSpaces[1].agents.map(\.pane) == ["w2:p3"])
    }

    @Test func spaceGroupingAndCollapsedSpacesSurviveARestart() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(!first.spaceGroupingEnabled)
        #expect(!first.spaceIsCollapsed("edith"))

        first.spaceGroupingEnabled = true
        first.toggleSpace("edith")

        let second = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(second.spaceGroupingEnabled)
        #expect(second.spaceIsCollapsed("edith"))
        second.toggleSpace("edith")

        let third = HerdrStore(defaults: suite, liveWatcher: { _ in })
        #expect(!third.spaceIsCollapsed("edith"))
    }

    @Test func collapsedSpaceReopensOnlyWhenItsAgentCountChanges() {
        let suite = defaults()
        let first = HerdrStore(defaults: suite, liveWatcher: { _ in })
        first.apply([host])
        first.toggleSpace("edith")

        let same = HerdrStore(defaults: suite, liveWatcher: { _ in })
        same.apply([host])
        #expect(same.spaceIsCollapsed("edith"))

        let added = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p2", kind: "Codex", status: .idle,
            title: "Second agent", workspace: "edith", cwd: "/repo")
        let changed = HerdrStore(defaults: suite, liveWatcher: { _ in })
        changed.apply([.local(herdrPresent: true, agents: [agent, added])])
        #expect(!changed.spaceIsCollapsed("edith"))
    }

    @Test func aBurstOfUpdatesLandsOnceAsTheLatestState() async throws {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.settle([host])
        store.settle([host, remote])
        store.settle([remote])
        #expect(store.hosts.map(\.name) == ["This Mac"])

        try await Task.sleep(for: HerdrStore.settleWindow * 3)
        #expect(store.hosts.map(\.name) == ["tuf-wired"])
        #expect(!store.settling)
    }

    @Test func aDetachedAgentKeepsOneTabUntilItsWindowCloses() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        #expect(store.detachedIDs.isEmpty)

        let first = store.detachedTab(for: agent)
        #expect(store.detachedIDs == [agent.id])
        let again = store.detachedTab(for: agent)
        #expect(first.id == again.id)
        #expect(store.detachedIDs.count == 1)

        store.reattach(agent.id)
        #expect(store.detachedIDs.isEmpty)
    }

    @Test func aTerminalCanBeDetachedTheSameWay() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host, remote])
        let terminal = HerdrMachineTerminal.agent(for: remote)
        let tab = store.detachedTab(for: terminal)
        #expect(tab.agent.isTerminal)
        #expect(tab.view == .agent)
        #expect(store.detachedIDs == [terminal.id])
    }

    @Test func theRailRemembersWhetherItWasCollapsed() {
        let store = defaults()
        let first = HerdrStore(defaults: store, liveWatcher: { _ in })
        #expect(first.railOpen)
        first.setRailOpen(false)
        let second = HerdrStore(defaults: store, liveWatcher: { _ in })
        #expect(second.railOpen == false)
    }

    @Test func terminalsCarryTheirOwnToneAndAgentsFollowTheirStatus() {
        let terminal = HerdrMachineTerminal.agent(for: host)
        #expect(HerdrStatusColor.tone(terminal, dark: false) == DashSkin.gold)
        #expect(
            HerdrStatusColor.tone(agent, dark: false)
                == HerdrStatusColor.color(.working, dark: false))
    }

    @Test func shiftReturnSendsANewlineUntilTheTerminalAsksForMore() {
        let view = EdithTerminalView.make()
        #expect(view.command(for: key(code: 36, flags: .shift)) == .newline)
        #expect(view.command(for: key(code: 76, flags: .shift)) == .newline)
        #expect(view.command(for: key(code: 36, flags: [])) == .none)
        #expect(view.command(for: key(code: 36, flags: [.shift, .command])) == .none)
    }

    @Test func commandCAndCommandVReachTheTerminal() {
        let view = EdithTerminalView.make()
        #expect(view.command(for: key(code: 9, flags: .command, characters: "v")) == .paste)
        #expect(view.command(for: key(code: 8, flags: .command, characters: "c")) == .none)
        #expect(view.command(for: key(code: 1, flags: .command, characters: "s")) == .none)
    }

    @Test func scrollbackIsDeepEnoughForALongAgentRun() {
        #expect(EdithTerminalView.scrollback >= 10000)
    }

    private func key(
        code: UInt16, flags: NSEvent.ModifierFlags, characters: String = "\r"
    ) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: 0, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "herdr.cockpit.\(UUID().uuidString)")!
    }

    private var agent: HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p1", kind: "Claude Code", status: .working,
            title: "Herdr cockpit", workspace: "edith", cwd: "/repo")
    }

    private var host: HerdrHostSnapshot {
        .local(herdrPresent: true, agents: [agent])
    }

    private var remote: HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB", name: "tuf-wired", isLocal: false,
            sshTarget: "tuf-wired", herdrPresent: true, reachable: true)
    }

    private var missing: HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: "11111111-1111-1111-1111-111111111111", name: "mini-pc", isLocal: false,
            sshTarget: "mini-pc", herdrPresent: false, reachable: true)
    }
}

private actor HerdrCloseCapture {
    private var values: [String] = []

    func append(_ id: String) {
        values.append(id)
    }

    func ids() -> [String] {
        values
    }
}
