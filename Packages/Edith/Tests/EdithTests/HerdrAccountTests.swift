import Darwin
import Foundation
import Testing

@testable import Edith
@testable import EdithKit

private actor HerdrAccountLaunchRecorder {
    var panes = 0
    var script: String?
    var started = false
    var cliStarts = 0

    func createPane() -> HerdrCreatedPane {
        panes += 1
        return HerdrCreatedPane(
            workspaceID: "fixture", tabID: "fixture:tab", paneID: "fixture:pane")
    }

    func begin(_ command: String) {
        script = command
        started = true
    }

    func startCLI() { cliStarts += 1 }
}

@MainActor @Suite(.serialized) struct HerdrAccountTests {
    private func fixture() throws -> URL {
        let root = try PhysicalTemporaryDirectory.url()
            .appendingPathComponent("herdr-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func defaults() throws -> UserDefaults {
        let suite = "herdr-accounts." + UUID().uuidString
        let value = try #require(UserDefaults(suiteName: suite))
        value.removePersistentDomain(forName: suite)
        return value
    }

    private func accountModel(_ root: URL, accounts: [ClaudeAccount]) async throws
        -> ClaudeAccountsModel
    {
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("accounts"), eraseSecret: { _ in },
            notifyUsage: {})
        try await model.load()
        try await model.persist(
            ClaudeAccountsState(accounts: accounts, defaultID: accounts.first?.id))
        return model
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 where !(await condition()) {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test(arguments: ["invalid", UUID().uuidString])
    func invalidOrRemovedAccountCannotCreatePane(selection: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await accountModel(root, accounts: [])
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: try defaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in })
        await #expect(throws: ClaudeAccountError.self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: nil, accountID: selection)
        }
        #expect(await recorder.panes == 0)
        #expect(store.sessions.isEmpty)
    }

    @Test func selectedAccountLaunchKeepsNativeProfileAndOnlySelectedCredential() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ClaudeAccount(name: "Synthetic first", credential: "synthetic-first-token")
        let second = ClaudeAccount(
            name: "Synthetic second", authentication: .apiKey, credential: "synthetic-second-key")
        let model = try await accountModel(root, accounts: [first, second])
        let recorder = HerdrAccountLaunchRecorder()
        let settings = try defaults()
        let store = HerdrStore(
            defaults: settings, claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in await recorder.startCLI() },
            accountAgentStarter: { launcher, _ in
                await recorder.begin(launcher)
            })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: second.id.uuidString)
        try await waitUntil { await recorder.started }
        let script = try #require(await recorder.script)
        #expect(!script.contains("CLAUDE_CONFIG_DIR"))
        #expect(!script.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR"))
        #expect(!script.contains("synthetic-second-key"))
        #expect(!script.contains("synthetic-first-token"))
        let staged = try FileManager.default.contentsOfDirectory(atPath: model.directory.path)
            .filter { $0.hasPrefix("launch-") }
        #expect(staged.count == 1)
        let path = model.directory.appendingPathComponent(try #require(staged.first)).path
        #expect(script.contains("export ANTHROPIC_API_KEY=\"$(cat " + ShellQuote.quote(path) + ")\""))
        #expect(script.contains("rm -f " + ShellQuote.quote(path)))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == "synthetic-second-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(
            script.hasPrefix("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN")
        )
        let tagging = try ClaudeAccountSessions.launchArguments(
            account: second.id, directory: model.directory)
        #expect(script.hasSuffix(tagging.map(ShellQuote.quote).joined(separator: " ")))
        #expect(store.accountSessions["local|default|fixture:pane"] == second.id.uuidString)
        #expect(
            settings.dictionary(forKey: HerdrStore.accountSessionsKey) as? [String: String]
                == ["local|default|fixture:pane": second.id.uuidString])
        #expect(await recorder.cliStarts == 0)
    }

    @Test func browserLoginLaunchSeedsItsPrivateProfileAndClearsSignOut() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var account = ClaudeAccount(name: "Synthetic browser", authentication: .browserLogin)
        account.loginData = #"{"claudeAiOauth":{"accessToken":"synthetic-access"}}"#
        account.isLoggedOut = true
        let model = try await accountModel(root, accounts: [account])
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: try defaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in },
            accountAgentStarter: { launcher, _ in
                await recorder.begin(launcher)
            })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil)
        try await waitUntil { model.account(account.id)?.isLoggedOut == false }
        let profile = model.directory.appendingPathComponent(account.id.uuidString)
        let script = try #require(await recorder.script)
        #expect(script.contains("export CLAUDE_CONFIG_DIR=" + ShellQuote.quote(profile.path)))
        #expect(
            script.contains(
                "export CLAUDE_SECURESTORAGE_CONFIG_DIR=" + ShellQuote.quote(profile.path)))
        let seeded = try Data(contentsOf: profile.appendingPathComponent(".credentials.json"))
        #expect(String(decoding: seeded, as: UTF8.self) == account.loginData)
        #expect(model.account(account.id)?.isLoggedOut == false)
    }

    @Test func nonClaudeAccountSelectionCannotCreatePane() async throws {
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: try defaults(),
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in })
        await #expect(throws: ClaudeAccountError.self) {
            try await store.launchNewAgent(
                kind: "Codex", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: nil, accountID: UUID().uuidString)
        }
        #expect(await recorder.panes == 0)
    }

    @Test func reusedNativeSessionCannotKeepOldAccountLabel() throws {
        let settings = try defaults()
        let store = HerdrStore(defaults: settings, liveWatcher: { _ in })
        var agent = HerdrAgent.make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "fixture:pane", kind: "Claude Code", status: .working,
            title: "Synthetic", workspace: "fixture", cwd: "/synthetic")
        let accountID = UUID().uuidString
        store.accountSessions[agent.id] = accountID
        agent.nativeSession = HerdrNativeSession(provider: "claude", value: "synthetic-session-one")
        store.apply([.local(herdrPresent: true, agents: [agent])])
        #expect(store.accountSessions[agent.id] == accountID)
        let restored = HerdrStore(defaults: settings, liveWatcher: { _ in })
        #expect(restored.accountSessions[agent.id] == accountID)
        agent.nativeSession = HerdrNativeSession(provider: "claude", value: "synthetic-session-two")
        restored.apply([.local(herdrPresent: true, agents: [agent])])
        #expect(restored.accountSessions[agent.id] == nil)
    }

    @Test func accountFilterSeparatesNamedAccountsFromTheExistingCLILogin() throws {
        let store = HerdrStore(defaults: try defaults(), liveWatcher: { _ in })
        func agent(_ pane: String, kind: String = "Claude Code") -> HerdrAgent {
            HerdrAgent.make(
                machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true,
                sshTarget: nil, session: "default", pane: pane, kind: kind, status: .working,
                title: "Synthetic", workspace: "fixture", cwd: "/synthetic")
        }
        let named = agent("fixture:named")
        let cli = agent("fixture:cli")
        let codex = agent("fixture:codex", kind: "Codex")
        let accountID = UUID().uuidString
        store.accountSessions[named.id] = accountID
        store.apply([.local(herdrPresent: true, agents: [named, cli, codex])])
        store.accountFilter = accountID
        #expect(store.filteredAgents.map(\.id) == [named.id])
        store.accountFilter = "cli"
        #expect(store.filteredAgents.map(\.id) == [cli.id])
        store.clearSessionFilters()
        #expect(store.accountFilter == nil)
        #expect(store.filteredAgents.count == 3)
    }

    @Test func selectedAccountCannotMoveToUnassociatedMachine() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        var account = ClaudeAccount(name: "Synthetic remote", credential: "synthetic-token")
        account.remoteMachineID = UUID().uuidString
        let model = try await accountModel(root, accounts: [account])
        let machine = Machine(name: "Synthetic target", host: "fixture.invalid")
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: try defaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in }, machinesProvider: { [machine] })
        let host = HerdrHostSnapshot(
            id: machine.id.uuidString, name: "Synthetic target", isLocal: false, herdrPresent: true,
            reachable: true)
        await #expect(throws: ClaudeAccountError.self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: host, existingSpace: nil, newSpaceLabel: nil,
                accountID: account.id.uuidString)
        }
        #expect(await recorder.panes == 0)
    }

    @Test func explicitCLIChoiceDoesNotReadSavedAccountStorage() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("accounts")
        try Data("synthetic invalid storage".utf8).write(to: invalid)
        let model = ClaudeAccountsModel(directory: invalid, notifyUsage: {})
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: try defaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in await recorder.startCLI() })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: "cli")
        #expect(await recorder.panes == 1)
        #expect(!model.ready)
        #expect(try Data(contentsOf: invalid) == Data("synthetic invalid storage".utf8))
        await #expect(throws: ClaudeAccountError.self) {
            try await store.launchNewAgent(
                kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: nil, accountID: "default")
        }
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil)
        #expect(await recorder.panes == 2)
        try await waitUntil { await recorder.cliStarts == 2 }
        #expect(await recorder.cliStarts == 2)
    }
}
