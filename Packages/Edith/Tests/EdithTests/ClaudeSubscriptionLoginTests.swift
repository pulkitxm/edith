import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor @Suite(.serialized) struct ClaudeSubscriptionLoginTests {
    private func fixture() throws -> URL {
        let root = try PhysicalTemporaryDirectory.url()
            .appendingPathComponent("claude-subscription-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func defaults() throws -> UserDefaults {
        let suite = "claude-subscription." + UUID().uuidString
        let value = try #require(UserDefaults(suiteName: suite))
        value.removePersistentDomain(forName: suite)
        return value
    }

    private func model(
        _ root: URL, login: ClaudeSubscriptionLogin, account: ClaudeAccount
    ) async throws -> ClaudeAccountsModel {
        let model = ClaudeAccountsModel(
            directory: root.appendingPathComponent("Accounts"), subscriptionLogin: login,
            eraseSecret: { _ in }, notifyUsage: {})
        try await model.load()
        try await model.persist(.init(accounts: [account], defaultID: account.id))
        return model
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    @Test func launchSignsInWithAPrivateProfileAndNoInheritedCredentials() throws {
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let profile = UUID()
        let folder = URL(fileURLWithPath: "/synthetic/Accounts")
            .appendingPathComponent(profile.uuidString)
        let launch = try ClaudeLimitsLoginLaunch.prepare(
            account: account, profileID: profile, folder: folder, command: "claude",
            sharedEnvironment: "IS_DEMO=1",
            inheritedEnvironment: [
                "PATH": "/usr/bin", "ANTHROPIC_API_KEY": "synthetic-inherited",
                "CLAUDE_CONFIG_DIR": "/synthetic/other", "HISTFILE": "/synthetic/history",
            ])
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.currentDirectory == folder.path)
        #expect(launch.arguments.prefix(3) == ["-l", "-i", "-c"])
        let script = try #require(launch.arguments.last)
        #expect(script.hasPrefix("unset HISTFILE; SAVEHIST=0; unset ANTHROPIC_API_KEY"))
        #expect(script.contains("export IS_DEMO=1"))
        #expect(script.contains("export CLAUDE_CONFIG_DIR=" + ShellQuote.quote(folder.path)))
        #expect(script.hasSuffix("claude auth login"))
        #expect(!script.contains("synthetic-token"))
        #expect(
            launch.environment.sorted() == ["HISTFILE=/dev/null", "PATH=/usr/bin", "SAVEHIST=0"])
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeLimitsLoginLaunch.prepare(
                account: ClaudeAccount(
                    name: "Key", authentication: .apiKey, credential: "synthetic-key"),
                profileID: profile, folder: folder, command: "claude", sharedEnvironment: "",
                inheritedEnvironment: [:])
        }
    }

    @Test func successfulSignInLinksTheNewLimitsProfile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let login = ClaudeSubscriptionLogin(
            runTerminal: { _, launch in
                let file = URL(fileURLWithPath: launch.currentDirectory)
                    .appendingPathComponent(".credentials.json")
                FileManager.default.createFile(
                    atPath: file.path, contents: Data("{}".utf8),
                    attributes: [.posixPermissions: 0o600])
                return 0
            }, eraseScopedSecret: { _ in }, inheritedEnvironment: { [:] })
        let accounts = try await model(root, login: login, account: account)
        login.start(accountID: account.id, accounts: accounts, defaults: try defaults())
        #expect(login.running)
        try await waitUntil { !login.running }
        #expect(login.connected && login.error == nil)
        let linked = try #require(accounts.account(account.id)?.limitsProfileID)
        #expect(
            FileManager.default.fileExists(
                atPath: accounts.directory.appendingPathComponent(linked.uuidString).path))
        #expect(accounts.account(account.id)?.credential == "synthetic-token")
    }

    @Test func failedSignInLeavesTheAccountUnlinkedAndRemovesItsProfile() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let erased = ClaudeSubscriptionLoginRecorder()
        let login = ClaudeSubscriptionLogin(
            runTerminal: { _, _ in 1 }, eraseScopedSecret: { erased.record($0) },
            inheritedEnvironment: { [:] })
        let accounts = try await model(root, login: login, account: account)
        login.start(accountID: account.id, accounts: accounts, defaults: try defaults())
        try await waitUntil { !login.running }
        #expect(login.error == "Subscription sign-in did not finish. Try again.")
        #expect(!login.connected)
        try await accounts.load()
        #expect(accounts.account(account.id)?.limitsProfileID == nil)
        #expect(erased.values.count == 1)
        let remaining = try FileManager.default.contentsOfDirectory(atPath: accounts.directory.path)
            .filter { UUID(uuidString: $0) != nil }
        #expect(remaining.isEmpty)
    }

    @Test func cancelledSignInStopsTheTerminalWithoutAnError() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let account = ClaudeAccount(name: "Synthetic", credential: "synthetic-token")
        let login = ClaudeSubscriptionLogin(
            runTerminal: { _, _ in
                try await Task.sleep(for: .seconds(30))
                return 0
            }, eraseScopedSecret: { _ in }, inheritedEnvironment: { [:] })
        let accounts = try await model(root, login: login, account: account)
        login.start(accountID: account.id, accounts: accounts, defaults: try defaults())
        login.start(accountID: account.id, accounts: accounts, defaults: try defaults())
        #expect(login.error == "Close the current subscription sign-in before starting another.")
        try await Task.sleep(for: .milliseconds(50))
        await login.cancel(accountID: account.id)
        #expect(!login.running && !login.connected)
        try await accounts.load()
        #expect(accounts.account(account.id)?.limitsProfileID == nil)
    }
}

private final class ClaudeSubscriptionLoginRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    var values: [URL] { lock.withLock { stored } }
    func record(_ url: URL) { lock.withLock { stored.append(url) } }
}
