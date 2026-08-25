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
