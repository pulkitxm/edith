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

    @Test func throttlingRetainsLastKnownLimitsAndBackoffAcrossRestarts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("limits.json")
        let account = ClaudeAccount(name: "Company", credential: "synthetic-private-token")
        let collector = ClaudeAccountLimitsCollector(cacheFile: file)
        let now = Date()
        let calls = AccountLimitsCalls()
        let success: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            _, _ in
            await calls.record(account.id)
            return LimitsProviderSnapshot(
                provider: .claude, session: LimitWindow(percent: 25, resetsAt: nil),
                week: LimitWindow(percent: 40, resetsAt: nil))
        }
        let failure: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            _, _ in
            await calls.record(account.id)
            throw ClaudeLimitsReader.Failure.rateLimited(300)
        }
        _ = await collector.refresh(accounts: [account], now: now, fetch: success)
        let stale = await collector.refresh(
            accounts: [account], now: now.addingTimeInterval(61), fetch: failure)
        #expect(stale.first?.limits.session?.percent == 25)
        #expect(stale.first?.limits.week?.percent == 40)
        #expect(stale.first?.refreshedAt == now)
        #expect(stale.first?.retryAt == now.addingTimeInterval(361))
        #expect(stale.first?.limits.error != nil)
        let restarted = ClaudeAccountLimitsCollector(cacheFile: file)
        let waiting = await restarted.refresh(
            accounts: [account], now: now.addingTimeInterval(100), fetch: success)
        #expect(waiting == stale)
        #expect(await calls.count == 2)
        let fresh = await restarted.refresh(
            accounts: [account], now: now.addingTimeInterval(362), fetch: success)
        #expect(fresh.first?.limits.error == nil)
        #expect(fresh.first?.retryAt == nil)
        #expect(fresh.first?.refreshedAt == now.addingTimeInterval(362))
        #expect(await calls.count == 3)
        let data = try Data(contentsOf: file)
        #expect(!String(decoding: data, as: UTF8.self).contains(account.credential))
        #expect(
            (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
                as? NSNumber)?.intValue == 0o600)
    }

    @Test func separateLimitsConnectionsDoNotShareCachedReadings() async {
        var first = ClaudeAccount(name: "First", credential: "synthetic-shared-launch-token")
        var second = ClaudeAccount(name: "Second", credential: first.credential)
        first.limitsProfileID = UUID()
        second.limitsProfileID = UUID()
        let collector = ClaudeAccountLimitsCollector()
        let now = Date()
        let expectedID = first.id
        let results = await collector.refresh(accounts: [first, second], now: now) { account, _ in
            LimitsProviderSnapshot(
                provider: .claude,
                session: LimitWindow(percent: account.id == expectedID ? 25 : 80, resetsAt: nil),
                week: nil)
        }
        #expect(results.map { $0.limits.session?.percent } == [25, 80])
        first.limitsProfileID = UUID()
        let reconnected = await collector.refresh(accounts: [first, second], now: now) { _, _ in
            throw ClaudeLimitsReader.Failure.unauthorized
        }
        #expect(reconnected[0].limits.session == nil)
        #expect(reconnected[1].limits.session?.percent == 80)
    }

    @Test func changedCredentialsNeverReuseAnotherTokensLastKnownLimits() async {
        var account = ClaudeAccount(name: "Company", credential: "synthetic-old-token")
        let collector = ClaudeAccountLimitsCollector()
        let now = Date()
        _ = await collector.refresh(accounts: [account], now: now) { _, _ in
            LimitsProviderSnapshot(
                provider: .claude, session: LimitWindow(percent: 30, resetsAt: nil), week: nil)
        }
        account.credential = "synthetic-new-token"
        let result = await collector.refresh(accounts: [account], now: now.addingTimeInterval(61)) {
            _, _ in
            throw ClaudeLimitsReader.Failure.rateLimited(nil)
        }
        #expect(result.first?.limits.session == nil)
        #expect(result.first?.retryAt == now.addingTimeInterval(1861))
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

    @MainActor @Test func renderStaleAndUnavailableLimitsWithSyntheticAccounts() async throws {
        guard let output = ProcessInfo.processInfo.environment["EDITH_LIMITS_CACHE_EVIDENCE_DIR"]
        else { return }
        let accounts = [
            ClaudeAccount(name: "Company", credential: "synthetic-company-token"),
            ClaudeAccount(name: "Personal", credential: "synthetic-personal-token"),
        ]
        let collector = ClaudeAccountLimitsCollector()
        let now = Date().addingTimeInterval(-120)
        _ = await collector.refresh(accounts: accounts, now: now) { account, _ in
            if account.id == accounts[1].id { throw ClaudeLimitsReader.Failure.rateLimited(300) }
            return LimitsProviderSnapshot(
                provider: .claude, session: LimitWindow(percent: 25, resetsAt: nil),
                week: LimitWindow(percent: 40, resetsAt: nil))
        }
        let stale = await collector.refresh(accounts: accounts, now: now.addingTimeInterval(61)) {
            _, _ in
            throw ClaudeLimitsReader.Failure.rateLimited(300)
        }
        let host = NSHostingView(
            rootView:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Rate limits").font(.edithText(.headline))
                    ClaudeAccountLimitsView(accounts: stale, compact: true)
                    Spacer()
                }.padding(18).frame(width: 330, height: 420)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, .dark))
        host.appearance = NSAppearance(named: .darkAqua)
        host.frame = NSRect(x: 0, y: 0, width: 330, height: 420)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent("limits-retry.png"))
    }

    private func fixtures(_ count: Int) -> [ClaudeAccountLimits] {
        (0..<count).map { index -> ClaudeAccountLimits in
            let name: String
            switch index {
            case 0: name = "Company"
            case 1: name = "Personal"
            default: name = "Team \(index)"
            }
            let sessionPercent = Double(20 + index * 10)
            let weekPercent = Double(40 + index * 8)
            let session = LimitWindow(percent: sessionPercent, resetsAt: nil)
            let week = LimitWindow(percent: weekPercent, resetsAt: nil)
            let limits = LimitsProviderSnapshot(provider: .claude, session: session, week: week)
            return ClaudeAccountLimits(id: UUID(), name: name, limits: limits, refreshedAt: Date())
        }
    }
}

private actor AccountLimitsCalls {
    private(set) var count = 0
    func record(_ id: UUID) { count += 1 }
}
