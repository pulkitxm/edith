import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private actor SyncHerdr {
    private(set) var closed: [String] = []
    private var next = 1

    func open() -> HerdrCreatedPane {
        defer { next += 1 }
        return HerdrCreatedPane(workspaceID: "w9", tabID: "w9:t\(next)", paneID: "w9:p\(next)")
    }

    func close(_ pane: String) { closed.append(pane) }

    nonisolated var operations: HerdrPanelTerminalOperations {
        HerdrPanelTerminalOperations(
            open: { _, _, _ in await self.open() },
            state: { _, _, _ in
                .live(HerdrPaneProcess(name: "zsh", command: "-zsh", running: false))
            },
            close: { _, pane, _ in await self.close(pane) },
            run: { _, _, _, _ in })
    }
}

@MainActor
@Suite struct HerdrTerminalSyncTests {
    @Test func snapshotsListThePanesOfTheEdithTerminalsSpace() throws {
        let json = """
            {"result":{"type":"session_snapshot","snapshot":{"workspaces":[{"workspace_id":"w1","label":"demo-app"},{"workspace_id":"w7","label":"Edith-terminals"}],"panes":[{"pane_id":"w1:p1","workspace_id":"w1","cwd":"/repo","agent":"claude"},{"pane_id":"w7:p1","workspace_id":"w7","cwd":"/repo"},{"pane_id":"w7:p2","workspace_id":"w7","cwd":"/srv/api"}],"agents":[]}}}
            """
        let board = try #require(HerdrListParser.snapshotBoard(from: json))
        #expect(
            HerdrListParser.spacePanes(in: board, session: "default") == [
                HerdrSpacePane(session: "default", pane: "w7:p1", cwd: "/repo"),
                HerdrSpacePane(session: "default", pane: "w7:p2", cwd: "/srv/api"),
            ])

        let cache = HerdrBoardCache(
            context: HerdrBoardContext(
                session: "default", machineID: "local", machineName: "This Mac",
                machineIsLocal: true, sshTarget: nil))
        cache.applySnapshot(json)
        #expect(cache.terminals.map(\.pane) == ["w7:p1", "w7:p2"])
        cache.applyEvent(#"{"event":"pane_closed","data":{"pane_id":"w7:p2"}}"#)
        #expect(cache.terminals.map(\.pane) == ["w7:p1"])
    }

    @Test func hostSnapshotsWithoutTerminalsStillDecode() throws {
        let json =
            #"{"id":"local","name":"This Mac","isLocal":true,"herdrPresent":true,"reachable":true,"agents":[]}"#
        let host = try JSONDecoder().decode(HerdrHostSnapshot.self, from: Data(json.utf8))
        #expect(host.terminals.isEmpty)
    }

    @Test func herdrOnlyTerminalsAppearOnTheBoard() {
        let store = makeStore()
        store.apply([host([pane("w7:p1", cwd: "/tmp/scratch")])])

        let adopted = store.terminalPanels.terminals(of: HerdrStore.boardID)
        #expect(adopted.map(\.pane) == ["w7:p1"])
        #expect(adopted.first?.host.isLocal == true)
        #expect(!store.terminalPanels.isOpen(HerdrStore.boardID))
    }

    @Test func herdrTerminalsJoinTheTabOfTheAgentInTheirFolder() {
        let store = makeStore()
        store.open(agent("Claude Code", pane: "a", cwd: "/repo"))
        let owner = store.selectedTab

        store.apply([host([pane("w7:p1", cwd: "/repo/web"), pane("w7:p2", cwd: "/elsewhere")])])

        #expect(store.terminalPanels.terminals(of: owner).map(\.pane) == ["w7:p1"])
        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).map(\.pane) == ["w7:p2"])
    }

    @Test func boardTerminalsMoveWhenTheirAgentTabOpens() async throws {
        let store = makeStore()
        store.apply([host([pane("w7:p1", cwd: "/repo")])])
        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).count == 1)

        store.open(agent("Codex", pane: "a", cwd: "/repo"))
        let owner = store.selectedTab

        try await eventually { store.terminalPanels.terminals(of: owner).count == 1 }
        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).isEmpty)
    }

    @Test func terminalsClosedInHerdrLeaveTheApp() {
        let store = makeStore()
        store.apply([host([pane("w7:p1", cwd: "/tmp"), pane("w7:p2", cwd: "/tmp")])])
        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).count == 2)

        store.apply([host([pane("w7:p2", cwd: "/tmp")])])

        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).map(\.pane) == ["w7:p2"])
    }

    @Test func anUnreachableMachineKeepsItsTerminals() {
        let store = makeStore()
        store.apply([host([pane("w7:p1", cwd: "/tmp")])])
        var down = host([])
        down.reachable = false
        store.apply([down])

        #expect(store.terminalPanels.terminals(of: HerdrStore.boardID).count == 1)
    }

    @Test func terminalsEdithOpensAreNotAdoptedTwice() async throws {
        let herdr = SyncHerdr()
        let store = makeStore(herdr)
        store.open(agent("Codex", pane: "a", cwd: "/repo"))
        let owner = store.selectedTab
        store.perform(.toggle)
        let id = try #require(store.terminalPanels.terminals(of: owner).first?.id)

        store.apply([host([pane("w9:p1", cwd: "/repo")])])
        try await eventually { store.terminalPanels.terminals[id]?.pane == "w9:p1" }
        store.apply([host([pane("w9:p1", cwd: "/repo")])])

        #expect(store.terminalPanels.terminals.count == 1)
        #expect(store.terminalPanels.terminals(of: owner).map(\.id) == [id])
    }

    @Test func aTerminalBeingClosedIsNotAdoptedBack() async throws {
        let herdr = SyncHerdr()
        let store = makeStore(herdr)
        store.apply([host([pane("w7:p1", cwd: "/tmp")])])
        let id = try #require(store.terminalPanels.terminals(of: HerdrStore.boardID).first?.id)

        store.terminalPanels.close(id)
        store.apply([host([pane("w7:p1", cwd: "/tmp")])])

        #expect(store.terminalPanels.terminals.isEmpty)
        try await eventually { await herdr.closed == ["w7:p1"] }
        store.apply([host([])])
        store.apply([host([pane("w7:p1", cwd: "/tmp")])])
        #expect(store.terminalPanels.terminals.count == 1)
    }

    private func makeStore(_ herdr: SyncHerdr = SyncHerdr()) -> HerdrStore {
        let suite = "HerdrTerminalSyncTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return HerdrStore(
            defaults: defaults,
            terminalPanels: HerdrTerminalPanels(defaults: defaults, operations: herdr.operations))
    }

    private func host(_ terminals: [HerdrSpacePane]) -> HerdrHostSnapshot {
        .local(herdrPresent: true, terminals: terminals)
    }

    private func pane(_ id: String, cwd: String) -> HerdrSpacePane {
        HerdrSpacePane(session: "default", pane: id, cwd: cwd)
    }

    private func agent(_ kind: String, pane: String, cwd: String) -> HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "This Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: pane, kind: kind, status: .idle, title: kind,
            workspace: "", cwd: cwd)
    }

    private func eventually(
        _ condition: @MainActor () async -> Bool, timeout: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("condition was not met in time")
    }
}
