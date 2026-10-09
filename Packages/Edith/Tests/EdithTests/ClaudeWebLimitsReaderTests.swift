import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ClaudeWebLimitsReaderTests {
    private let organization = "00000000-0000-0000-0000-000000000001"
    private let other = "00000000-0000-0000-0000-000000000002"
    private let usage = Data(
        """
        {"five_hour":{"utilization":23,"resets_at":"2099-01-01T05:00:00Z"},
         "seven_day":{"utilization":41,"resets_at":"2099-01-08T00:00:00Z"},
         "limits":[{"kind":"weekly_scoped","percent":7,"resets_at":"2099-01-08T00:00:00Z",
                    "scope":{"model":{"display_name":"Fable"}}}]}
        """.utf8)

    @Test func connectionPermissionIsConsumedByOnlyOneRefresh() async throws {
        let request = ClaudeWebLimitsReader.ConnectionRequest()
        #expect(await request.take() == false)
        await request.request()
        #expect(await request.take() == true)
        #expect(await request.take() == false)
        await request.request()
        await request.discard()
        #expect(await request.take() == false)
        let payload = try AgentPayload.encode(UsageLimitsRefreshRequest(connectBrowser: true))
        #expect(
            try AgentPayload.decode(UsageLimitsRefreshRequest.self, from: payload).connectBrowser)
    }

    @Test func skippedRefreshCannotDelayWebsitePermissionUntilALaterPoll() async throws {
        let suite = "connection-refresh-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Limits.claudeEnabled)
        defaults.set(false, forKey: AppStorageKeys.Limits.codexEnabled)
        defaults.set(false, forKey: AppStorageKeys.Limits.cursorEnabled)
        defaults.set(false, forKey: AppStorageKeys.Limits.grokEnabled)
        let session = LimitsRefreshSession()
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: Date(),
            providers: [
                .init(provider: .claude, session: nil, week: nil, error: "Rate limited")
            ], failure: "Rate limited")
        await session.finish(snapshot, retryNotBefore: [.claude: Date().addingTimeInterval(3600)])
        await ClaudeWebLimitsReader.requestConnection()
        let result = await LimitsCollector.refresh(
            defaults: defaults, refreshSession: session, connectClaude: {}, announce: { _ in })
        #expect(result == snapshot)
        #expect(await ClaudeWebLimitsReader.takeConnection() == false)
    }

    @Test func blockedCredentialReadsTimeOutWithoutStartingMoreWorkers() async {
        let lookup = BoundedKeychainAccess<Bool>()
        let release = DispatchSemaphore(value: 0)
        let result = await lookup.run(timeout: 0.02, fallback: false) {
            release.wait()
            return true
        }
        #expect(!result)
        let second = await lookup.run(timeout: 0.02, fallback: false) {
            Issue.record("A blocked credential read started another worker")
            return true
        }
        #expect(!second)
        release.signal()
    }

    @Test func websiteRefreshUsesTheActiveOrganizationAndPersistsEveryWindow() async throws {
        var requested: [String] = []
        var persisted: LimitsProviderSnapshot?
        let credential = ClaudeWebLimitsReader.Credential(
            sessionKey: "synthetic-session", organization: organization)
        let result = await LimitsCollector.fetchClaude(
            fetch: {
                try await ClaudeWebLimitsReader.fetch(credential: credential) { request in
                    let url = try #require(request.url)
                    requested.append(url.path)
                    #expect(url.host == "claude.ai")
                    #expect(
                        request.value(forHTTPHeaderField: "Cookie")
                            == "sessionKey=synthetic-session")
                    #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
                    let data =
                        requested.count == 1
                        ? Data(
                            "[{\"uuid\":\"\(other)\",\"capabilities\":[\"chat\"]},{\"uuid\":\"\(organization)\",\"capabilities\":[\"chat\"]}]"
                                .utf8)
                        : usage
                    return (
                        data,
                        HTTPURLResponse(
                            url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    )
                }
            },
            fallback: {
                Issue.record("A successful website refresh must not use the CLI fallback");
                return .init(provider: .claude, session: nil, week: nil)
            },
            persist: { persisted = $0 })
        #expect(requested == ["/api/organizations", "/api/organizations/\(organization)/usage"])
        #expect(result.0.session?.percent == 23)
        #expect(result.0.week?.percent == 41)
        #expect(result.0.fable?.percent == 7)
        #expect(result.0.session?.resetsAt == EdithDate.parseISO("2099-01-01T05:00:00Z"))
        #expect(persisted == result.0)
        #expect(result.0.error == nil)
        #expect(result.1 == nil)
    }

    @Test func websiteRefreshReachesTheCliReportThroughPersistedHistory() async throws {
        let url = LimitsHistory.url
        let previous = try? Data(contentsOf: url)
        defer {
            if let previous {
                try? previous.write(to: url)
            } else {
                try? FileManager.default.removeItem(at: url)
            }
        }
        let result = await LimitsCollector.fetchClaude(fetch: {
            try ClaudeWebLimitsReader.limits(json: usage)
        })
        #expect(result.0.error == nil)
        let observation = try #require(LimitsReport.providers().first { $0.provider == .claude })
        #expect(observation.session?.percent == 23)
        #expect(observation.week?.percent == 41)
        #expect(observation.fable?.percent == 7)
        guard case .object(let fields) = LimitsReport.json(observation),
            case .object(let fable)? = fields["fable"]
        else {
            Issue.record("The CLI report omitted the website Fable window")
            return
        }
        #expect(fable["percent"] == .double(7))
    }

    @Test func credentialsUseOnlyTheNewestClaudeCookies() throws {
        func cookie(host: String, name: String, value: String, updated: Double) -> ChromeCookie {
            ChromeCookie(
                host: host, name: name, value: value, path: "/", expires: nil,
                isSecure: true, isHTTPOnly: true, sameSite: .lax,
                updated: Date(timeIntervalSince1970: updated))
        }
        let cookies = [
            cookie(host: ".unrelated.example", name: "sessionKey", value: "unrelated", updated: 20),
            cookie(host: ".claude.ai", name: "sessionKey", value: "old", updated: 1),
            cookie(host: ".claude.ai", name: "sessionKey", value: "current", updated: 2),
            cookie(host: ".claude.ai", name: "lastActiveOrg", value: organization, updated: 2),
        ]
        let credential = try ClaudeWebLimitsReader.credential(cookies: cookies)
        #expect(credential.sessionKey == "current")
        #expect(credential.organization == organization)
        #expect(throws: ClaudeWebLimitsReader.Failure.missingSession) {
            try ClaudeWebLimitsReader.credential(cookies: [cookies[0]])
        }
    }

    @Test func missingAndNullWindowsStayMissingInsteadOfBecomingZero() throws {
        let result = try ClaudeWebLimitsReader.limits(
            json: Data(#"{"five_hour":null,"seven_day":{"utilization":0},"limits":[]}"#.utf8))
        #expect(result.session == nil)
        #expect(result.week?.percent == 0)
        #expect(result.fable == nil)
        #expect(throws: ClaudeWebLimitsReader.Failure.unavailable) {
            try ClaudeWebLimitsReader.limits(json: Data(#"{"five_hour":{},"seven_day":null}"#.utf8))
        }
    }

    @Test func unrelatedModelLimitsNeverBecomeFable() throws {
        let result = try ClaudeWebLimitsReader.limits(
            json: Data(
                #"{"seven_day":{"utilization":4},"limits":[{"kind":"weekly_scoped","percent":99,"scope":{"model":{"display_name":"Other"}}}]}"#
                    .utf8))
        #expect(result.fable == nil)
    }

    @Test func ambiguousAndMissingOrganizationsNeverPickAnotherAccount() {
        let data = Data(
            "[{\"uuid\":\"\(other)\",\"capabilities\":[\"chat\"]},{\"uuid\":\"\(organization)\",\"capabilities\":[\"chat\"]}]"
                .utf8)
        #expect(throws: ClaudeWebLimitsReader.Failure.organization) {
            try ClaudeWebLimitsReader.organization(json: data, selected: nil)
        }
        #expect(throws: ClaudeWebLimitsReader.Failure.organization) {
            try ClaudeWebLimitsReader.organization(json: data, selected: "missing")
        }
    }

    @Test func soleChatOrganizationCanBeSelectedWithoutAnActiveCookie() throws {
        let data = Data(
            "[{\"uuid\":\"\(other)\",\"capabilities\":[\"api\"]},{\"uuid\":\"\(organization)\",\"capabilities\":[\"chat\"]}]"
                .utf8)
        #expect(try ClaudeWebLimitsReader.organization(json: data, selected: nil) == organization)
    }

    @Test(arguments: [401, 403, 429, 500])
    func failuresStopWithoutRetryingOrWritingHistory(status: Int) async {
        let now = Date(timeIntervalSince1970: 0)
        var count = 0
        var persisted = false
        let result = await LimitsCollector.fetchClaude(
            now: now,
            fetch: {
                try await ClaudeWebLimitsReader.fetch(
                    credential: .init(sessionKey: "synthetic", organization: organization)
                ) { request in
                    count += 1
                    return (
                        Data(),
                        HTTPURLResponse(
                            url: request.url!, statusCode: status, httpVersion: nil,
                            headerFields: ["Retry-After": "3600"])!
                    )
                }
            },
            fallback: {
                .init(provider: .claude, session: nil, week: .init(percent: 0, resetsAt: nil))
            },
            persist: { _ in persisted = true })
        #expect(count == 1)
        #expect(!persisted)
        #expect(result.0.session == nil)
        #expect(result.0.week == nil)
        #expect(result.0.error != nil)
        #expect(result.1 == (status == 429 ? now.addingTimeInterval(3600) : nil))
    }

    @Test func browserChallengesRemainVisible() async {
        let result = await LimitsCollector.fetchClaude(
            fetch: {
                try await ClaudeWebLimitsReader.fetch(
                    credential: .init(sessionKey: "synthetic", organization: organization)
                ) { request in
                    (
                        Data(),
                        HTTPURLResponse(
                            url: request.url!, statusCode: 403, httpVersion: nil,
                            headerFields: ["cf-mitigated": "challenge"])!
                    )
                }
            }, fallback: { .init(provider: .claude, session: nil, week: nil) }, persist: { _ in })
        #expect(result.0.error == ClaudeWebLimitsReader.Failure.challenge.localizedDescription)
    }

    @Test func usableCliReadingsRemainAvailableDuringWebsiteFailure() async {
        let saved = LimitsProviderSnapshot(
            provider: .claude, session: .init(percent: 23, resetsAt: nil),
            week: .init(percent: 41, resetsAt: nil))
        let result = await LimitsCollector.fetchClaude(
            fetch: { throw ClaudeWebLimitsReader.Failure.missingSession },
            fallback: { saved }, persist: { _ in Issue.record("Failed refresh wrote history") })
        #expect(result.0.session == saved.session)
        #expect(result.0.week == saved.week)
        #expect(result.0.error != nil)
    }
}
