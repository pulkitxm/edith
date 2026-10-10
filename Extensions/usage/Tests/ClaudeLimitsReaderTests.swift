import Foundation
import Testing

@testable import UsageExtension

@Suite struct ClaudeLimitsReaderTests {
    private let usage = Data(
        """
        {"five_hour":{"utilization":23,"resets_at":"2099-01-01T05:00:00Z"},
         "seven_day":{"utilization":41,"resets_at":"2099-01-08T00:00:00Z"},
         "seven_day_fable":{"utilization":7,"resets_at":"2099-01-08T00:00:00Z"}}
        """.utf8)

    @Test func shellTokenIsAvailableToTheBackgroundReader() async throws {
        let token = try await ClaudeLimitsReader.resolveToken(
            environment: [:],
            shell: {
                ["CLAUDE_CODE_OAUTH_TOKEN": "synthetic-shell-token"]
            })
        #expect(token == "synthetic-shell-token")
    }

    @Test func inheritedTokenTakesPrecedenceWithoutRunningTheShell() async throws {
        let token = try await ClaudeLimitsReader.resolveToken(
            environment: ["CLAUDE_CODE_OAUTH_TOKEN": "synthetic-process-token"],
            shell: {
                Issue.record("An inherited token must not run the shell"); return nil
            })
        #expect(token == "synthetic-process-token")
    }

    @Test(arguments: ["", "invalid\ntoken", String(repeating: "x", count: 8193)])
    func missingOrMalformedTokensNeverReachTheApi(value: String) async {
        await #expect(throws: ClaudeLimitsReader.Failure.self) {
            try await ClaudeLimitsReader.resolveToken(
                environment: ["CLAUDE_CODE_OAUTH_TOKEN": value],
                shell: {
                    Issue.record("An explicit token must not fall back"); return nil
                })
        }
    }

    @Test func oauthRefreshPersistsEveryWindowWithBearerAuthentication() async throws {
        var count = 0
        var persisted: LimitsProviderSnapshot?
        let result = await LimitsCollector.fetchClaude(
            fetch: {
                try await ClaudeLimitsReader.fetch(token: "synthetic-token") { request in
                    count += 1
                    #expect(
                        request.url?.absoluteString
                            == "https://api.anthropic.com/api/oauth/usage?cedar_ember=1")
                    #expect(
                        request.value(forHTTPHeaderField: "Authorization")
                            == "Bearer synthetic-token")
                    #expect(
                        request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
                    #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
                    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
                    #expect(
                        request.value(forHTTPHeaderField: "User-Agent")
                            == "claude-cli/2.1.0 (external, cli)")
                    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                    return (usage, response(request, status: 200))
                }
            },
            fallback: {
                Issue.record("A successful API read must not use saved limits");
                return .init(provider: .claude, session: nil, week: nil)
            },
            persist: { persisted = $0 })
        #expect(count == 1)
        #expect(result.0.session?.percent == 23)
        #expect(result.0.week?.percent == 41)
        #expect(result.0.fable?.percent == 7)
        #expect(result.0.session?.resetsAt == EdithDate.parseISO("2099-01-01T05:00:00Z"))
        #expect(persisted == result.0)
        #expect(result.0.error == nil)
        #expect(result.1 == nil)
    }

    @Test func missingWindowsStayMissingAndReportedZeroStaysZero() throws {
        let result = try ClaudeLimitsReader.limits(
            json: Data("{\"five_hour\":{\"utilization\":0}}".utf8))
        #expect(result.session?.percent == 0)
        #expect(result.week == nil)
        #expect(result.fable == nil)
        #expect(throws: ClaudeLimitsReader.Failure.unavailable) {
            try ClaudeLimitsReader.limits(json: Data("{}".utf8))
        }
    }

    @Test func scopedFableWindowDoesNotConsumeAnotherModelsWindow() throws {
        let json = Data(
            """
            {"seven_day":{"utilization":41},"limits":[
             {"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Other"}}},
             {"kind":"weekly_scoped","percent":7,"scope":{"model":{"display_name":"Fable"}}}]}
            """.utf8)
        #expect(try ClaudeLimitsReader.limits(json: json).fable?.percent == 7)
    }

    @Test func insufficientProfileScopeIsReportedWithoutEchoingTheResponse() async {
        var count = 0
        let body = Data(
            "{\"error\":{\"message\":\"synthetic-secret-token does not meet scope requirement user:profile\"}}"
                .utf8)
        let result = await LimitsCollector.fetchClaude(
            fetch: {
                try await ClaudeLimitsReader.fetch(token: "synthetic-token") { request in
                    count += 1
                    return (body, response(request, status: 403))
                }
            }, fallback: { .init(provider: .claude, session: nil, week: nil) },
            persist: { _ in Issue.record("Rejected tokens must not persist limits") })
        #expect(
            result.0.error == ClaudeLimitsReader.Failure.missingProfileScope.localizedDescription)
        #expect(result.0.error?.contains("synthetic-secret-token") == false)
        #expect(count == 1)
    }

    @Test(arguments: [400, 403])
    func optionalInventoryRejectionRetriesWithTheSameCredential(status: Int) async throws {
        var count = 0
        let result = try await ClaudeLimitsReader.fetch(token: "synthetic-token") { request in
            count += 1
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
            if count == 1 {
                #expect(request.url?.query == "cedar_ember=1")
                return (Data(), response(request, status: status))
            }
            #expect(request.url?.query == nil)
            #expect(request.value(forHTTPHeaderField: "User-Agent") == "claude-cli/2.1.0")
            return (usage, response(request, status: 200))
        }
        #expect(count == 2)
        #expect(result.fable?.percent == 7)
    }

    @Test(arguments: [401, 403, 429, 500])
    func failuresDoNotTurnOldWeeklyZerosIntoCurrentUsage(status: Int) async {
        let now = Date(timeIntervalSince1970: 1000)
        var count = 0
        let result = await LimitsCollector.fetchClaude(
            now: now,
            fetch: {
                try await ClaudeLimitsReader.fetch(token: "synthetic-token") { request in
                    count += 1
                    return (
                        Data(), response(request, status: status, headers: ["Retry-After": "3600"])
                    )
                }
            },
            fallback: {
                .init(provider: .claude, session: nil, week: .init(percent: 0, resetsAt: nil))
            },
            persist: { _ in Issue.record("Failed API requests must not persist limits") })
        #expect(count == (status == 403 ? 2 : 1))
        #expect(result.0.session == nil)
        #expect(result.0.week == nil)
        #expect(result.0.error != nil)
        #expect(result.1 == (status == 429 ? now.addingTimeInterval(3600) : nil))
    }

    @Test func currentStatusLineReadingsRemainAvailableDuringApiFailure() async {
        let saved = LimitsProviderSnapshot(
            provider: .claude, session: .init(percent: 23, resetsAt: nil),
            week: .init(percent: 41, resetsAt: nil))
        let result = await LimitsCollector.fetchClaude(
            fetch: { throw ClaudeLimitsReader.Failure.missingToken },
            fallback: { saved }, persist: { _ in Issue.record("Failed refresh wrote history") })
        #expect(result.0.session == saved.session)
        #expect(result.0.week == saved.week)
        #expect(result.0.error != nil)
    }

    private func response(_ request: URLRequest, status: Int, headers: [String: String] = [:])
        -> HTTPURLResponse
    {
        HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }
}
