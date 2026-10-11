import Foundation
import Testing
@testable import NotchShelfExtension

@Suite @MainActor struct NotchSettingsDrainTests {
    @Test(arguments: [false, true])
    func stoppingJoinsOwnedReadAndWriteBeforeDiscardingLateResults(write: Bool) async throws {
        var suspended: CheckedContinuation<Void, Never>?
        var cancelled = false
        var starts = 0
        let model = NotchSettingsModel(invoke: { _, _ in
            starts += 1
            await withCheckedContinuation { suspended = $0 }
            cancelled = Task.isCancelled
            return try JSONEncoder().encode(NotchSettingsSnapshot.empty)
        })
        let caller = Task {
            if write { model.perform("notch.settings.write") }
            else { await model.refresh() }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while suspended == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try #require(suspended)
        var drained = false
        let shutdown = Task { await model.stopAndWait(); drained = true }
        while !model.stopped, ContinuousClock.now < deadline { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.stopped)
        #expect(!drained)
        continuation.resume()
        await shutdown.value
        await caller.value
        #expect(cancelled)
        #expect(model.snapshot == .empty)
        #expect(model.error == nil)
        await model.refresh()
        model.perform("notch.settings.write")
        #expect(starts == 1)
    }

    @Test func cancelledRefreshForwardsCancellationAndStillJoinsItsInvocation() async throws {
        var suspended: CheckedContinuation<Void, Never>?
        var cancelled = false
        let model = NotchSettingsModel(invoke: { _, _ in
            await withCheckedContinuation { suspended = $0 }
            cancelled = Task.isCancelled
            return try JSONEncoder().encode(NotchSettingsSnapshot.empty)
        })
        var finished = false
        let caller = Task { await model.refresh(); finished = true }
        let deadline = ContinuousClock.now + .seconds(5)
        while suspended == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try #require(suspended)
        caller.cancel()
        for _ in 0..<20 { await Task.yield() }
        #expect(!finished)
        continuation.resume()
        await caller.value
        #expect(cancelled)
        #expect(model.error == nil)
        await model.stopAndWait()
    }
}
