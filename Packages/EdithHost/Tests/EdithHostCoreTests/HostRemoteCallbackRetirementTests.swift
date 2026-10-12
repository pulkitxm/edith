import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostRemoteCallbackRetirementTests {
    @Test func queuedCallbackRetainsActualTailAcrossCloseAndRepeatedWait() async throws {
        let callbacks = HostRemoteCallbackRetirement()
        var held: CheckedContinuation<Void, Never>?
        var returned = false
        var firstJoined = false
        var secondJoined = false
        let actual = try #require(
            callbacks.schedule {
                await withCheckedContinuation { held = $0 }
                returned = true
            })
        callbacks.close()
        #expect(callbacks.schedule {} == nil)
        defer { held?.resume(); held = nil }
        let first = Task {
            await callbacks.closeAndWait(); firstJoined = true
        }
        let second = Task {
            await callbacks.closeAndWait(); secondJoined = true
        }
        let startDeadline = ContinuousClock.now + .seconds(2)
        while held == nil, ContinuousClock.now < startDeadline { await Task.yield() }
        try #require(held != nil)
        #expect(!returned)
        #expect(!firstJoined && !secondJoined)
        actual.cancel()
        for _ in 0..<100 { await Task.yield() }
        #expect(!returned)
        #expect(!firstJoined && !secondJoined)
        held?.resume()
        held = nil
        let deadline = ContinuousClock.now + .seconds(2)
        while (!firstJoined || !secondJoined), ContinuousClock.now < deadline { await Task.yield() }
        try #require(firstJoined && secondJoined)
        try #require(returned)
        await first.value
        await second.value
        await actual.value
    }

    @Test func joinCurrentWaitsForActualCallbackThenPermitsControlRetry() async throws {
        let callbacks = HostRemoteCallbackRetirement()
        var held: CheckedContinuation<Void, Never>?
        var returned = false
        var joined = false
        let actual = try #require(
            callbacks.schedule {
                await withCheckedContinuation { held = $0 }
                returned = true
            })
        defer { held?.resume() }
        let ready = ContinuousClock.now + .seconds(2)
        while held == nil, ContinuousClock.now < ready { await Task.yield() }
        try #require(held != nil)
        let drain = Task {
            await callbacks.joinCurrent(); joined = true
        }
        for _ in 0..<100 { await Task.yield() }
        #expect(!joined && !returned)
        held?.resume()
        held = nil
        let finished = ContinuousClock.now + .seconds(2)
        while !joined, ContinuousClock.now < finished { await Task.yield() }
        try #require(joined && returned)
        await actual.value
        await drain.value
        var retryReturned = false
        let retry = try #require(callbacks.schedule { retryReturned = true })
        await retry.value
        await callbacks.closeAndWait()
        #expect(retryReturned)
        #expect(callbacks.schedule {} == nil)
    }

    @Test func controlResumeRequiresActualClosedCallbackRetirement() async throws {
        let callbacks = HostRemoteCallbackRetirement()
        var gate: CheckedContinuation<Void, Never>?
        var joined = false
        let actual = try #require(
            callbacks.schedule {
                await withCheckedContinuation { gate = $0 }
            })
        defer { gate?.resume() }
        let ready = ContinuousClock.now + .seconds(2)
        while gate == nil, ContinuousClock.now < ready { await Task.yield() }
        try #require(gate != nil)
        callbacks.close()
        #expect(!callbacks.resume())
        let drain = Task {
            await callbacks.closeAndWait(); joined = true
        }
        gate?.resume()
        gate = nil
        let finished = ContinuousClock.now + .seconds(2)
        while !joined, ContinuousClock.now < finished { await Task.yield() }
        try #require(joined)
        await actual.value
        await drain.value
        #expect(callbacks.resume())
        var retried = false
        let retry = try #require(callbacks.schedule { retried = true })
        await retry.value
        await callbacks.closeAndWait()
        #expect(retried)
    }

}
