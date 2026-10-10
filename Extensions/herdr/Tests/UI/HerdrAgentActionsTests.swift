@testable import HerdrUI
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

private actor HerdrFocusRecorder {
    private(set) var calls: [String] = []

    func focus(_ session: String, _ pane: String, _ machine: Machine?) {
        calls.append("\(machine?.id.uuidString ?? "local")|\(session)|\(pane)")
    }
}

@MainActor
@Suite struct HerdrAgentActionsTests {
    @Test func openFocusesAnExistingSplitAndKeepsItsSessions() throws {
        let store = makeStore()
        let first = agent(pane: "w1:p1")
        let second = agent(pane: "w1:p2")
        store.open(first)
        store.open(second, beside: .right)
        let tab = try #require(store.currentTab)
        let holder = try #require(store.session(first.id)).holder
        store.selectBoard()

        HerdrAgentActions().open(first, store: store)

        #expect(store.tabs.count == 1)
        #expect(store.currentTab?.id == tab.id)
        #expect(store.currentTab?.layout == tab.layout)
        #expect(store.currentTab?.focused == first.id)
        #expect(store.session(first.id)?.holder === holder)
    }

    @Test func openingInHerdrReusesTheMachineTerminalAndFocusesEachRequestedPane() async throws {
        let recorder = HerdrFocusRecorder()
        let store = makeStore(recorder: recorder)
        let first = agent(pane: "w1:p1")
        let second = agent(pane: "w2:p1")
        store.hosts = [.local(herdrPresent: true, agents: [first, second])]
        let terminal = HerdrMachineTerminal.agent(for: store.hosts[0])
        store.open(terminal)
        let holder = try #require(store.session(terminal.id)).holder
        store.open(first)
        store.open(second, beside: .right)
        let layout = try #require(store.currentTab).layout

        try await store.openInHerdrTerminal(first)
        try await store.openInHerdrTerminal(second)

        #expect(await recorder.calls == ["local|default|w1:p1", "local|default|w2:p1"])
        #expect(store.currentTab?.agentIDs == [terminal.id])
        #expect(store.session(terminal.id)?.holder === holder)
        #expect(store.tabs.count == 2)
        #expect(store.tab(containing: first.id)?.layout == layout)
    }

    @Test func openingInHerdrPresentsTheWorkspaceAfterSelectingTheTerminal() async throws {
        var presentations = 0
        let store = HerdrStore(
            defaults: defaults(), agentFocuser: { _, _, _ in }, machinesProvider: { [] },
            workspacePresenter: { presentations += 1 })
        let target = agent(pane: "w1:p1")
        store.hosts = [.local(herdrPresent: true, agents: [target])]

        try await store.openInHerdrTerminal(target)

        #expect(presentations == 1)
        #expect(store.focusedSession?.agent.isTerminal == true)
    }

    @Test func namedSessionsOpenTheirOwnTerminal() async throws {
        let recorder = HerdrFocusRecorder()
        let store = makeStore(recorder: recorder)
        let target = agent(pane: "w1:p1", session: "sample session")
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(HerdrMachineTerminal.agent(for: store.hosts[0]))

        try await store.openInHerdrTerminal(target)

        #expect(store.sessions.count == 2)
        #expect(store.focusedSession?.agent.session == "sample session")
        #expect(await recorder.calls == ["local|sample session|w1:p1"])
    }

    @Test func remoteFocusUsesTheConfiguredMachineAndItsNamedSession() async throws {
        let recorder = HerdrFocusRecorder()
        let machine = Machine(name: "Sample server", host: "sample.invalid", username: "sample")
        let store = HerdrStore(
            defaults: defaults(), agentFocuser: { await recorder.focus($0, $1, $2) },
            machinesProvider: { [machine] })
        let target = HerdrAgent.make(
            machineID: machine.id.uuidString, machineName: machine.name, machineIsLocal: false,
            sshTarget: "sample@sample.invalid", session: "remote sample", pane: "w1:p1",
            kind: "Shell", status: .idle, title: "Sample task", workspace: "Sample",
            cwd: "/tmp/sample")
        store.hosts = [
            HerdrHostSnapshot(
                id: machine.id.uuidString, name: machine.name, isLocal: false,
                sshTarget: target.sshTarget, herdrPresent: true, reachable: true, agents: [target])
        ]

        try await store.openInHerdrTerminal(target)

        #expect(await recorder.calls == ["\(machine.id.uuidString)|remote sample|w1:p1"])
        #expect(store.focusedSession?.agent.machineID == machine.id.uuidString)
        #expect(store.focusedSession?.agent.session == "remote sample")
    }

    @Test func aFocusFailureKeepsTheCurrentLayout() async throws {
        let store = HerdrStore(
            defaults: defaults(),
            agentFocuser: { _, _, _ in throw HerdrCommandError.commandFailed("sample failure") },
            machinesProvider: { [] })
        let target = agent(pane: "w1:p1")
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)
        let tabs = store.tabs
        let selected = store.selectedTab

        await #expect(throws: HerdrCommandError.self) {
            try await store.openInHerdrTerminal(target)
        }

        #expect(store.tabs == tabs)
        #expect(store.selectedTab == selected)
    }

    private func makeStore(recorder: HerdrFocusRecorder = HerdrFocusRecorder()) -> HerdrStore {
        HerdrStore(
            defaults: defaults(), agentFocuser: { await recorder.focus($0, $1, $2) },
            machinesProvider: { [] })
    }

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HerdrAgentActionsTests-\(UUID().uuidString)")!
    }

    private func agent(pane: String, session: String = "default") -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "Sample Mac", machineIsLocal: true, sshTarget: nil,
            session: session, pane: pane, kind: "Shell", status: .idle, title: "Sample task",
            workspace: "Sample project", cwd: "/tmp/sample")
    }
}
