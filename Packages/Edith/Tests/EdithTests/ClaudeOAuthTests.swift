import Foundation
import Testing
@testable import EdithHelper

@Suite struct ClaudeOAuthCredentialTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func detectsAccessTokenNearExpiry() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(30),
            refreshExpiresAt: now.addingTimeInterval(3_600))
        #expect(credential.shouldRefresh(at: now))
    }

    @Test func keepsAccessTokenWithTimeRemaining() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(600),
            refreshExpiresAt: now.addingTimeInterval(3_600))
        #expect(!credential.shouldRefresh(at: now))
    }

    @Test func rejectsExpiredRefreshToken() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(-1),
            refreshExpiresAt: now.addingTimeInterval(-1))
        #expect(credential.usableRefreshToken(at: now) == nil)
    }

    @Test func savesRotatedTokensAndPreservesOtherCredentials() throws {
        let credential = try decode(
            accessExpiresAt: now.addingTimeInterval(-1),
            refreshExpiresAt: now.addingTimeInterval(60))
        let response = ClaudeOAuthRefreshResponse(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            expiresIn: 600,
            refreshTokenExpiresIn: 3_600)
        let data = try credential.updatedData(with: response, now: now)
        let document = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        let oauth = try #require(document["claudeAiOauth"] as? [String: Any])
        let mcp = try #require(document["mcpOAuth"] as? [String: Any])
        #expect(oauth["accessToken"] as? String == "new-access")
        #expect(oauth["refreshToken"] as? String == "new-refresh")
        #expect(oauth["expiresAt"] as? Int64 == 1_800_000_600_000)
        #expect(oauth["refreshTokenExpiresAt"] as? Int64 == 1_800_003_600_000)
        #expect(mcp["preserved"] as? Bool == true)
    }

    private func decode(accessExpiresAt: Date, refreshExpiresAt: Date) throws
        -> ClaudeOAuthCredential
    {
        let data = try JSONSerialization.data(withJSONObject: [
            "mcpOAuth": ["preserved": true],
            "claudeAiOauth": [
                "accessToken": "old-access",
                "refreshToken": "old-refresh",
                "expiresAt": Int64(accessExpiresAt.timeIntervalSince1970 * 1_000),
                "refreshTokenExpiresAt": Int64(refreshExpiresAt.timeIntervalSince1970 * 1_000),
            ],
        ])
        return try #require(ClaudeOAuthCredential.decode(data, source: .keychain))
    }
}
