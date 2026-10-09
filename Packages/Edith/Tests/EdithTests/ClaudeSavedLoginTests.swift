import Foundation
import LocalAuthentication
import Security
import Testing

@testable import EdithKit

@Suite struct ClaudeSavedLoginTests {
    private let now = Date(timeIntervalSince1970: 1000)

    @Test func scopedLoginTakesPrecedenceOverAnInferenceOnlyShellToken() async throws {
        let token = try await ClaudeLimitsReader.resolveUsageToken(
            savedLogin: { "synthetic-login-token" },
            shellToken: {
                Issue.record("A scoped login must not use the shell token")
                return "synthetic-inference-token"
            })
        #expect(token == "synthetic-login-token")
    }

    @Test func missingLoginUsesTheShellToken() async throws {
        let token = try await ClaudeLimitsReader.resolveUsageToken(
            savedLogin: { nil }, shellToken: { "synthetic-shell-token" })
        #expect(token == "synthetic-shell-token")
    }

    @Test func keychainQueryOnlyReadsTheCliLoginAndCannotPrompt() throws {
        var count = 0
        let token = ClaudeSavedLogin.token(
            environment: [:], now: now,
            readFile: { _ in
                Issue.record("The default login must not read a file"); return nil
            },
            readKeychain: { query in
                count += 1
                #expect(query[kSecClass as String] as? String == kSecClassGenericPassword as String)
                #expect(query[kSecAttrService as String] as? String == "Claude Code-credentials")
                #expect(query[kSecReturnData as String] as? Bool == true)
                #expect(query[kSecMatchLimit as String] as? String == kSecMatchLimitOne as String)
                #expect(
                    (query[kSecUseAuthenticationContext as String] as? LAContext)?
                        .interactionNotAllowed == true)
                return credential()
            })
        #expect(count == 1)
        #expect(token == "synthetic-login-token")
    }

    @Test func configuredProfileDoesNotReadAnotherAccountsKeychain() {
        let token = ClaudeSavedLogin.token(
            environment: ["CLAUDE_CONFIG_DIR": "/synthetic/profile"], now: now,
            readFile: { url in
                #expect(url.path == "/synthetic/profile/.credentials.json")
                return credential()
            },
            readKeychain: { _ in
                Issue.record("A configured profile must stay isolated"); return nil
            })
        #expect(token == "synthetic-login-token")
    }

    @Test func missingConfiguredProfileCannotFallBackToTheDefaultAccount() {
        #expect(
            ClaudeSavedLogin.token(
                environment: ["CLAUDE_CONFIG_DIR": "/synthetic/missing-profile"], now: now,
                readFile: { _ in nil },
                readKeychain: { _ in
                    Issue.record("The default account must not be read"); return nil
                })
                == nil)
    }

    @Test(arguments: [999_000.0, 1_000_000.0])
    func expiredCredentialsAreNotSentToTheApi(expiry: Double) {
        #expect(
            ClaudeSavedLogin.token(
                environment: [:], now: now, readKeychain: { _ in credential(expiry: expiry) })
                == nil)
    }

    @Test(arguments: ["", "invalid\ntoken", String(repeating: "x", count: 8193)])
    func malformedCredentialsAreNotSelected(token: String) {
        #expect(
            ClaudeSavedLogin.token(
                environment: [:], now: now, readKeychain: { _ in credential(token: token) }) == nil)
    }

    @Test func inferenceOnlyLoginCannotBeSelectedForUsage() {
        #expect(
            ClaudeSavedLogin.token(
                environment: [:], now: now,
                readKeychain: { _ in credential(scopes: ["user:inference"]) }) == nil)
    }

    @Test(arguments: [Data(), Data("{}".utf8), Data(repeating: 0, count: 65_537)])
    func absentOrMalformedDataLeavesShellAuthenticationAvailable(data: Data) {
        #expect(
            ClaudeSavedLogin.token(environment: [:], now: now, readKeychain: { _ in data }) == nil)
    }

    @Test func savedLoginReachesTheUsageApiAndPersistsEveryWindow() async throws {
        var persisted: LimitsProviderSnapshot?
        let result = await LimitsCollector.fetchClaude(
            fetch: {
                let token = try await ClaudeLimitsReader.resolveUsageToken(
                    savedLogin: {
                        ClaudeSavedLogin.token(
                            environment: [:], now: now, readKeychain: { _ in credential() })
                    },
                    shellToken: {
                        Issue.record("The API must use the scoped login"); return "inference-token"
                    })
                return try await ClaudeLimitsReader.fetch(token: token) { request in
                    #expect(
                        request.value(forHTTPHeaderField: "Authorization")
                            == "Bearer synthetic-login-token")
                    let data = Data(
                        "{\"five_hour\":{\"utilization\":23},\"seven_day\":{\"utilization\":41},\"seven_day_fable\":{\"utilization\":7}}"
                            .utf8)
                    return (
                        data,
                        HTTPURLResponse(
                            url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            }, fallback: { .init(provider: .claude, session: nil, week: nil) },
            persist: { persisted = $0 })
        #expect(result.0.error == nil)
        #expect(persisted?.session?.percent == 23)
        #expect(persisted?.week?.percent == 41)
        #expect(persisted?.fable?.percent == 7)
    }

    private func credential(
        token: String = "synthetic-login-token",
        scopes: [String] = ["user:profile", "user:inference"],
        expiry: Double = 2_000_000
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["accessToken": token, "scopes": scopes, "expiresAt": expiry]
        ])
    }
}
