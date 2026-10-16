import Foundation
import Testing

@testable import EdithKit

private actor AccountLimitsProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    func enter() { calls += 1; active += 1; maximumActive = max(maximumActive, active) }
    func leave() { active -= 1 }
}

private actor FetchedAccountNames {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}

@Suite struct ClaudeAccountLimitsTests {
    private let directory = URL(fileURLWithPath: "/synthetic/accounts")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ name: String = "Synthetic account") -> ClaudeAccount {
        .init(name: name, credential: "synthetic-token-" + name)
    }

    private func subscribedAccount(_ name: String = "Synthetic account") -> ClaudeAccount {
        .init(name: name, authentication: .browserLogin)
    }

    @Test func configuredAccountsReplaceAmbientClaudeAndDisabledClaudeDoesNotReadAccounts()
        async throws
    {
        let probe = AccountLimitsProbe()
        let configured = [subscribedAccount()]
        let snapshot = await LimitsCollector.collectConfigured(
            providers: [.claude, .codex], refreshSession: LimitsRefreshSession(), now: now,
            announce: { _ in }, accountDirectory: { directory }, loadAccounts: { _ in configured },
            fetchAccount: { _, _ in
                await probe.enter(); await probe.leave()
                return .init(
                    provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
            }
        ) { provider in
            #expect(provider == .codex)
            return (.init(provider: provider, session: nil, week: nil), nil)
        }
        #expect(snapshot.providers.map(\.provider) == [.codex])
        #expect(snapshot.claudeAccounts.first?.limits.session?.percent == 23)
        let disabled = await LimitsCollector.collectConfigured(
            providers: [], refreshSession: LimitsRefreshSession(), announce: { _ in },
            accountDirectory: {
                Issue.record("Disabled provider resolved accounts"); return directory
            },
            loadAccounts: { _ in
                Issue.record("Disabled provider read accounts"); return configured
            },
            fetchAccount: { _, _ in
                Issue.record("Disabled provider fetched credentials")
                return .init(provider: .claude, session: nil, week: nil)
            }
        ) { provider in
            Issue.record("Disabled provider ran collection")
            return (.init(provider: provider, session: nil, week: nil), nil)
        }
        #expect(disabled.claudeAccounts.isEmpty)
        #expect(await probe.calls == 1)
    }

    @Test func onlyAccountsWithConnectedSubscriptionsShowLimits() async throws {
        var linked = account("Linked token")
        linked.limitsProfileID = UUID()
        var loggedOut = subscribedAccount("Logged out login")
        loggedOut.isLoggedOut = true
        let configured = [
            account("Token only"), linked, subscribedAccount("Subscription login"),
            ClaudeAccount(name: "API key", authentication: .apiKey, credential: "synthetic-key"),
            loggedOut,
        ]
        let fetched = FetchedAccountNames()
        let snapshot = await LimitsCollector.collectConfigured(
            providers: [.claude], refreshSession: LimitsRefreshSession(), now: now,
            announce: { _ in }, accountDirectory: { directory }, loadAccounts: { _ in configured },
            fetchAccount: { account, _ in
                await fetched.append(account.name)
                return .init(
                    provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
            }
        ) { provider in
            Issue.record("Configured accounts read ambient \(provider) limits")
            return (.init(provider: provider, session: nil, week: nil), nil)
        }
        #expect(snapshot.providers.isEmpty)
        #expect(
            snapshot.claudeAccounts.map(\.name).sorted() == ["Linked token", "Subscription login"])
        #expect(await fetched.names.sorted() == ["Linked token", "Subscription login"])

        let unsubscribed = await LimitsCollector.collectConfigured(
            providers: [.claude], refreshSession: LimitsRefreshSession(), now: now,
            announce: { _ in }, accountDirectory: { directory },
            loadAccounts: { _ in [account("Token only")] },
            fetchAccount: { _, _ in
                Issue.record("Unsubscribed account fetched limits")
                return .init(provider: .claude, session: nil, week: nil)
            }
        ) { provider in
            Issue.record("Configured accounts read ambient \(provider) limits")
            return (.init(provider: provider, session: nil, week: nil), nil)
        }
        #expect(unsubscribed.providers.isEmpty)
        #expect(unsubscribed.claudeAccounts.isEmpty)
    }

    @Test func explicitCancellationErrorsNeverBecomeCachedAccountFailures() async throws {
        let collector = ClaudeAccountLimitsCollector()
        let configured = (0..<8).map { account("Synthetic \($0)") }
        let probe = AccountLimitsProbe()
        await #expect(throws: CancellationError.self) {
            try await collector.refresh(accounts: configured, directory: directory, now: now) {
                _, _ in
                await probe.enter(); await probe.leave()
                throw CancellationError()
            }
        }
        #expect(await probe.calls <= 3)
        let recovered = try await collector.refresh(
            accounts: configured, directory: directory, now: now
        ) { _, _ in .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        #expect(recovered.count == 8)
        #expect(recovered.allSatisfy { $0.limits.error == nil })
    }

    @Test func cancellingAFollowerLeavesTheOwnerAndClearJoinsItsChildren() async throws {
        let collector = ClaudeAccountLimitsCollector()
        let configured = (0..<8).map { account("Synthetic \($0)") }
        let probe = AccountLimitsProbe()
        let owner = Task {
            try await collector.refresh(accounts: configured, directory: directory) { _, _ in
                await probe.enter()
                do { try await Task.sleep(for: .seconds(60)) } catch {
                    await probe.leave(); throw error
                }
                await probe.leave()
                return .init(provider: .claude, session: nil, week: nil)
            }
        }
        try await waitUntil { await probe.active == 3 }
        let follower = Task {
            try await collector.refresh(accounts: configured, directory: directory) { _, _ in
                Issue.record("Follower started another collection")
                return .init(provider: .claude, session: nil, week: nil)
            }
        }
        try await waitUntil { await collector.followerCount == 1 }
        follower.cancel()
        await #expect(throws: CancellationError.self) { try await follower.value }
        #expect(await probe.active == 3)
        #expect(await collector.followerCount == 0)
        await collector.clear()
        await #expect(throws: CancellationError.self) { try await owner.value }
        #expect(await probe.active == 0)
        #expect(await probe.calls == 3)
        #expect(await probe.maximumActive == 3)
    }

    @Test func cacheExpiresAndCredentialEditsInvalidateOnlyTheirAccount() async throws {
        let collector = ClaudeAccountLimitsCollector()
        var configured = [account("First"), account("Second")]
        let probe = AccountLimitsProbe()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = { _, _ in
            await probe.enter(); await probe.leave()
            return .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        _ = try await collector.refresh(
            accounts: configured, directory: directory, now: now, fetch: fetch)
        configured[0].name = "Renamed"
        let renamed = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(1), fetch: fetch
        )
        #expect(renamed[0].name == "Renamed")
        #expect(await probe.calls == 2)
        configured[0].credential = "synthetic-replacement"
        _ = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(2), fetch: fetch
        )
        #expect(await probe.calls == 3)
        _ = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(63),
            fetch: fetch)
        #expect(await probe.calls == 5)
    }

    @Test func quotaEncodingDoesNotContainAuthenticationOrUnexpectedErrorData() async throws {
        let configured = [account()]
        let collector = ClaudeAccountLimitsCollector()
        let values = try await collector.refresh(accounts: configured, directory: directory) {
            _, _ in
            throw NSError(
                domain: "synthetic-token", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "synthetic-token"])
        }
        let text = String(decoding: try JSONEncoder().encode(values), as: UTF8.self)
        #expect(!text.contains("synthetic-token"))
        #expect(!text.contains("credential"))
        #expect(!text.contains("loginData"))
        #expect(!text.contains("remoteMachineID"))
    }

    @Test func apiKeysDoNotFallBackToAnotherAccountLogin() {
        let value = ClaudeAccount(
            name: "Synthetic API", authentication: .apiKey, credential: "synthetic-key")
        #expect(throws: ClaudeAccountError.self) {
            try ClaudeLimitsReader.accountToken(value, directory: directory) { _, _ in
                Issue.record("API-key account read another login"); return "synthetic-token"
            }
        }
    }

    @Test func changedAssociationInvalidatesCachedQuotaAndLogoutReadsNoCredentials() async throws {
        let collector = ClaudeAccountLimitsCollector()
        var value = account()
        let probe = AccountLimitsProbe()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = { _, _ in
            await probe.enter(); await probe.leave()
            return .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        _ = try await collector.refresh(
            accounts: [value], directory: directory, now: now, fetch: fetch)
        value.remoteMachineID = UUID().uuidString
        _ = try await collector.refresh(
            accounts: [value], directory: directory, now: now, fetch: fetch)
        #expect(await probe.calls == 2)
        value.isLoggedOut = true
        let loggedOut = try await collector.refresh(
            accounts: [value], directory: directory, now: now, fetch: fetch)
        #expect(loggedOut.first?.limits.session == nil)
        #expect(loggedOut.first?.limits.error != nil)
        #expect(await probe.calls == 2)
    }

    @Test func pausedAmbientProvidersRetainNamedAccountQuotaAndItsIndependentCache() async throws {
        let session = LimitsRefreshSession()
        let configured = [subscribedAccount()]
        let named = AccountLimitsProbe()
        let ambient = AccountLimitsProbe()
        let fetchAccount: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = {
            _, _ in
            await named.enter(); await named.leave()
            return .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        for offset in [0.0, 1.0] {
            let snapshot = await LimitsCollector.collectConfigured(
                providers: [.claude, .codex], refreshSession: session,
                now: now.addingTimeInterval(offset), announce: { _ in },
                accountDirectory: { directory }, loadAccounts: { _ in configured },
                fetchAccount: fetchAccount
            ) { provider in
                #expect(provider == .codex)
                await ambient.enter(); await ambient.leave()
                return (
                    .init(provider: provider, session: nil, week: nil, error: "Rate limited"),
                    now.addingTimeInterval(60)
                )
            }
            #expect(snapshot.claudeAccounts.first?.limits.session?.percent == 23)
        }
        #expect(await named.calls == 1)
        #expect(await ambient.calls == 1)
    }

    @Test(arguments: [ClaudeAccount.Authentication.oauthToken, .apiKey])
    func duplicateCredentialsShareRetryAfterAcrossRenameAndRemoval(
        authentication: ClaudeAccount.Authentication
    ) async throws {
        let collector = ClaudeAccountLimitsCollector()
        var first = account("Company")
        var duplicate = account("Imported CLI")
        first.authentication = authentication
        duplicate.authentication = authentication
        duplicate.credential = first.credential
        let probe = AccountLimitsProbe()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = { _, _ in
            await probe.enter(); await probe.leave()
            throw ClaudeLimitsReader.Failure.rateLimited(300)
        }
        let original = try await collector.refresh(
            accounts: [first, duplicate], directory: directory, now: now, fetch: fetch)
        #expect(original.map(\.id) == [first.id, duplicate.id])
        #expect(original.allSatisfy { $0.limits.error != nil })
        #expect(await probe.calls == 1)
        first.name = "Renamed company"
        let renamed = try await collector.refresh(
            accounts: [first, duplicate], directory: directory,
            now: now.addingTimeInterval(61), fetch: fetch)
        #expect(renamed.map(\.name) == [first.name, duplicate.name])
        #expect(await probe.calls == 1)
        let retained = try await collector.refresh(
            accounts: [duplicate], directory: directory,
            now: now.addingTimeInterval(62), fetch: fetch)
        #expect(retained.map(\.id) == [duplicate.id])
        #expect(await probe.calls == 1)
        _ = try await collector.refresh(
            accounts: [duplicate], directory: directory,
            now: now.addingTimeInterval(301), fetch: fetch)
        #expect(await probe.calls == 2)
        duplicate.credential = "synthetic-replaced-token"
        _ = try await collector.refresh(
            accounts: [duplicate], directory: directory,
            now: now.addingTimeInterval(302), fetch: fetch)
        #expect(await probe.calls == 3)
    }

    @Test func browserProfilesAndAssociatedMachinesNeverShareCredentialCache() async throws {
        let collector = ClaudeAccountLimitsCollector()
        var browser = account("First browser")
        browser.authentication = .browserLogin
        var secondBrowser = browser
        secondBrowser.id = UUID()
        secondBrowser.name = "Second browser"
        var local = account("Local OAuth")
        local.credential = browser.credential
        var remote = local
        remote.id = UUID()
        remote.name = "Remote OAuth"
        remote.remoteMachineID = UUID().uuidString
        var revoked = local
        revoked.id = UUID()
        revoked.name = "Revoked OAuth"
        revoked.isLoggedOut = true
        let probe = AccountLimitsProbe()
        let values = try await collector.refresh(
            accounts: [browser, secondBrowser, local, remote, revoked],
            directory: directory, now: now
        ) { account, _ in
            #expect(!account.isLoggedOut)
            await probe.enter(); await probe.leave()
            return .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        #expect(await probe.calls == 4)
        #expect(values.count == 5)
        #expect(values.last?.limits.session == nil)
        #expect(values.last?.limits.error != nil)
    }

    @Test func failedQuotaRefreshRetainsAllWindowsAndHonorsExactRetryDeadline() async throws {
        let collector = ClaudeAccountLimitsCollector()
        let configured = [account()]
        let original = LimitsProviderSnapshot(
            provider: .claude, session: .init(percent: 23, resetsAt: now.addingTimeInterval(600)),
            week: .init(percent: 41, resetsAt: now.addingTimeInterval(3600)),
            fable: .init(percent: 17, resetsAt: now.addingTimeInterval(3600)))
        _ = try await collector.refresh(accounts: configured, directory: directory, now: now) {
            _, _ in original
        }
        let failed = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(60)
        ) { _, _ in throw ClaudeLimitsReader.Failure.rateLimited(300) }
        let stale = try #require(failed.first)
        #expect(stale.limits.session == original.session)
        #expect(stale.limits.week == original.week)
        #expect(stale.limits.fable == original.fable)
        #expect(
            stale.limits.error == ClaudeLimitsReader.Failure.rateLimited(300).localizedDescription)
        #expect(stale.refreshedAt == now)
        #expect(stale.retryAt == now.addingTimeInterval(360))
        let probe = AccountLimitsProbe()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = { _, _ in
            await probe.enter(); await probe.leave()
            return .init(provider: .claude, session: .init(percent: 7, resetsAt: nil), week: nil)
        }
        let held = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(359),
            fetch: fetch)
        #expect(held == failed)
        #expect(await probe.calls == 0)
        let recovered = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(360),
            fetch: fetch)
        #expect(await probe.calls == 1)
        #expect(recovered.first?.limits.session?.percent == 7)
        #expect(recovered.first?.limits.error == nil)
        #expect(recovered.first?.retryAt == nil)
        #expect(recovered.first?.refreshedAt == now.addingTimeInterval(360))
        let defaultRetry = try await collector.refresh(
            accounts: configured, directory: directory, now: now.addingTimeInterval(420)
        ) { _, _ in throw ClaudeLimitsReader.Failure.rateLimited(nil) }
        #expect(defaultRetry.first?.retryAt == now.addingTimeInterval(2220))
        #expect(defaultRetry.first?.refreshedAt == now.addingTimeInterval(360))
        #expect(defaultRetry.first?.limits.session == recovered.first?.limits.session)
    }

    @Test func linkedProfilesAndDirectoryChangesCannotReuseAnotherCredentialScopeQuota()
        async throws
    {
        let collector = ClaudeAccountLimitsCollector()
        var first = account("First linked")
        first.limitsProfileID = UUID()
        var second = first
        second.id = UUID()
        second.limitsProfileID = UUID()
        let probe = AccountLimitsProbe()
        let fetch: @Sendable (ClaudeAccount, URL) async throws -> LimitsProviderSnapshot = { _, _ in
            await probe.enter(); await probe.leave()
            return .init(provider: .claude, session: .init(percent: 23, resetsAt: nil), week: nil)
        }
        _ = try await collector.refresh(
            accounts: [first, second], directory: directory, now: now, fetch: fetch)
        #expect(await probe.calls == 2)
        first.name = "Renamed linked"
        _ = try await collector.refresh(
            accounts: [first, second], directory: directory, now: now.addingTimeInterval(1),
            fetch: fetch)
        #expect(await probe.calls == 2)
        first.limitsProfileID = UUID()
        _ = try await collector.refresh(
            accounts: [first, second], directory: directory, now: now.addingTimeInterval(2),
            fetch: fetch)
        #expect(await probe.calls == 3)
        _ = try await collector.refresh(
            accounts: [first, second], directory: directory.appendingPathComponent("other"),
            now: now.addingTimeInterval(3), fetch: fetch)
        #expect(await probe.calls == 5)
        var browser = account("Scoped browser")
        browser.authentication = .browserLogin
        _ = try await collector.refresh(
            accounts: [browser], directory: directory, now: now.addingTimeInterval(4), fetch: fetch)
        #expect(await probe.calls == 6)
        _ = try await collector.refresh(
            accounts: [browser], directory: directory.appendingPathComponent("other"),
            now: now.addingTimeInterval(5), fetch: fetch)
        #expect(await probe.calls == 7)
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
