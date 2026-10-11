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
}
