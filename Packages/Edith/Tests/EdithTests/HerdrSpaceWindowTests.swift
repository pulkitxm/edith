import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct HerdrSpaceWindowModelTests {
    @Test func anEmptySpaceStartsWithOneLocalTerminal() {
        let model = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "empty", title: "empty", agents: []),
            store: makeStore())

        #expect(model.tabs.count == 1)
        #expect(model.selectedTab?.agentID == nil)
        #expect(model.selectedTab?.focusedTarget == HerdrSpaceTerminalContext.local.target)
    }

    @Test func openingASpaceMovesItsAgentsIntoIndependentTabs() {
        let store = makeStore()
        let agents = [localAgent, remoteAgent]
        store.apply([.local(herdrPresent: true, agents: agents)])
        store.open(localAgent)
        let sourceHolder = store.tabs[0].holder

        let model = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "edith", title: "edith", agents: agents), store: store)

        #expect(model.tabs.map(\.title) == ["Local agent", "Remote agent"])
        #expect(model.selected == model.tabs[0].id)
        #expect(store.tabs.isEmpty)
        #expect(store.detachedIDs.isEmpty)
        #expect(model.tabs[0].holders[0] !== sourceHolder)
        #expect(model.tabs.allSatisfy { $0.paneCount == 1 })
    }

    @Test func terminalContextsKeepMachineAndDirectoryPairsDistinct() {
        let repeated = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "third", pane: "p3", kind: "Codex", status: .idle,
            title: "Repeated", workspace: "edith", cwd: "/repo")
        let home = HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "fourth", pane: "p4", kind: "Codex", status: .idle,
            title: "Home", workspace: "edith", cwd: "  ")

        let contexts = HerdrSpaceTerminalContext.unique(
            for: [localAgent, repeated, home, remoteAgent])

        #expect(contexts.count == 3)
        #expect(contexts[0].machineID == Machine.localID)
        #expect(contexts[0].workingDirectory == "/repo")
        #expect(contexts[1].workingDirectory == nil)
        #expect(contexts[2].machineID.uuidString == remoteID.uuidString)
        #expect(contexts[2].workingDirectory == "/srv/edith")
    }

    @Test func commandTStyleCreationInheritsTheFocusedContext() {
        let model = makeModel()
        let terminal = model.addTerminal()

        #expect(model.tabs.count == 3)
        #expect(model.selected == terminal.id)
        #expect(terminal.title == "Shell 1")
        #expect(terminal.focusedTarget?.machineID == Machine.localID)
        #expect(terminal.focusedTarget?.argument == "/repo")
        #expect(terminal.agentID == nil)
    }

    @Test func aChosenContextOverridesTheFocusedAgent() throws {
        let model = makeModel()
        let remote = try #require(model.contexts.first { $0.machineID == remoteID })
        let terminal = model.addTerminal(context: remote)

        #expect(terminal.focusedTarget == remote.target)
    }

    @Test func splitRightAddsAndFocusesAnAppTerminalPane() throws {
        let model = makeModel()
        let tab = try #require(model.selectedTab)
        let agentHolder = tab.holders[0]

        tab.split(.right)

        #expect(tab.paneCount == 2)
        let root = try #require(split(tab.layout.root))
        #expect(root.axis == .horizontal)
        #expect(root.children.count == 2)
        #expect(tab.layout.focused == root.children[1].id)
        #expect(tab.holders.count == 2)
        #expect(tab.holders.contains { $0 === agentHolder })
        let focused = try #require(tab.focusedPane)
        if case .terminal = try #require(tab.content(for: focused)) {
        } else {
            Issue.record("The inserted pane was not an app terminal")
        }
    }

    @Test func splitDownUsesAVerticalTree() throws {
        let model = makeModel()
        let tab = model.addTerminal()

        tab.split(.bottom)

        let root = try #require(split(tab.layout.root))
        #expect(root.axis == .vertical)
    }

    @Test func closingAPaneStopsOnlyItsTerminal() throws {
        let model = makeModel()
        let tab = try #require(model.selectedTab)
        tab.split(.right)
        let focused = try #require(tab.focusedPane)
        let content = try #require(tab.content(for: focused))
        let holder = content.holder
        holder.start(executable: "/bin/cat", arguments: [], environment: [])
        #expect(holder.started)

        #expect(tab.closeFocusedPane())

        #expect(!holder.started)
        #expect(tab.paneCount == 1)
        #expect(tab.agentID == localAgent.id)
    }

    @Test func closingATabStopsEveryPaneItOwns() throws {
        let model = makeModel()
        let shell = model.addTerminal()
        shell.split(.right)
        let holders = shell.holders
        for holder in holders {
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
        }

        #expect(model.closeSelectedTab())

        #expect(holders.allSatisfy { !$0.started })
        #expect(model.tabs.count == 2)
    }

    @Test func tabAndPaneNavigationWrap() throws {
        let model = makeModel()
        let first = try #require(model.selected)
        let second = model.tabs[1].id
        #expect(model.cycleTab(backwards: true))
        #expect(model.selected == second)
        #expect(model.cycleTab(backwards: false))
        #expect(model.selected == first)

        let tab = try #require(model.selectedTab)
        tab.split(.right)
        let right = tab.layout.focused
        #expect(model.cyclePane(backwards: false))
        #expect(tab.layout.focused != right)
        #expect(model.cyclePane(backwards: true))
        #expect(tab.layout.focused == right)
    }

    @Test func selectingAnAgentRaisesItsOwningTopLevelTab() {
        let model = makeModel()

        #expect(model.selectAgent(remoteAgent.id))
        #expect(model.selectedAgentID == remoteAgent.id)
        #expect(!model.selectAgent("missing"))
        #expect(model.selectedAgentID == remoteAgent.id)
    }

    @Test func agentViewChangesStayWindowLocalAndPersistThePreference() throws {
        let suite = defaults()
        let store = HerdrStore(defaults: suite, liveWatcher: { _ in })
        let model = HerdrSpaceWindowModel(
            space: HerdrAgentSpace(id: "edith", title: "edith", agents: [localAgent]),
            store: store)
        let tab = try #require(model.selectedTab)

        tab.setAgentView(.split, defaults: suite)

        let pane = try #require(tab.focusedPane)
        let agent = try #require(tab.content(for: pane)?.agent)
        #expect(agent.view == .split)
        #expect(HerdrAgentViews.view(for: localAgent.id, suite) == .split)
        #expect(store.tabs.isEmpty)
        #expect(store.detachedIDs.isEmpty)
    }

    @Test func stoppingTheWindowStopsAgentAndShellSessions() {
        let model = makeModel()
        _ = model.addTerminal()
        let holders = model.tabs.flatMap(\.holders)
        for holder in holders {
            holder.start(executable: "/bin/cat", arguments: [], environment: [])
        }

        model.stopAll()

        #expect(holders.allSatisfy { !$0.started })
        #expect(model.tabs.isEmpty)
        #expect(model.selected == nil)
    }

    private func makeModel() -> HerdrSpaceWindowModel {
        HerdrSpaceWindowModel(
            space: HerdrAgentSpace(
                id: "edith", title: "edith", agents: [localAgent, remoteAgent]),
            store: makeStore())
    }

    private func makeStore() -> HerdrStore {
        HerdrStore(defaults: defaults(), liveWatcher: { _ in })
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "herdr.space.window.\(UUID().uuidString)")!
    }

    private func split(_ node: LayoutNode) -> SplitNode? {
        guard case let .split(value) = node else { return nil }
        return value
    }

    private var localAgent: HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true,
            sshTarget: nil, session: "main", pane: "p1", kind: "Codex", status: .working,
            title: "Local agent", workspace: "edith", cwd: "/repo")
    }

    private var remoteAgent: HerdrAgent {
        HerdrAgent.make(
            machineID: remoteID.uuidString, machineName: "build-box", machineIsLocal: false,
            sshTarget: "build-box", session: "remote", pane: "p2", kind: "OpenCode",
            status: .idle, title: "Remote agent", workspace: "edith", cwd: "/srv/edith")
    }

    private var remoteID: UUID {
        UUID(uuidString: "60E1AA8E-9B9C-487D-BA0F-D7D664D97CEB")!
    }
}
