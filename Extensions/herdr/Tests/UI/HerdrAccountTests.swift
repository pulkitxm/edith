import EdithExtensionAccounts
import EdithExtensionSupport
import Darwin
import Foundation
import Testing
@testable import HerdrUI

private actor HerdrAccountLaunchRecorder {
    var invalidations = 0
    func invalidate() { invalidations += 1 }
    var panes = 0
    var script: String?
    var started = false
    var cancelled = false

    func createPane() -> HerdrCreatedPane {
        panes += 1
        return HerdrCreatedPane(
            workspaceID: "fixture", tabID: "fixture:tab", paneID: "fixture:pane")
    }

    func begin(_ command: String, suspend: Bool) async throws {
        script = command
        started = true
        if suspend {
            do { try await Task.sleep(for: .seconds(30)) } catch { cancelled = true; throw error }
        }
    }
}

@MainActor @Suite(.serialized) struct HerdrAccountTests {
    init() { HerdrWorkOwnership.enable() }
    private func fixture() throws -> URL {
        let temporary = try #require(ProcessInfo.processInfo.environment["TMPDIR"])
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        var attributes = stat()
        try #require(
            lstat(physical, &attributes) == 0 && attributes.st_uid == getuid()
                && attributes.st_mode & S_IFMT == S_IFDIR && attributes.st_mode & 0o777 == 0o700)
        let root = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent("herdr-accounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func accountModel(_ root: URL, accounts: [ClaudeAccount]) async throws
        -> ClaudeAccountsModel
    {
        let model = ClaudeAccountsModel(directory: root.appendingPathComponent("accounts"))
        try await model.load()
        try await model.persist(
            ClaudeAccountsState(accounts: accounts, defaultID: accounts.first?.id))
        return model
    }

    @Test(arguments: ["invalid", UUID().uuidString])
    func invalidOrRemovedAccountCannotCreatePane(selection: String) async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await accountModel(root, accounts: [])
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: HerdrUIDefaults(), claudeAccounts: model,
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
        let store = HerdrStore(
            defaults: HerdrUIDefaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in },
            accountAgentStarter: { launcher, _ in try await recorder.begin(launcher, suspend: false)
            })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: second.id.uuidString)
        for _ in 0..<100 where !(await recorder.started) {
            try await Task.sleep(for: .milliseconds(5))
        }
        let script = try #require(await recorder.script)
        #expect(!script.contains("CLAUDE_CONFIG_DIR"))
        #expect(!script.contains("CLAUDE_SECURESTORAGE_CONFIG_DIR"))
        #expect(script.contains("synthetic-second-key"))
        #expect(!script.contains("synthetic-first-token"))
        #expect(
            script.contains("unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN CLAUDE_CODE_OAUTH_TOKEN"))
        let tagging = try ClaudeAccountSessions.launchArguments(
            account: second.id, directory: model.directory)
        #expect(script.hasSuffix(tagging.map(ShellQuote.quote).joined(separator: " ")))
        #expect(!tagging.joined().contains(first.id.uuidString))
        #expect(store.accountSessions["local|default|fixture:pane"] == second.id.uuidString)
        await store.drain()
    }

    @Test func cancelledOwnedStartupCreatesNoLauncherAndKeepsAccount() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(name: "Synthetic cancelled", credential: "synthetic-token")
        let model = try await accountModel(root, accounts: [account])
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: HerdrUIDefaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in },
            accountAgentStarter: { launcher, _ in try await recorder.begin(launcher, suspend: true)
            })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: account.id.uuidString)
        for _ in 0..<100 where !(await recorder.started) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await recorder.started)
        await store.drain()
        #expect(await recorder.cancelled)
        let profile = try model.directory.appendingPathComponent(account.id.uuidString)
        #expect(!FileManager.default.fileExists(atPath: profile.path))
        #expect(
            try await ClaudeAccountStorage(directory: model.directory).load().accounts.map(\.id)
                == [account.id])
    }

    @Test func retainedLaunchTransmitsAccountIdentityWithoutCredentials() async throws {
        let defaults = HerdrUIDefaults()
        let worker = HerdrWorker(
            store: HerdrStore(defaults: defaults, machinesProvider: { [] }),
            defaults: defaults, automaticActions: false)
        let response: Data
        do {
            response = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        } catch {
            await worker.shutdown()
            throw error
        }
        await worker.shutdown()
        var operation: String?
        var object: [String: Any]?
        let client = HerdrUIClient { command, payload in
            operation = command
            object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
            return response
        }
        let store = HerdrStore(uiClient: client)
        let id = UUID().uuidString
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: id)
        #expect(operation == "herdr.ui.launch")
        #expect(object?["accountID"] as? String == id)
        #expect(Set(try #require(object).keys) == ["kind", "machineID", "beside", "accountID"])
        #expect(store.sessions.isEmpty)
        await store.drain()
    }

    @Test func nonClaudeAccountSelectionCannotCreatePane() async throws {
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: HerdrUIDefaults(),
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in })
        await #expect(throws: ClaudeAccountError.self) {
            try await store.launchNewAgent(
                kind: "Codex", host: .local(herdrPresent: true), existingSpace: nil,
                newSpaceLabel: nil, accountID: UUID().uuidString)
        }
        #expect(await recorder.panes == 0)
    }

    @Test func reusedNativeSessionCannotKeepOldAccountLabel() {
        let store = HerdrStore(defaults: HerdrUIDefaults(), liveWatcher: { _ in })
        var agent = HerdrAgent.make(
            machineID: "local", machineName: "Synthetic Mac", machineIsLocal: true, sshTarget: nil,
            session: "default", pane: "fixture:pane", kind: "Claude Code", status: .working,
            title: "Synthetic", workspace: "fixture", cwd: "/synthetic")
        let accountID = UUID().uuidString
        store.accountSessions[agent.id] = accountID
        agent.nativeSession = HerdrNativeSession(provider: "claude", value: "synthetic-session-one")
        store.apply([.local(herdrPresent: true, agents: [agent])])
        #expect(store.accountSessions[agent.id] == accountID)
        agent.nativeSession = HerdrNativeSession(provider: "claude", value: "synthetic-session-two")
        store.apply([.local(herdrPresent: true, agents: [agent])])
        #expect(store.accountSessions[agent.id] == nil)
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
            defaults: HerdrUIDefaults(), claudeAccounts: model,
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
        let model = ClaudeAccountsModel(directory: invalid)
        let recorder = HerdrAccountLaunchRecorder()
        let store = HerdrStore(
            defaults: HerdrUIDefaults(), claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in })
        try await store.launchNewAgent(
            kind: "Claude Code", host: .local(herdrPresent: true), existingSpace: nil,
            newSpaceLabel: nil, accountID: "cli")
        #expect(await recorder.panes == 1)
        #expect(!model.ready)
        #expect(try Data(contentsOf: invalid) == Data("synthetic invalid storage".utf8))
        await store.drain()
    }

    @Test func malformedUISelectionCannotReachAccountStorageOrCreatePane() async throws {
        let recorder = HerdrAccountLaunchRecorder()
        let defaults = HerdrUIDefaults()
        let model = ClaudeAccountsModel(
            directory: URL(fileURLWithPath: "/synthetic/unavailable/accounts"))
        let store = HerdrStore(
            defaults: defaults, claudeAccounts: model,
            newAgentPaneCreator: { _, _, _, _ in await recorder.createPane() },
            agentStarter: { _, _, _ in }, machinesProvider: { [] })
        store.hosts = [.local(herdrPresent: true)]
        let worker = HerdrWorker(store: store, defaults: defaults, automaticActions: false)
        defer { HerdrWorkOwnership.enable() }
        let payload = try JSONSerialization.data(withJSONObject: [
            "kind": "Claude Code", "machineID": "local", "beside": false, "accountID": 42,
        ])
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.execute("herdr.ui.launch", payload: payload)
        }
        #expect(await recorder.panes == 0)
        #expect(!model.ready)
        await worker.shutdown()
    }

    @Test(arguments: [
        "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_USE_BEDROCK",
    ])
    func sharedEnvironmentCannotOverrideSelectedAccount(name: String) {
        let defaults = HerdrUIDefaults()
        #expect(throws: ClaudeAccountError.self) {
            try HerdrLaunchSettings.setSharedClaudeLaunch(
                arguments: "", environment: name + "=synthetic", in: defaults)
        }
        #expect(HerdrLaunchSettings.sharedEnvironment(in: defaults).isEmpty)
    }

    private func runGuard(_ source: String, home: URL) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", source]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    @Test(arguments: ["private", "public", "hardlink", "symlink", "oversized"])
    func remoteCredentialAdmissionRejectsUnsafeFiles(kind: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("synthetic'credential.json")
        try Data(repeating: 0x78, count: kind == "oversized" ? 65_537 : 2).write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: kind == "public" ? 0o644 : 0o600], ofItemAtPath: file.path)
        if kind == "hardlink" {
            try FileManager.default.linkItem(
                at: file, to: root.appendingPathComponent("synthetic-link"))
        }
        if kind == "symlink" {
            let actual = root.appendingPathComponent("synthetic-target")
            try FileManager.default.moveItem(at: file, to: actual)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: actual)
        }
        let guardSource = try ClaudeAccountImport.remoteCredentialValidation(
            path: file.path, platform: .darwin)
        #expect(try runGuard(guardSource, home: root) == (kind == "private" ? 0 : 1))
    }

    @Test func remoteScopeRejectsSymlinkAncestorBeforeAnyDeletion() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent(".local/share")
        let outside = root.appendingPathComponent("synthetic-original-cli")
        try FileManager.default.createDirectory(
            at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(
            at: outside, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let original = outside.appendingPathComponent(".credentials.json")
        try Data("synthetic untouched CLI".utf8).write(to: original)
        try FileManager.default.createSymbolicLink(
            at: parent.appendingPathComponent("edith"), withDestinationURL: outside)
        let guardSource = try ClaudeAccountImport.remoteScopeValidation(
            accountID: UUID(),
            environment: ["EDITH_APPLICATION_IDENTIFIER": "com.pulkit.edith.dev.synthetic"])
        #expect(try runGuard(guardSource, home: root) != 0)
        #expect(try Data(contentsOf: original) == Data("synthetic untouched CLI".utf8))
    }

    @Test func cancelledDurableLogoutJoinsUsageInvalidation() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HerdrAccountLaunchRecorder()
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("accounts"),
            eraseSecret: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw CancellationError()
            }, invalidateUsage: { await recorder.invalidate() })
        try await model.load()
        let account = ClaudeAccount(name: "Synthetic revoked", credential: "synthetic-secret")
        try await model.persist(ClaudeAccountsState(accounts: [account], defaultID: account.id))
        let task = Task { @MainActor in
            await model.logout(account.id)
            return Task.isCancelled
        }
        #expect(await task.value)
        #expect(await recorder.invalidations == 1)
        let saved = try await ClaudeAccountStorage(directory: model.directory).load()
        #expect(saved.accounts.first?.isLoggedOut == true)
        #expect(saved.accounts.first?.credential.isEmpty == true)
        #expect(saved.accounts.first?.loginData == nil)
    }

    @Test(arguments: [
        "/synthetic/accounts/id", "/synthetic//accounts", "/synthetic/./accounts",
        "/synthetic/../accounts", "synthetic/accounts",
    ])
    func absoluteAccountPathsAdmitOnlyCompleteComponents(path: String) {
        #expect(
            (ClaudeAccountImport.absoluteComponents(path) != nil)
                == (path == "/synthetic/accounts/id"))
    }

    @Test(arguments: ["private", "public", "hardlink", "ancestor-symlink"])
    func explicitImportRejectsUnsafeCredentialFiles(kind: String) throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("synthetic-cli")
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent(".credentials.json")
        let data = Data("synthetic CLI credential".utf8)
        try data.write(to: file)
        try FileManager.default.setAttributes(
            [.posixPermissions: kind == "public" ? 0o644 : 0o600], ofItemAtPath: file.path)
        if kind == "hardlink" {
            try FileManager.default.linkItem(
                at: file, to: root.appendingPathComponent("synthetic-link"))
        }
        var requested = file
        if kind == "ancestor-symlink" {
            let alias = root.appendingPathComponent("synthetic-alias")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: folder)
            requested = alias.appendingPathComponent(".credentials.json")
        }
        #expect(ClaudeAccountImport.readFile(requested) == (kind == "private" ? data : nil))
        #expect(try Data(contentsOf: file) == data)
    }

    @Test func genericUIProjectionDoesNotIncludeSavedCredential() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let model = try await accountModel(
            root,
            accounts: [
                ClaudeAccount(name: "Synthetic account", credential: "synthetic-private-marker")
            ])
        let defaults = HerdrUIDefaults()
        let store = HerdrStore(defaults: defaults, claudeAccounts: model, machinesProvider: { [] })
        let worker = HerdrWorker(store: store, defaults: defaults, automaticActions: false)
        defer { HerdrWorkOwnership.enable() }
        let projection = try await worker.execute("herdr.ui.read", payload: Data("{}".utf8))
        #expect(!String(decoding: projection, as: UTF8.self).contains("synthetic-private-marker"))
        let explicit = try await worker.execute("herdr.ui.accounts.read", payload: Data("{}".utf8))
        #expect(String(decoding: explicit, as: UTF8.self).contains("synthetic-private-marker"))
        await worker.shutdown()
    }
}
