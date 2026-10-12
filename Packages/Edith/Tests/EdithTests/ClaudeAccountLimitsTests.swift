import AppKit
import EdithKit
import Security
import SwiftUI
import Testing
@testable import EdithHelper
@testable import EdithKit

@Suite struct ClaudeAccountLimitsTests {
    @Test func namedAccountsReplaceTheDefaultCredentialPoll() {
        let providers: [LimitProvider] = [.claude, .codex]
        #expect(LimitsCollector.pollingProviders(providers, accounts: []) == providers)
        #expect(
            LimitsCollector.pollingProviders(providers, accounts: [ClaudeAccount(name: "Company")])
                == [.codex])
    }

    @Test func menuBarKeepsTwoAccountsNamedAndBoundsLargerSets() {
        let accounts = fixtures(5)
        #expect(
            ClaudeAccountLimitsLayout.inlineAccounts(Array(accounts.prefix(2)), selectedID: nil)
                .count == 2)
        #expect(
            ClaudeAccountLimitsLayout.inlineAccounts(
                accounts, selectedID: accounts[3].id.uuidString
            ).map(\.id) == [accounts[3].id])
        #expect(
            ClaudeAccountLimitsLayout.inlineAccounts(accounts, selectedID: "removed").map(\.id) == [
                accounts[0].id
            ])
        #expect(ClaudeAccountLimitsLayout.inlineAccounts([], selectedID: nil).isEmpty)
    }

    @Test func accountRefreshKeepsFailuresSeparateAndHonorsRetryAfter() async throws {
        let accounts = (0..<5).map {
            ClaudeAccount(name: "Account \($0)", credential: "synthetic-\($0)")
        }
        let collector = ClaudeAccountLimitsCollector()
        let calls = AccountLimitsCalls()
        let now = Date()
        let read: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            account, _ in
            await calls.record(account.id)
            if account.id == accounts[2].id { throw ClaudeLimitsReader.Failure.rateLimited(300) }
            return LimitsProviderSnapshot(
                provider: .claude, session: LimitWindow(percent: 20, resetsAt: nil),
                week: LimitWindow(percent: 40, resetsAt: nil)
            )
        }
        let first = await collector.refresh(accounts: accounts, now: now, fetch: read)
        #expect(first.map(\.id) == accounts.map(\.id))
        #expect(first[2].limits.session == nil)
        #expect(first[2].limits.error != nil)
        #expect(first[0].limits.error == nil)
        _ = await collector.refresh(
            accounts: accounts, now: now.addingTimeInterval(30), fetch: read)
        #expect(await calls.count == 5)
        _ = await collector.refresh(
            accounts: accounts, now: now.addingTimeInterval(61), fetch: read)
        #expect(await calls.count == 9)
        let encoded = try JSONEncoder().encode(first)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("synthetic-"))
        let remaining = await collector.refresh(
            accounts: Array(accounts.prefix(1)), now: now.addingTimeInterval(62), fetch: read)
        #expect(remaining.count == 1)
    }

    @Test func duplicateCredentialsAndRenamesDoNotRepeatRateLimitedRequests() async {
        var company = ClaudeAccount(name: "Company", credential: "synthetic-shared-token")
        let duplicate = ClaudeAccount(name: "Current CLI account", credential: company.credential)
        let collector = ClaudeAccountLimitsCollector()
        let calls = AccountLimitsCalls()
        let now = Date()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            account, _ in
            await calls.record(account.id)
            throw ClaudeLimitsReader.Failure.rateLimited(300)
        }
        let first = await collector.refresh(accounts: [company, duplicate], now: now, fetch: fetch)
        #expect(first.map(\.id) == [company.id, duplicate.id])
        #expect(await calls.count == 1)
        company.name = "Renamed company"
        let second = await collector.refresh(
            accounts: [company], now: now.addingTimeInterval(61), fetch: fetch)
        #expect(second.first?.name == company.name)
        #expect(await calls.count == 1)
        _ = await collector.refresh(
            accounts: [company], now: now.addingTimeInterval(301), fetch: fetch)
        #expect(await calls.count == 2)
    }

    @Test func concurrentRefreshesCoalesceWithoutCrossAccountTokens() async {
        let accounts = [ClaudeAccount(name: "Company", credential: "synthetic-company")]
        let collector = ClaudeAccountLimitsCollector()
        let calls = AccountLimitsCalls()
        let read: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            account, _ in
            await calls.record(account.id)
            try await Task.sleep(for: .milliseconds(20))
            return LimitsProviderSnapshot(
                provider: .claude, session: LimitWindow(percent: 25, resetsAt: nil), week: nil)
        }
        async let first = collector.refresh(accounts: accounts, fetch: read)
        async let second = collector.refresh(accounts: accounts, fetch: read)
        let results = await (first, second)
        #expect(results.0 == results.1)
        #expect(await calls.count == 1)
    }

    @Test func apiKeyAccountsDoNotCallTheSubscriptionUsageEndpoint() async {
        await #expect(throws: (any Error).self) {
            try await ClaudeLimitsReader.fetch(
                account: ClaudeAccount(
                    name: "API", authentication: .apiKey, credential: "synthetic-key"),
                directory: URL(fileURLWithPath: "/synthetic"))
        }
    }

    @Test func notchUsesDetailedRowsForTwoAndCompactRowsForFive() {
        for count in [2, 5] {
            let accounts = fixtures(count)
            let snapshot = LimitsTopicSnapshot(
                refreshedAt: Date(), providers: [.init(provider: .claude, session: nil, week: nil)],
                failure: nil, claudeAccounts: accounts)
            let projection = SurfaceCoreProjection.limits(
                snapshot, tile: SurfaceTile(.limits))
            #expect(projection.rows.count == (count == 2 ? 4 : 5))
            #expect(projection.rows.allSatisfy { $0.sourceID == "claude" })
            #expect(projection.rows.first?.title.contains(accounts[0].name) == true)
            #expect(projection.metrics.first(where: { $0.id == "accounts" })?.value == "\(count)")
        }
    }

    @Test func browserLoginReadsOnlyItsScopedKeychainWithoutPrompting() {
        let json = Data(
            "{\"claudeAiOauth\":{\"accessToken\":\"synthetic-profile-token\",\"expiresAt\":4102444800000,\"scopes\":[\"user:profile\"]}}"
                .utf8)
        let token = ClaudeSavedLogin.token(
            environment: ["CLAUDE_SECURESTORAGE_CONFIG_DIR": "/synthetic/profile"],
            readFile: { _ in
                Issue.record("The scoped Keychain should supply the token"); return nil
            },
            readKeychain: { query in
                #expect(
                    query[kSecAttrService as String] as? String
                        == "Claude Code-credentials-fead5c03")
                return json
            })
        #expect(token == "synthetic-profile-token")
    }

    @MainActor @Test func menuBarNamesAndPrivacyMaskApplyToEachAccount() {
        let accounts = fixtures(2)
        let groups = LimitsStatusItem.accountGroups(accounts, masked: false)
        #expect(groups.count == 2)
        #expect(groups[0].columns[0].label.hasPrefix("Company"))
        #expect(groups[1].columns[0].label.hasPrefix("Personal"))
        #expect(
            LimitsStatusItem.accountGroups(accounts, masked: true).flatMap(\.columns).allSatisfy {
                $0.value == "·"
            })
        let view = StackedLimitsView()
        view.groups = LimitsStatusItem.accountGroups(
            ClaudeAccountLimitsLayout.inlineAccounts(fixtures(5), selectedID: nil), masked: false)
        #expect(view.desiredWidth < 180)
    }

    private func fixtures(_ count: Int) -> [ClaudeAccountLimits] {
        (0..<count).map { index in
            ClaudeAccountLimits(
                id: UUID(),
                name: index == 0 ? "Company" : index == 1 ? "Personal" : "Team \(index)",
                limits: .init(
                    provider: .claude,
                    session: LimitWindow(percent: Double(20 + index * 10), resetsAt: nil),
                    week: LimitWindow(percent: Double(40 + index * 8), resetsAt: nil)),
                refreshedAt: Date())
        }
    }
}

private actor AccountLimitsCalls {
    private(set) var count = 0
    func record(_ id: UUID) { count += 1 }
}
