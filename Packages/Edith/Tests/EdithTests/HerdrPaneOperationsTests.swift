import Foundation
import Testing

@testable import EdithKit

private actor HerdrCloseRecorder {
    private(set) var events: [String] = []
    private var states: [HerdrPaneState]
    private let fallback: HerdrPaneState

    init(states: [HerdrPaneState], fallback: HerdrPaneState) {
        self.states = states
        self.fallback = fallback
    }

    func record(_ event: String) { events.append(event) }

    func nextState() -> HerdrPaneState {
        events.append("state")
        return states.isEmpty ? fallback : states.removeFirst()
    }
}

@Suite struct HerdrPaneOperationsTests {
    private static let idleShell = """
        {"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":21791,"foreground_processes":[{"argv":["-zsh"],"argv0":"-zsh","cmdline":"-zsh","cwd":"/Users/me","name":"zsh","pid":21791}],"pane_id":"w2:p1","shell_pid":21791},"type":"pane_process_info"}}
        """

    private static let runningAgent = """
        {"id":"cli:pane:process_info","result":{"process_info":{"foreground_process_group_id":17128,"foreground_processes":[{"argv":["caffeinate","-i"],"argv0":"caffeinate","cmdline":"caffeinate -i","name":"caffeinate","pid":27199},{"argv":["claude"],"argv0":"/opt/bin/claude","cmdline":"claude --resume","name":"2.1.282","pid":17128}],"pane_id":"w5:pW","shell_pid":85573},"type":"pane_process_info"}}
        """

    @Test func anIdleShellIsNamedAfterTheShellAndNotRunning() throws {
        let process = try #require(HerdrListParser.paneProcess(from: Self.idleShell))
        #expect(process == HerdrPaneProcess(name: "zsh", command: "-zsh", running: false))
    }

    @Test func aForegroundJobIsNamedAfterItsGroupLeader() throws {
        let process = try #require(HerdrListParser.paneProcess(from: Self.runningAgent))
        #expect(process.name == "claude")
        #expect(process.command == "claude --resume")
        #expect(process.running)
    }

    @Test func processInfoWithoutProcessesIsUnknown() {
        #expect(HerdrListParser.paneProcess(from: "{}") == nil)
        #expect(
            HerdrListParser.paneProcess(
                from: #"{"result":{"process_info":{"foreground_processes":[]}}}"#) == nil)
    }

    @Test func paneCommandsAreScopedToTheirSession() {
        #expect(
            HerdrPaneProcessCommand.arguments(session: "default", pane: "w1:p2") == [
                "--session", "default", "pane", "process-info", "--pane", "w1:p2",
            ])
        #expect(
            HerdrPaneCloseCommand.arguments(session: "default", pane: "w1:p2") == [
                "--session", "default", "pane", "close", "w1:p2",
            ])
    }

    @Test func onlyPaneNotFoundErrorsMeanThePaneIsGone() {
        let missing = HerdrCommandError.commandFailed(
            #"{"error":{"code":"pane_not_found","message":"pane w9:p9 not found"}}"#)
        #expect(missing.paneMissing)
        #expect(!HerdrCommandError.commandFailed("connection refused").paneMissing)
        #expect(!HerdrCommandError.herdrUnavailable.paneMissing)
    }

    @Test func closingAnAgentWaitsForItToExitBeforeClosingThePane() async throws {
        let busy = HerdrPaneState.live(
            HerdrPaneProcess(name: "claude", command: "claude", running: true))
        let idle = HerdrPaneState.live(
            HerdrPaneProcess(name: "zsh", command: "-zsh", running: false))
        let recorder = HerdrCloseRecorder(states: [busy, busy, idle], fallback: idle)

        try await HerdrAgentCloseExecution.close(
            steps: steps(recorder), patience: .seconds(2), interval: .milliseconds(1))

        #expect(
            await recorder.events == ["state", "interrupt", "state", "state", "close"])
    }

    @Test func anAgentThatIgnoresInterruptsIsInterruptedAgainThenItsPaneCloses() async throws {
        let busy = HerdrPaneState.live(
            HerdrPaneProcess(name: "codex", command: "codex", running: true))
        let recorder = HerdrCloseRecorder(states: [], fallback: busy)

        try await HerdrAgentCloseExecution.close(
            steps: steps(recorder), patience: .milliseconds(20), interval: .milliseconds(5))

        let events = await recorder.events
        #expect(events.filter { $0 == "interrupt" }.count == HerdrAgentCloseExecution.attempts)
        #expect(events.last == "close")
    }

    @Test func anAgentWhosePaneIsAlreadyGoneNeedsNoClose() async throws {
        let recorder = HerdrCloseRecorder(states: [.missing], fallback: .missing)

        try await HerdrAgentCloseExecution.close(
            steps: steps(recorder), patience: .milliseconds(20), interval: .milliseconds(5))

        #expect(await recorder.events == ["state"])
    }

    private func steps(_ recorder: HerdrCloseRecorder) -> HerdrAgentCloseSteps {
        HerdrAgentCloseSteps(
            interrupt: { await recorder.record("interrupt") },
            state: { await recorder.nextState() },
            closePane: { await recorder.record("close") })
    }
}
