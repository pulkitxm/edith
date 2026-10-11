import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostRemoteInvocationRetirementTests {
    @Test func cancelledReplyCannotReleaseHeldActualRequestOwner() async throws {
        let ownership = HostRemoteInvocationRetirement()
        let token = UUID()
        var continuation: CheckedContinuation<Void, Never>?
        var actualReturned = false
        var joined = false
        var joinedSecond = false
        let actual = Task {
            await withCheckedContinuation { continuation = $0 }
            actualReturned = true
        }
        try #require(ownership.accepts(token))
        ownership.retain(actual, token: token)
        defer { continuation?.resume(); continuation = nil }
        let deadline = ContinuousClock.now + .seconds(2)
        while continuation == nil, ContinuousClock.now < deadline { await Task.yield() }
        try #require(continuation != nil)
        ownership.cancel(token)
        let retirement = Task {
            await ownership.closeAndWait(); joined = true
        }
        let second = Task {
            await ownership.closeAndWait(); joinedSecond = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!actualReturned)
        #expect(!joined && !joinedSecond)
        #expect(ownership.count == 1)
        #expect(!ownership.accepts(UUID()))
        continuation?.resume()
        continuation = nil
        let finishDeadline = ContinuousClock.now + .seconds(2)
        while (!joined || !joinedSecond), ContinuousClock.now < finishDeadline {
            await Task.yield()
        }
        try #require(joined && joinedSecond)
        try #require(actualReturned)
        await retirement.value
        await second.value
        #expect(ownership.count == 0)
    }

    @Test func completedActualOwnerReleasesCapacityWithoutClosingOrdinaryAdmission() async throws {
        let ownership = HostRemoteInvocationRetirement()
        let token = UUID()
        var returned = false
        let actual = Task { returned = true }
        ownership.retain(actual, token: token)
        let deadline = ContinuousClock.now + .seconds(2)
        while ownership.count != 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(ownership.count == 0)
        #expect(returned)
        #expect(ownership.accepts(token))
        await actual.value
    }

    @Test func stopExclusionStillJoinsActualOtherOwnerBeforeRetryAdmission() async throws {
        let ownership = HostRemoteInvocationRetirement()
        let stopToken = UUID()
        let otherToken = UUID()
        var stopContinuation: CheckedContinuation<Void, Never>?
        var otherContinuation: CheckedContinuation<Void, Never>?
        var otherReturned = false
        var joined = false
        let stop = Task { await withCheckedContinuation { stopContinuation = $0 } }
        let other = Task {
            await withCheckedContinuation { otherContinuation = $0 }
            otherReturned = true
        }
        ownership.retain(stop, token: stopToken)
        ownership.retain(other, token: otherToken)
        defer { stopContinuation?.resume(); otherContinuation?.resume() }
        let ready = ContinuousClock.now + .seconds(2)
        while (stopContinuation == nil || otherContinuation == nil), ContinuousClock.now < ready {
            await Task.yield()
        }
        try #require(stopContinuation != nil && otherContinuation != nil)
        let drain = Task {
            await ownership.cancelAndJoin(excluding: stopToken)
            joined = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!joined && !otherReturned)
        #expect(!stop.isCancelled)
        #expect(other.isCancelled)
        otherContinuation?.resume()
        otherContinuation = nil
        let finished = ContinuousClock.now + .seconds(2)
        while !joined, ContinuousClock.now < finished { await Task.yield() }
        try #require(joined && otherReturned)
        #expect(!stop.isCancelled)
        #expect(ownership.count == 1)
        #expect(ownership.accepts(otherToken))
        await drain.value
        stopContinuation?.resume()
        stopContinuation = nil
        await stop.value
        await other.value
        await ownership.closeAndWait()
        #expect(ownership.count == 0)
    }

}
