import Foundation
import Testing

@testable import HerdrUI

@Suite struct AgentResumeTests {
    private let samples = [
        ("Claude Code", "Resume this session with:\nclaude --resume c3ca7f1f-d8cc-489d-a485-38e664ddf0f2\n", "c3ca7f1f-d8cc-489d-a485-38e664ddf0f2"),
        ("Codex", "To reconnect, run:\n  codex resume 01a1aab0-a42a-7460-ad54-ca8c25b7955a\nStop the current turn", "01a1aab0-a42a-7460-ad54-ca8c25b7955a"),
        ("OpenCode", "  Continue  opencode -s ses_e554ef9f6ffeL72g2EEodGm28a\n", "ses_e554ef9f6ffeL72g2EEodGm28a"),
        ("Grok", "Resume this session with:\n  grok --resume 01a1aab1-4cae-7391-9f35-d337f195a3c2\n", "01a1aab1-4cae-7391-9f35-d337f195a3c2"),
        ("Cursor Agent", "  To resume this session: agent --resume=920e7b33-63c7-449b-b148-6f29ef155b8e\n", "920e7b33-63c7-449b-b148-6f29ef155b8e"),
    ]

    @Test func readsTheSessionFromEachRealExitMessage() {
        for (kind, output, id) in samples {
            #expect(AgentResume.sessionID(kind: kind, native: nil, exitOutput: output) == id)
        }
    }

    @Test func theLastExitMessageInThePaneWins() {
        let output = "claude --resume first-session\nclaude --resume second-session\n"
        #expect(
            AgentResume.sessionID(kind: "claude", native: nil, exitOutput: output)
                == "second-session")
    }

    @Test func aReportedSessionWinsOverPaneOutputOnlyForTheSameAgent() {
        let reported = HerdrNativeSession(provider: "claude", value: "reported-session")
        let output = "claude --resume printed-session"
        #expect(
            AgentResume.sessionID(kind: "Claude Code", native: reported, exitOutput: output)
                == "reported-session")
        let other = HerdrNativeSession(provider: "codex", value: "codex-session")
        #expect(
            AgentResume.sessionID(kind: "Claude Code", native: other, exitOutput: output)
                == "printed-session")
    }

    @Test func rejectsAnythingThatIsNotASessionID() {
        #expect(AgentResume.sessionID(kind: "Claude Code", native: nil, exitOutput: "") == nil)
        #expect(
            AgentResume.sessionID(
                kind: "Claude Code", native: nil, exitOutput: "claude --resume $(rm)") == nil)
        #expect(AgentResume.sessionID(kind: "FX.sh", native: nil, exitOutput: "fx") == nil)
    }

    @Test func resumeArgumentsMatchEachCLI() {
        #expect(AgentResume.resumeArguments(kind: "Claude Code", sessionID: "a") == ["--resume", "a"])
        #expect(AgentResume.resumeArguments(kind: "Codex", sessionID: "a") == ["resume", "a"])
        #expect(AgentResume.resumeArguments(kind: "OpenCode", sessionID: "a") == ["-s", "a"])
        #expect(AgentResume.resumeArguments(kind: "Cursor Agent", sessionID: "a") == ["--resume=a"])
        #expect(AgentResume.resumeArguments(kind: "Grok", sessionID: "a") == ["--resume", "a"])
    }

    @Test func handoffNamesTheSourceAgentAndSessionForEveryTarget() throws {
        for source in AgentResume.profiles {
            for target in AgentResume.handoffTargets(from: source.kind) {
                let arguments = AgentResume.handoffArguments(
                    from: source.kind, sessionID: "sample-session", to: target)
                let prompt = try #require(arguments.last)
                #expect(prompt.contains(source.kind))
                #expect(prompt.contains("sample-session"))
                #expect(prompt.contains("checklist"))
                #expect(!prompt.contains("\n"))
                #expect(prompt.utf8.count <= 8192)
            }
            #expect(!AgentResume.handoffTargets(from: source.kind).contains(source.kind))
        }
        #expect(AgentResume.handoffArguments(from: "Codex", sessionID: "s", to: "OpenCode").first == "--prompt")
        #expect(AgentResume.handoffArguments(from: "Codex", sessionID: "s", to: "Gemini").first == "-i")
    }

    @Test func aLocatedClaudeTranscriptReplacesTheGenericPath() throws {
        let arguments = AgentResume.handoffArguments(
            from: "Claude Code", sessionID: "s", to: "Codex",
            transcriptPath: "/sample/projects/p/s.jsonl")
        let prompt = try #require(arguments.first)
        #expect(prompt.contains("/sample/projects/p/s.jsonl"))
        #expect(prompt.contains("/sample/projects/p/s/subagents"))
    }

    @Test func splitPaneParsesHerdrOutput() {
        let output = #"{"result":{"pane":{"pane_id":"w1:p7","tab_id":"w1:t2","workspace_id":"w1"}}}"#
        #expect(
            HerdrListParser.splitPane(from: output)
                == HerdrCreatedPane(workspaceID: "w1", tabID: "w1:t2", paneID: "w1:p7"))
        #expect(HerdrListParser.splitPane(from: "{}") == nil)
    }

    @Test func leadingArgumentsComeBeforeLaunchFlags() throws {
        let defaults = try #require(UserDefaults(suiteName: "AgentResume-\(UUID().uuidString)"))
        let launch = HerdrLaunchOperations.agentLaunch(
            kind: "Codex", name: "codex", pane: "w1:p1",
            options: AgentLaunchOptions(model: "gpt-6-sol"),
            leadingArguments: ["resume", "sample"], defaults: defaults)
        #expect(launch.local.suffix(4) == ["resume", "sample", "-m", "gpt-6-sol"])
    }
}

@Suite struct ClaudeTranscriptCommandTests {
    private func run(_ script: String, home: URL) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        let output = Pipe()
        process.standardOutput = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude transcript \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, age: TimeInterval = 0) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: url.path)
    }

    @Test func copiesTheNewestTranscriptAndSubagentsIntoTheTargetProfile() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = home.appendingPathComponent("first profile")
        let second = home.appendingPathComponent("second profile")
        let target = home.appendingPathComponent("target profile")
        try write(
            "old", to: first.appendingPathComponent("projects/p/s.jsonl"), age: 60)
        try write("new", to: second.appendingPathComponent("projects/p/s.jsonl"))
        try write("sub", to: second.appendingPathComponent("projects/p/s/subagents/a.jsonl"))
        let quote = { (url: URL) in "'" + url.path + "'" }
        let (status, output) = try run(
            ClaudeTranscriptCommand.script(
                sessionID: "s", roots: [quote(first), quote(second)], destination: quote(target)),
            home: home)
        #expect(status == 0)
        let copied = target.appendingPathComponent("projects/p/s.jsonl")
        #expect(output == copied.path)
        #expect(try String(contentsOf: copied, encoding: .utf8) == "new")
        #expect(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("projects/p/s/subagents/a.jsonl").path))
    }

    @Test func aTranscriptAlreadyInTheTargetStaysPut() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("kept", to: home.appendingPathComponent(".claude/projects/p/s.jsonl"))
        let root = "\"$HOME\"/.claude"
        let (status, output) = try run(
            ClaudeTranscriptCommand.script(sessionID: "s", roots: [root], destination: root),
            home: home)
        #expect(status == 0)
        #expect(output == home.appendingPathComponent(".claude/projects/p/s.jsonl").path)
    }

    @Test func aMissingTranscriptReportsNotFound() throws {
        let home = try fixture()
        defer { try? FileManager.default.removeItem(at: home) }
        let (status, _) = try run(
            ClaudeTranscriptCommand.script(
                sessionID: "s", roots: ["\"$HOME\"/.claude"], destination: nil), home: home)
        #expect(status == ClaudeTranscriptCommand.notFoundStatus)
    }
}

@Suite struct HerdrAgentQuitTests {
    private actor Recorder {
        var presses: [String] = []
        var running: Bool
        let quitAfter: Int
        let menu: Bool

        init(quitAfter: Int, menu: Bool = false) {
            running = true
            self.quitAfter = quitAfter
            self.menu = menu
        }

        func press(_ key: String) {
            presses.append(key)
            if menu ? key == "3" : presses.count >= quitAfter { running = false }
        }

        func state() -> HerdrPaneState {
            .live(HerdrPaneProcess(name: "agent", command: "agent", running: running))
        }

        func screen() -> String {
            running
                ? (menu ? "3. Exit  Stop the current task and exit Codex" : "working")
                : "exited"
        }
    }

    private func steps(_ recorder: Recorder) -> HerdrAgentQuitSteps {
        HerdrAgentQuitSteps(
            state: { await recorder.state() }, press: { await recorder.press($0) },
            read: { await recorder.screen() })
    }

    private func quit(_ kind: String, _ recorder: Recorder) async throws -> String {
        try await HerdrAgentRestartExecution.quit(
            kind: kind, steps: steps(recorder), patience: .milliseconds(30),
            pressGap: .milliseconds(1), interval: .milliseconds(5))
    }

    @Test func mostAgentsTakeTwoPressesPerRound() async throws {
        let recorder = Recorder(quitAfter: 4)
        #expect(try await quit("Claude Code", recorder) == "exited")
        #expect(await recorder.presses == ["ctrl+c", "ctrl+c", "ctrl+c", "ctrl+c"])
    }

    @Test func codexGetsOnePressSoItsExitMessagePrints() async throws {
        let recorder = Recorder(quitAfter: 1)
        #expect(try await quit("Codex", recorder) == "exited")
        #expect(await recorder.presses == ["ctrl+c"])
    }

    @Test func codexRunningTaskMenuStopsTheTurnAndExits() async throws {
        let recorder = Recorder(quitAfter: 0, menu: true)
        #expect(try await quit("Codex", recorder) == "exited")
        #expect(await recorder.presses == ["ctrl+c", "3"])
    }

    @Test func anAgentThatWillNotQuitIsReported() async {
        let recorder = Recorder(quitAfter: 1_000)
        await #expect(throws: HerdrAgentRestartError.stillRunning) {
            try await quit("Grok", recorder)
        }
    }
}
