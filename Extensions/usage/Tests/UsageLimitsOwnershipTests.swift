import Foundation
import Testing

@testable import UsageExtension

@Suite struct UsageLimitsOwnershipTests {
    @Test func cancellingAFollowerDoesNotCancelTheOwner() async throws {
        let session = LimitsRefreshSession()
        guard case .collect(let owner) = await session.begin(force: false, providers: [.codex])
        else {
            Issue.record("Expected a collection owner")
            return
        }
        let follower = Task { await session.begin(force: false, providers: [.codex]) }
        try await waitForFollowers(1, session: session)
        follower.cancel()
        guard case .cancelled = await follower.value else {
            Issue.record("Cancelled follower retained its wait")
            return
        }
        #expect(await session.followerCount == 0)
        let remaining = Task { await session.begin(force: false, providers: [.codex]) }
        try await waitForFollowers(1, session: session)
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: Date(),
            providers: [
                LimitsProviderSnapshot(
                    provider: .codex, session: LimitWindow(percent: 25, resetsAt: nil), week: nil)
            ], failure: nil)
        await session.finish(snapshot, retryNotBefore: [:], lease: owner.id)
        guard case .cached(let received) = await remaining.value else {
            Issue.record("Owner did not complete its remaining follower")
            return
        }
        #expect(received == snapshot)
    }

    @Test func stoppingARefreshReleasesAllFollowersAndStartsFresh() async throws {
        let session = LimitsRefreshSession()
        _ = await session.begin(force: false, providers: [.cursor])
        let first = Task { await session.begin(force: false, providers: [.cursor]) }
        let second = Task { await session.begin(force: false, providers: [.cursor]) }
        try await waitForFollowers(2, session: session)
        await session.clear()
        for result in [await first.value, await second.value] {
            guard case .cancelled = result else {
                Issue.record("Shutdown left a waiting request")
                return
            }
        }
        #expect(await session.followerCount == 0)
        guard case .collect(let owner) = await session.begin(force: false, providers: [.cursor])
        else {
            Issue.record("New worker retained a stopped collection")
            return
        }
        #expect(owner.paused.isEmpty)
        await session.abort()
    }

    @Test func preCancelledCollectionDoesNotFetchOrPublish() async {
        let session = LimitsRefreshSession()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await LimitsCollector.collect(
                providers: [.cursor], refreshSession: session,
                announce: { _ in
                    Issue.record("Cancelled refresh published a completion")
                }
            ) { provider in
                Issue.record("Cancelled refresh started a provider")
                return (LimitsProviderSnapshot(provider: provider, session: nil, week: nil), nil)
            }
        }
        let result = await task.value
        #expect(result.providers.isEmpty)
        #expect(result.failure == "Cancelled")
        guard case .collect = await session.begin(force: false, providers: [.cursor]) else {
            Issue.record("Cancelled refresh retained ownership")
            return
        }
        await session.abort()
    }

    @Test func stoppedOwnerCannotPublishIntoANewCollection() async throws {
        let session = LimitsRefreshSession()
        guard case .collect(let older) = await session.begin(force: false, providers: [.codex])
        else {
            Issue.record("Expected older owner")
            return
        }
        await session.clear()
        guard case .collect(let newer) = await session.begin(force: false, providers: [.codex])
        else {
            Issue.record("Expected newer owner")
            return
        }
        let follower = Task { await session.begin(force: false, providers: [.codex]) }
        try await waitForFollowers(1, session: session)
        let snapshot = LimitsTopicSnapshot(refreshedAt: Date(), providers: [], failure: nil)
        #expect(await session.finish(snapshot, retryNotBefore: [:], lease: older.id) == false)
        #expect(await session.followerCount == 1)
        await session.abort(lease: older.id)
        #expect(await session.followerCount == 1)
        #expect(await session.finish(snapshot, retryNotBefore: [:], lease: newer.id))
        guard case .cached = await follower.value else {
            Issue.record("Newer owner did not publish")
            return
        }
    }

    private func waitForFollowers(_ count: Int, session: LimitsRefreshSession) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await session.followerCount != count {
            try #require(ContinuousClock.now < deadline)
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}
