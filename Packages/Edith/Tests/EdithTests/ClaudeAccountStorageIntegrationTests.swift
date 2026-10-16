import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct ClaudeAccountStorageIntegrationTests {
    private func fixture() throws -> URL {
        let temporary = FileManager.default.temporaryDirectory.path
        let physical = try #require(realpath(temporary, nil))
        defer { free(physical) }
        let parent = URL(fileURLWithPath: String(cString: physical), isDirectory: true)
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return root
    }

    private func account() throws -> ClaudeAccount {
        var value = ClaudeAccount(name: "Synthetic physical account", authentication: .browserLogin)
        value.loginData = String(
            decoding: try JSONSerialization.data(withJSONObject: [
                "claudeAiOauth": [
                    "accessToken": "synthetic-profile-token",
                    "scopes": ["user:profile"], "expiresAt": 4_102_444_800_000.0,
                ]
            ]), as: UTF8.self)
        return value
    }

    @Test func physicalOwnedStorageResolvesTheSharedScopedLoginWithoutGlobalSecrets() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let storage = ClaudeAccountStorage(directory: directory)
        let value = try account()
        try await storage.save(.init(accounts: [value]))
        try await storage.seedLogin(account: value)
        let token = try await ClaudeLimitsReader.resolveAccountToken(
            value, directory: directory,
            savedLogin: { account, directory in
                ClaudeSavedLogin.scopedToken(
                    account: account, directory: directory,
                    readScopedSecret: { profile in
                        #expect(
                            profile?.path
                                == directory.appendingPathComponent(account.id.uuidString).path)
                        return nil
                    })
            },
            remoteLogin: { _ in
                Issue.record("Local scoped account requested a remote login"); return nil
            })
        #expect(token == "synthetic-profile-token")
        _ = try await storage.logout(id: value.id, eraseScopedSecret: { _ in })
        await #expect(throws: CancellationError.self) {
            try await ClaudeLimitsReader.resolveAccountToken(
                value, directory: directory,
                savedLogin: { _, _ in
                    Issue.record("Revoked account read credentials"); return nil
                },
                remoteLogin: { _ in
                    Issue.record("Revoked account requested a remote login"); return nil
                })
        }
    }

    @Test func durableLogoutDuringHTTPRejectsTheDefaultStorageIdentityAfterTheResponse()
        async throws
    {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Accounts", isDirectory: true)
        let storage = ClaudeAccountStorage(directory: directory)
        let value = try account()
        try await storage.save(.init(accounts: [value]))
        await #expect(throws: CancellationError.self) {
            try await ClaudeLimitsReader.fetchAccount(
                value, directory: directory, resolveToken: { "synthetic-profile-token" },
                send: { request in
                    _ = try await storage.logout(id: value.id, eraseScopedSecret: { _ in })
                    let data = Data("{\"five_hour\":{\"utilization\":23}}".utf8)
                    return (
                        data,
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200,
                            httpVersion: nil, headerFields: nil)!
                    )
                })
        }
        #expect(try await storage.load().accounts.first?.isLoggedOut == true)
    }
}
