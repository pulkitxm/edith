import EdithExtensionAccounts
import EdithExtensionSupport
import Darwin
import Foundation
import Testing

@testable import HerdrUI

private actor HerdrRestartRecorder {
    var events: [String] = []
    var environments: [[String: String]] = []
    var scripts: [String] = []
    var started: [(kind: String, leading: [String], pane: String)] = []
    var commands: [String] = []

    func log(_ event: String) { events.append(event) }
    func pane(_ environment: [String: String]) {
        events.append("split")
        environments.append(environment)
    }
    func script(_ value: String) { scripts.append(value) }
    func start(_ kind: String, _ leading: [String], _ pane: String) {
        events.append("start")
        started.append((kind, leading, pane))
    }
    func command(_ value: String) {
        events.append("account")
        commands.append(value)
    }
}

@MainActor
@Suite struct HerdrAgentRestartTests {
    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "HerdrAgentRestartTests-\(UUID().uuidString)")!
    }

    private func agent(
        pane: String = "w1:p1", kind: String = "Claude Code",
        native: HerdrNativeSession? = HerdrNativeSession(provider: "claude", value: "session-one")
    ) -> HerdrAgent {
        HerdrAgent.make(
            machineID: HerdrHostSnapshot.localID, machineName: "Sample Mac",
            machineIsLocal: true, sshTarget: nil, session: "default", pane: pane, kind: kind,
            status: .working, title: "Sample task", workspace: "Sample project",
            cwd: "/tmp/sample", nativeSession: native)
    }

    private func steps(
        _ recorder: HerdrRestartRecorder, exitOutput: String = "", transcript: String? = "/t.jsonl",
        quitError: Error? = nil
    ) -> HerdrAgentRestartSteps {
        HerdrAgentRestartSteps(
            quit: { _ in
                await recorder.log("quit")
                if let quitError { throw quitError }
                return exitOutput
            },
            locateClaudeTranscript: { script, _ in
                await recorder.script(script)
                return transcript
            },
            createPane: { _, _, environment in
                await recorder.pane(environment)
                return HerdrCreatedPane(workspaceID: "w1", tabID: "w1:t1", paneID: "w1:p2")
            },
            closePane: { agent, _ in await recorder.log("close \(agent.pane)") },
            start: { kind, leading, pane, _, _ in await recorder.start(kind, leading, pane) })
    }

    private func settle(_ recorder: HerdrRestartRecorder, count: Int) async throws {
        for _ in 0..<200 {
            let events = await recorder.events.count
            if events >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func accountModel(_ accounts: [ClaudeAccount]) async throws -> (ClaudeAccountsModel, URL) {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        try #require(realpath(NSTemporaryDirectory(), &buffer) != nil)
        let root = URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .appendingPathComponent("herdr-restart-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let model = ClaudeAccountsModel(directory: root.appendingPathComponent("accounts"))
        try await model.load()
        try await model.persist(
            ClaudeAccountsState(accounts: accounts, defaultID: accounts.first?.id))
        return (model, root)
    }

    @Test func restartQuitsThenResumesInAReplacementPaneAtTheSameLayoutSlot() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(defaults: defaults(), agentRestartSteps: steps(recorder))
        let target = agent()
        let neighbor = agent(pane: "w1:p9", kind: "Codex", native: nil)
        store.hosts = [.local(herdrPresent: true, agents: [target, neighbor])]
        store.open(target)
        store.open(neighbor, beside: .right)
        let shape = try #require(store.currentTab).layout.panes.firstIndex(of: target.id)

        try await store.restartAgent(target)
        try await settle(recorder, count: 4)

        let replacement = HerdrAgent.make(
            machineID: target.machineID, machineName: target.machineName, machineIsLocal: true,
            sshTarget: nil, session: "default", pane: "w1:p2", kind: "Claude Code",
            status: .unknown, title: "Claude Code", workspace: "", cwd: "")
        let tab = try #require(store.currentTab)
        #expect(tab.layout.panes.firstIndex(of: replacement.id) == shape)
        #expect(!tab.layout.contains(target.id))
        #expect(store.session(target.id) == nil)
        #expect(store.sessions.count == 2)
        #expect(await recorder.events.first == "quit")
        #expect(Set(await recorder.events) == ["quit", "split", "start", "close w1:p1"])
        let started = try #require(await recorder.started.first)
        #expect(started.kind == "Claude Code")
        #expect(started.leading == ["--resume", "session-one"])
        #expect(started.pane == "w1:p2")
    }

    @Test func aSessionPrintedAtExitIsUsedWhenHerdrHasNone() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(),
            agentRestartSteps: steps(recorder, exitOutput: "  codex resume printed-id\n"))
        let target = agent(kind: "Codex", native: nil)
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        try await store.restartAgent(target)
        try await settle(recorder, count: 4)

        #expect(await recorder.started.first?.leading == ["resume", "printed-id"])
    }

    @Test func continuingInAnotherAgentStartsItWithAHandoffPrompt() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(),
            agentRestartSteps: steps(recorder, transcript: "/sample/projects/p/session-one.jsonl"))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        try await store.restartAgent(target, kind: "Codex")
        try await settle(recorder, count: 4)

        let started = try #require(await recorder.started.first)
        #expect(started.kind == "Codex")
        let prompt = try #require(started.leading.first)
        #expect(prompt.contains("Claude Code (session session-one)"))
        #expect(prompt.contains("/sample/projects/p/session-one.jsonl"))
        #expect(!(await recorder.scripts.first ?? "").contains("cp -f"))
    }

    @Test func movingToATokenAccountHandsTheCredentialToTheNewPaneOnly() async throws {
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let (model, root) = try await accountModel([account])
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(), claudeAccounts: model,
            accountAgentStarter: { command, _ in await recorder.command(command) },
            agentRestartSteps: steps(recorder))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        try await store.restartAgent(target, accountID: account.id.uuidString)
        try await settle(recorder, count: 4)

        #expect(
            await recorder.environments.first == [
                ClaudeAccount.launchCredentialVariable: "synthetic-token"
            ])
        let command = try #require(await recorder.commands.first)
        #expect(command.contains("unset ANTHROPIC_API_KEY"))
        #expect(command.contains("--resume session-one"))
        #expect(!command.contains("synthetic-token"))
        #expect(store.accountSessions[target.id] == nil)
        #expect(store.accountSessions.values.contains(account.id.uuidString))
    }

    @Test func movingToAProfileAccountCopiesTheTranscriptIntoThatProfile() async throws {
        let account = ClaudeAccount(
            name: "Synthetic", authentication: .browserLogin, credential: "")
        var login = account
        login.loginData = #"{"claudeAiOauth":{"accessToken":"synthetic"}}"#
        let (model, root) = try await accountModel([login])
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(), claudeAccounts: model,
            accountAgentStarter: { command, _ in await recorder.command(command) },
            agentRestartSteps: steps(recorder))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        try await store.restartAgent(target, accountID: account.id.uuidString)
        try await settle(recorder, count: 3)

        let script = try #require(await recorder.scripts.first)
        #expect(script.contains("/accounts/\(account.id.uuidString)/projects/$project"))
        #expect(script.contains("cp -f"))
    }

    @Test func aRestartThatCannotFindTheTranscriptStopsBeforeCreatingAPane() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(), agentRestartSteps: steps(recorder, transcript: nil))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        await #expect(throws: HerdrAgentRestartError.transcriptMissing("session-one")) {
            try await store.restartAgent(target)
        }
        #expect(await recorder.events == ["quit"])
        #expect(store.session(target.id) != nil)
    }

    @Test func aFailedQuitLeavesTheAgentAlone() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(),
            agentRestartSteps: steps(recorder, quitError: HerdrAgentRestartError.stillRunning))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]
        store.open(target)

        await #expect(throws: HerdrAgentRestartError.stillRunning) {
            try await store.restartAgent(target)
        }
        #expect(await recorder.events == ["quit"])
        #expect(store.session(target.id) != nil)
    }

    @Test func anInvalidAccountNeverQuitsTheAgent() async throws {
        let (model, root) = try await accountModel([])
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(
            defaults: defaults(), claudeAccounts: model, agentRestartSteps: steps(recorder))
        let target = agent()
        store.hosts = [.local(herdrPresent: true, agents: [target])]

        await #expect(throws: ClaudeAccountError.self) {
            try await store.restartAgent(target, accountID: UUID().uuidString)
        }
        #expect(await recorder.events.isEmpty)
    }

    @Test func unsupportedAgentsAndTargetsAreRejected() async throws {
        let recorder = HerdrRestartRecorder()
        let store = HerdrStore(defaults: defaults(), agentRestartSteps: steps(recorder))
        let fx = agent(kind: "FX.sh", native: nil)
        let claude = agent(pane: "w1:p3")
        store.hosts = [.local(herdrPresent: true, agents: [fx, claude])]

        await #expect(throws: HerdrAgentRestartError.unsupported("FX.sh")) {
            try await store.restartAgent(fx)
        }
        await #expect(throws: HerdrAgentRestartError.unsupported("Amp")) {
            try await store.restartAgent(claude, kind: "Amp")
        }
        #expect(await recorder.events.isEmpty)
    }
}
