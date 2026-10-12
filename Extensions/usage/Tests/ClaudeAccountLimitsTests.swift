import EdithExtensionAccounts
import Foundation
import Testing

@testable import UsageExtension

private actor AccountLimitsProbe {
    private(set) var calls = 0
    private(set) var active = 0
    private(set) var maximumActive = 0
    func enter() { calls += 1; active += 1; maximumActive = max(maximumActive, active) }
    func leave() { active -= 1 }
}

@Suite struct ClaudeAccountLimitsTests {
    private let directory = URL(fileURLWithPath: "/synthetic/accounts")
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func account(_ name: String = "Synthetic account") -> ClaudeAccount {
        .init(name: name, credential: "synthetic-token")
    }

    @Test func configuredAccountsReplaceAmbientClaudeAndDisabledClaudeDoesNotReadAccounts()
        async throws
    {
        let probe = AccountLimitsProbe()
        let configured = [account()]
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
        let configured = [account()]
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

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await predicate()) {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
