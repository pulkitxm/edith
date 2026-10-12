import Darwin
import Foundation
import Testing
@testable import EdithExtensionAccounts

@Suite struct AccountSupportSavedLoginTests {
    private func fixture(
        token: String = "synthetic-profile-token", expiry: Double = 4_102_444_800_000,
        scopes: [String] = ["user:profile"]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": token, "expiresAt": expiry, "scopes": scopes]
        ])
    }

    @Test func decoderRejectsExpiredUnscopedOversizedAndInvalidTokens() throws {
        #expect(ClaudeSavedLogin.token(data: try fixture()) == "synthetic-profile-token")
        #expect(ClaudeSavedLogin.token(data: try fixture(expiry: 0)) == nil)
        #expect(ClaudeSavedLogin.token(data: try fixture(scopes: [])) == nil)
        #expect(ClaudeSavedLogin.token(data: try fixture(token: "bad\ntoken")) == nil)
        #expect(ClaudeSavedLogin.token(data: Data(repeating: 32, count: 65_537)) == nil)
    }

    @Test func explicitCredentialImportReadsOnlyTheRequestedScope() throws {
        let data = try fixture()
        let directory = URL(fileURLWithPath: "/synthetic/selected-profile", isDirectory: true)
        var requested: [URL?] = []
        let read = ClaudeSavedLogin.credentials(
            environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": directory.path],
            readFile: { _ in
                Issue.record("Unexpected file read"); return nil
            },
            readScopedSecret: {
                requested.append($0); return data
            })
        #expect(read == data && requested == [directory])
        #expect(
            ClaudeSavedLogin.credentials(
                environment: [:], readFile: { _ in nil },
                readScopedSecret: { _ in Data(repeating: 0, count: 65_537) }) == nil)
    }

    @Test func scopedLookupNeverUsesGlobalSecretsAndLogoutRejectsBeforeRead() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        let fixtureRoot = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: fixtureRoot, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let directory = fixtureRoot.appendingPathComponent("Accounts", isDirectory: true)
        let storage = ClaudeAccountStorage(directory: directory)
        var account = ClaudeAccount(name: "Synthetic", authentication: .browserLogin)
        account.loginData = String(decoding: try fixture(), as: UTF8.self)
        try await storage.save(.init(accounts: [account]))
        var requested: [URL?] = []
        #expect(
            ClaudeSavedLogin.scopedToken(
                account: account, directory: directory,
                readScopedSecret: {
                    requested.append($0); return nil
                }) == "synthetic-profile-token")
        #expect(
            requested == [
                directory.appendingPathComponent(account.id.uuidString, isDirectory: true)
            ])
        _ = try await storage.logout(id: account.id, eraseScopedSecret: { _ in })
        #expect(
            ClaudeSavedLogin.scopedToken(
                account: account, directory: directory,
                readScopedSecret: { _ in
                    Issue.record("Stale account lookup must not read secrets"); return nil
                }) == nil)
        account.isLoggedOut = true
        #expect(
            ClaudeSavedLogin.scopedToken(
                account: account, directory: directory,
                readScopedSecret: { _ in
                    Issue.record("Logged-out lookup must not read secrets"); return nil
                }) == nil)
    }
}
