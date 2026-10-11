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
}
