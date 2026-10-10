import Foundation
import Testing

@testable import UsageExtension

@Suite @MainActor struct UsageBackupSchedulingTests {
    @Test func repeatedChangesDebounceAndTransfersNeverOverlap() async throws {
        var calls = 0
        var active = 0
        var maximum = 0
        let queue = UsageBackupEventQueue(debounce: .milliseconds(20), enabled: { true }) {
            calls += 1; active += 1; maximum = max(maximum, active)
            defer { active -= 1 }
            if calls == 1 { try await Task.sleep(for: .milliseconds(60)) }
        }
        for _ in 0..<20 { queue.changed() }
        await wait { calls == 1 }
        for _ in 0..<20 { queue.changed() }
        await wait { calls == 2 && !queue.scheduled }
        #expect(maximum == 1)
        await queue.shutdown()
        queue.changed()
        #expect(!queue.scheduled)
        #expect(calls == 2)
    }

    @Test func disablingAndShutdownCancelAndDrainTheOwnedTransfer() async {
        var enabled = true
        var calls = 0
        var active = false
        var cancelled = false
        let queue = UsageBackupEventQueue(debounce: .zero, enabled: { enabled }) {
            calls += 1; active = true
            defer { active = false }
            if calls == 1 {
                do { try await Task.sleep(for: .seconds(30)) } catch {
                    cancelled = true; throw error
                }
            }
        }
        queue.changed()
        await wait { active }
        enabled = false
        queue.changed()
        await queue.cancel()
        #expect(cancelled)
        #expect(!active)
        #expect(!queue.scheduled)
        enabled = true
        queue.changed()
        await wait { calls == 2 && !queue.scheduled }
        await queue.shutdown()
        #expect(calls == 2)
    }

    @Test func stopCancelsDebounceAndDoesNotRestartAfterReplacement() async {
        var oldCalls = 0, newCalls = 0
        let old = UsageBackupEventQueue(debounce: .seconds(30), enabled: { true }) { oldCalls += 1 }
        old.changed()
        await old.shutdown()
        old.changed()
        let replacement = UsageBackupEventQueue(debounce: .zero, enabled: { true }) {
            newCalls += 1
        }
        replacement.changed()
        await wait { newCalls == 1 && !replacement.scheduled }
        await replacement.shutdown()
        #expect(oldCalls == 0)
        #expect(newCalls == 1)
    }

    @Test func failedTransferRetriesWithoutParallelWork() async {
        var calls = 0
        let queue = UsageBackupEventQueue(
            debounce: .zero, retry: .milliseconds(20), enabled: { true }
        ) {
            calls += 1
            if calls == 1 { throw Failure() }
        }
        queue.changed()
        await wait { calls == 2 && !queue.scheduled }
        await queue.cancel()
        await queue.shutdown()
        #expect(calls == 2)
    }

    @Test func cancellingPendingRetryDrainsAndDiscardsTheRetry() async throws {
        var calls = 0
        let queue = UsageBackupEventQueue(debounce: .zero, retry: .seconds(30), enabled: { true }) {
            calls += 1
            throw Failure()
        }
        queue.changed()
        await wait { calls == 1 }
        #expect(queue.scheduled)
        await queue.cancel()
        #expect(!queue.scheduled)
        try await Task.sleep(for: .milliseconds(30))
        #expect(calls == 1)
        await queue.shutdown()
    }

    private struct Failure: Error {}
    private func wait(_ ready: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !ready(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(ready())
    }
}
