import Foundation
import Testing

@testable import EdithKit

private actor HerdrSpaceCommands {
    private(set) var arguments: [[String]] = []
    let snapshot: String
    let creation: String

    init(snapshot: String, creation: String) {
        self.snapshot = snapshot
        self.creation = creation
    }

    func run(_ arguments: [String]) -> String {
        self.arguments.append(arguments)
        return arguments.contains("snapshot") ? snapshot : creation
    }
}

@Suite struct HerdrAgentSpacePreservationTests {
    private var agent: HerdrAgent {
        HerdrAgent.make(
            machineID: "local", machineName: "Test Mac", machineIsLocal: true, sshTarget: nil,
            session: "close-test", pane: "w1:p1", kind: "OpenCode", status: .idle,
            title: "Sample task", workspace: "Sample space", cwd: "/sample/old")
    }

    private let pane = """
        {"pane_id":"w1:p1","workspace_id":"w1","cwd":"/sample/current"}
        """

    private let created = """
        {"result":{"root_pane":{"pane_id":"w1:p2","workspace_id":"w1","tab_id":"w1:t2"}}}
        """

    private func snapshot(_ panes: String) -> String {
        """
        {"result":{"snapshot":{"workspaces":[{"workspace_id":"w1","label":"Sample space"}],"panes":[\(panes)]}}}
        """
    }

    @Test func theLastPaneGetsAReplacementInItsLiveDirectoryAndSession() async throws {
        let commands = HerdrSpaceCommands(snapshot: snapshot(pane), creation: created)

        try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)

        #expect(
            await commands.arguments == [
                ["--session", "close-test", "api", "snapshot"],
                [
                    "--session", "close-test", "tab", "create", "--workspace", "w1", "--no-focus",
                    "--cwd", "/sample/current",
                ],
            ])
    }

    @Test func anOrdinaryShellInTheSameSpaceAlreadyPreservesIt() async throws {
        let shell = #"{"pane_id":"w1:p2","workspace_id":"w1"}"#
        let commands = HerdrSpaceCommands(snapshot: snapshot("\(pane),\(shell)"), creation: created)

        try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)

        #expect(await commands.arguments.count == 1)
    }

    @Test func aPaneInAnotherSpaceDoesNotProtectTheClosingSpace() async throws {
        let other = #"{"pane_id":"w2:p1","workspace_id":"w2"}"#
        let commands = HerdrSpaceCommands(snapshot: snapshot("\(pane),\(other)"), creation: created)

        try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)

        #expect(await commands.arguments.count == 2)
    }

    @Test func aMissingPaneDoesNotCreateATerminal() async throws {
        let commands = HerdrSpaceCommands(snapshot: snapshot(""), creation: created)

        try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)

        #expect(await commands.arguments.count == 1)
    }

    @Test func anUnreadableSnapshotStopsTheClose() async {
        let commands = HerdrSpaceCommands(snapshot: "{}", creation: created)

        await #expect(throws: HerdrCommandError.self) {
            try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)
        }
        #expect(await commands.arguments.count == 1)
    }

    @Test func anUnconfirmedReplacementStopsTheClose() async {
        let commands = HerdrSpaceCommands(snapshot: snapshot(pane), creation: "{}")

        await #expect(throws: HerdrCommandError.self) {
            try await HerdrAgentCloseExecution.preserveSpace(for: agent, run: commands.run)
        }
    }

    @Test func preservationFailureNeverInterruptsOrClosesTheAgent() async {
        let commands = HerdrSpaceCommands(snapshot: "{}", creation: "{}")
        let steps = HerdrAgentCloseSteps(
            preserveSpace: { throw HerdrCommandError.malformedResponse },
            interrupt: { _ = await commands.run(["interrupt"]) },
            state: { .live(nil) },
            closePane: { _ = await commands.run(["close"]) })

        await #expect(throws: HerdrCommandError.self) {
            try await HerdrAgentCloseExecution.close(steps: steps)
        }
        #expect(await commands.arguments.isEmpty)
    }
}
