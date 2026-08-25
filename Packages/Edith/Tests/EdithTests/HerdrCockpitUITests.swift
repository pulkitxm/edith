import AppKit
import EdithKit
import Testing

@testable import Edith

@MainActor
@Suite struct HerdrCockpitUITests {
    @Test func theListSplitsAgentsFromTerminals() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        #expect(store.listedAgents.map(\.pane) == ["w2:p1"])
        #expect(store.listedTerminals.map(\.pane) == ["w2:p6"])
    }

    @Test func theTerminalsPillFiltersToTerminals() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        store.selectKind(HerdrKind.terminalLabel, exclusive: true)
        #expect(store.listedAgents.isEmpty)
        #expect(store.listedTerminals.map(\.pane) == ["w2:p6"])
        store.selectKind("all", exclusive: false)
        #expect(store.listedAgents.map(\.pane) == ["w2:p1"])
    }

    @Test func terminalsAreOfferedAsAKindWithoutTheirProcesses() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        #expect(store.kindChoices.last == HerdrKind.terminalLabel)
        #expect(!store.kindChoices.contains("bun"))
        #expect(store.kindChoices.contains("Claude Code"))
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
        HerdrAgentViews.set(.diff, for: terminal.id, suite)
        store.open(terminal)
        #expect(store.view(for: terminal.id) == .agent)
    }

    @Test func theRailRemembersWhetherItWasCollapsed() {
        let store = defaults()
        let first = HerdrStore(defaults: store, liveWatcher: { _ in })
        #expect(first.railOpen)
        first.setRailOpen(false)
        let second = HerdrStore(defaults: store, liveWatcher: { _ in })
        #expect(second.railOpen == false)
    }

    @Test func workspacesAreOfferedPerMachine() {
        let store = HerdrStore(defaults: defaults(), liveWatcher: { _ in })
        store.apply([host])
        #expect(store.workspaceChoices(for: "local").map(\.id) == ["edith"])
        #expect(store.workspaceChoices(for: "nowhere").isEmpty)
    }

    @Test func terminalsCarryTheirOwnToneAndAgentsFollowTheirStatus() {
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

    private var terminal: HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "w2:p6", kind: HerdrKind.terminalLabel, status: .unknown,
            title: "site dev server", workspace: "edith", cwd: "/repo/apps/site",
            category: .terminal, process: "bun")
    }

    private var host: HerdrHostSnapshot {
        .local(herdrPresent: true, agents: [agent, terminal])
    }
}
