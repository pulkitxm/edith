import CryptoKit
import Foundation
import Security
import Testing

@testable import EdithKit

@Suite struct ClaudeLimitsLoginTests {
    @Test func linkedSubscriptionIsUsedOnlyForLimits() async throws {
        var account = ClaudeAccount(name: "Company", credential: "synthetic-launch-token")
        account.limitsProfileID = UUID()
        let root = URL(fileURLWithPath: "/synthetic/accounts")
        let token = try await ClaudeLimitsReader.resolveAccountUsageToken(
            account: account, directory: root,
            limitsLogin: { folder in
                #expect(folder == root.appendingPathComponent(account.limitsProfileID!.uuidString))
                return "synthetic-limits-token"
            },
            subscriptionLogin: { _, _ in
                Issue.record("Do not read another subscription login")
                return nil
            })
        #expect(token == "synthetic-limits-token")
        let launch = try account.launchCommand(command: "cc", arguments: ["--verbose"])
        #expect(launch.contains("synthetic-launch-token"))
        #expect(!launch.contains("synthetic-limits-token"))
        #expect(!launch.contains("CLAUDE_CONFIG_DIR="))
    }

    @Test func rejectedLimitsLoginCannotFallBackToALaunchToken() async throws {
        var account = ClaudeAccount(name: "Company", credential: "synthetic-launch-token")
        account.limitsProfileID = UUID()
        await #expect(throws: ClaudeLimitsReader.Failure.unauthorized) {
            try await ClaudeLimitsReader.resolveAccountUsageToken(
                account: account, directory: URL(fileURLWithPath: "/synthetic/accounts"),
                limitsLogin: { _ in throw ClaudeLimitsReader.Failure.unauthorized })
        }
    }

    @Test(arguments: [RemoteMachinePlatform.darwin, .linux, .windows])
    func limitsConnectionRunsLoginWithoutStartingAnInferenceSession(platform: RemoteMachinePlatform)
        throws
    {
        let account = ClaudeAccount(name: "Company", authentication: .browserLogin)
        let command = try account.launchCommand(
            command: "cc", arguments: ["--verbose"], environment: "IS_DEMO=true",
            platform: platform, configurationPath: "/synthetic/limits",
            authenticationOnly: true)
        #expect(
            command.contains(
                platform == .windows ? "'auth' 'login' '--claudeai'" : "auth login --claudeai"))
        #expect(command.contains("CLAUDE_CONFIG_DIR"))
        #expect(!command.contains("auth status"))
        #expect(!command.contains(".sh"))
        #expect(!command.contains("--print"))
    }

    @Test func renewalPreservesMetadataAndRotatesBothTokens() async throws {
        let updated = try await ClaudeLimitsLogin.renew(
            credentials: credential(), now: Date(timeIntervalSince1970: 1000)
        ) { request in
            #expect(request.url?.absoluteString == "https://platform.claude.com/v1/oauth/token")
            #expect(request.httpMethod == "POST")
            let body = try #require(
                JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String])
            #expect(body["grant_type"] == "refresh_token")
            #expect(body["refresh_token"] == "synthetic-refresh-token")
            #expect(body["scope"] == "user:profile user:inference")
            return response(
                request, status: 200,
                body: [
                    "access_token": "synthetic-renewed-access",
                    "refresh_token": "synthetic-rotated-refresh",
                    "expires_in": 3600, "scope": "user:profile user:inference",
                ])
        }
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let login = try #require(object["claudeAiOauth"] as? [String: Any])
        #expect(login["accessToken"] as? String == "synthetic-renewed-access")
        #expect(login["refreshToken"] as? String == "synthetic-rotated-refresh")
        #expect(login["expiresAt"] as? Double == 4_600_000)
        #expect(login["subscriptionType"] as? String == "max")
        #expect(object["otherSetting"] as? Bool == true)
    }

    @Test func renewedCredentialsPersistWithoutChangingAnotherProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folders = [root.appendingPathComponent("first"), root.appendingPathComponent("second")]
        defer {
            for folder in folders {
                let hash = SHA256.hash(data: Data(folder.path.utf8))
                    .map { String(format: "%02x", $0) }.joined().prefix(8)
                SecItemDelete(
                    [
                        kSecClass as String: kSecClassGenericPassword,
                        kSecAttrService as String: "Claude Code-credentials-" + hash,
                        kSecAttrAccount as String: NSUserName(),
                    ] as CFDictionary)
            }
            try? FileManager.default.removeItem(at: root)
        }
        for (index, folder) in folders.enumerated() {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try await ClaudeLimitsLogin.renew(credentials: credential()) { request in
                response(
                    request, status: 200,
                    body: [
                        "access_token": "synthetic-access-" + String(index), "expires_in": 3600,
                        "scope": "user:profile",
                        "refresh_token": "synthetic-refresh-" + String(index),
                    ])
            }
            try ClaudeLimitsLogin.save(data, folder: folder)
        }
        let reader = ClaudeLimitsLogin()
        for (index, folder) in folders.enumerated() {
            #expect(try await reader.token(folder: folder) == "synthetic-access-" + String(index))
            let file = folder.appendingPathComponent(".credentials.json")
            #expect(
                (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                    as? NSNumber)?.intValue == 0o600)
        }
    }

    @Test func renewalKeepsRefreshTokenWhenServerDoesNotRotateIt() async throws {
        let updated = try await ClaudeLimitsLogin.renew(credentials: credential()) { request in
            response(
                request, status: 200,
                body: [
                    "access_token": "synthetic-renewed-access", "expires_in": 3600,
                    "scope": "user:profile",
                ])
        }
        let object = try #require(JSONSerialization.jsonObject(with: updated) as? [String: Any])
        let login = try #require(object["claudeAiOauth"] as? [String: Any])
        #expect(login["refreshToken"] as? String == "synthetic-refresh-token")
    }

    @Test func inferenceOnlyTokenIsNotRenewedForLimits() async throws {
        await #expect(throws: ClaudeLimitsReader.Failure.missingProfileScope) {
            try await ClaudeLimitsLogin.renew(credentials: credential(scopes: ["user:inference"])) {
                _ in
                Issue.record("A login without profile scope must not be sent")
                throw ClaudeLimitsReader.Failure.unavailable
            }
        }
    }

    @Test func renewalHonorsServerThrottling() async throws {
        await #expect(throws: ClaudeLimitsReader.Failure.rateLimited(120)) {
            try await ClaudeLimitsLogin.renew(credentials: credential()) { request in
                (
                    Data(),
                    HTTPURLResponse(
                        url: request.url!, statusCode: 429, httpVersion: nil,
                        headerFields: ["Retry-After": "120"])!
                )
            }
        }
    }

    @Test func rejectedRenewalNeedsReconnection() async throws {
        await #expect(throws: ClaudeLimitsReader.Failure.unauthorized) {
            try await ClaudeLimitsLogin.renew(credentials: credential()) { request in
                response(request, status: 400, body: ["error": "invalid_grant"])
            }
        }
    }

    private func credential(scopes: [String] = ["user:profile", "user:inference"]) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "otherSetting": true,
            "claudeAiOauth": [
                "accessToken": "synthetic-expired-token", "refreshToken": "synthetic-refresh-token",
                "expiresAt": 1, "scopes": scopes, "subscriptionType": "max",
            ],
        ])
    }

    private func response(_ request: URLRequest, status: Int, body: [String: Any])
        -> (Data, HTTPURLResponse)
    {
        (
            try! JSONSerialization.data(withJSONObject: body),
            HTTPURLResponse(
                url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}
