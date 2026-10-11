import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostWorkerPreparationTests {
    @Test func synchronousReservationIsJoinedBeforeReplyTaskStarts() async throws {
        let preparation = HostWorkerPreparation()
        var waiter: CheckedContinuation<Void, Never>?
        let cleanup = try preparation.begin {
            await withCheckedContinuation { waiter = $0 }
        }
        #expect(preparation.isClosed)
        var joined = false
        let stop = Task {
            try await preparation.join(); joined = true
        }
        while waiter == nil { await Task.yield() }
        await Task.yield()
        #expect(!joined)
        waiter?.resume()
        try await stop.value
        try await cleanup.value.get()
        #expect(joined)
        #expect(preparation.isPrepared)
    }

    @Test func concurrentPreparationAndShutdownJoinSingleCleanup() async throws {
        let preparation = HostWorkerPreparation()
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let first = Task {
            try await preparation.prepare {
                calls += 1
                await withCheckedContinuation { continuation = $0 }
            }
        }
        while continuation == nil { await Task.yield() }
        let retry = Task { try await preparation.prepare { calls += 1 } }
        var joined = false
        let stop = Task {
            try await preparation.join(); joined = true
        }
        await Task.yield()
        #expect(preparation.isClosed)
        #expect(!preparation.isPrepared)
        #expect(!joined)
        #expect(calls == 1)
        first.cancel()
        continuation?.resume()
        try await first.value
        try await retry.value
        try await stop.value
        #expect(joined)
        #expect(preparation.isClosed)
        #expect(preparation.isPrepared)
        try await preparation.prepare { calls += 1 }
        #expect(calls == 1)
    }

    @Test func rejectedCleanupStaysClosedAndCanRetry() async throws {
        let preparation = HostWorkerPreparation()
        await #expect(throws: CocoaError.self) {
            try await preparation.prepare { throw CocoaError(.userCancelled) }
        }
        #expect(preparation.isClosed)
        #expect(!preparation.isPrepared)
        try await preparation.prepare {}
        #expect(preparation.isClosed)
        #expect(preparation.isPrepared)
    }
    @Test func lostAcknowledgementRetryUsesTheSameCleanupOutcome() async throws {
        let preparation = HostWorkerPreparation()
        let token = UUID()
        var calls = 0
        for _ in 0..<2 {
            await #expect(throws: CocoaError.self) {
                try await preparation.prepare(token: token) {
                    calls += 1
                    throw CocoaError(.userCancelled)
                }
            }
        }
        #expect(calls == 1)
        #expect(preparation.isClosed)
        try await preparation.prepare(token: UUID()) { calls += 1 }
        #expect(calls == 2)
        await #expect(throws: HostWorkerPreparation.Failure.self) {
            try await preparation.prepare(operation: "applicationQuit") { calls += 1 }
        }
        #expect(calls == 2)
    }

    @Test func failedQuitCanRestoreOnNewTokenOnlyAfterActualOwnerReturns() async throws {
        let preparation = HostWorkerPreparation()
        let quitToken = UUID()
        var waiter: CheckedContinuation<Void, Never>?
        var restored = false
        let quit = Task {
            try await preparation.prepare(token: quitToken, operation: "applicationQuit") {
                await withCheckedContinuation { waiter = $0 }
                throw CocoaError(.userCancelled)
            }
        }
        while waiter == nil { await Task.yield() }
        await #expect(throws: HostWorkerPreparation.Failure.self) {
            try await preparation.prepare(operation: "disable") { restored = true }
        }
        #expect(!restored)
        waiter?.resume()
        await #expect(throws: CocoaError.self) { try await quit.value }
        await #expect(throws: HostWorkerPreparation.Failure.self) {
            try await preparation.prepare(token: quitToken, operation: "disable") {
                restored = true
            }
        }
        #expect(!restored)
        try await preparation.prepare(operation: "disable") { restored = true }
        #expect(restored)
        #expect(preparation.isClosed)
        #expect(preparation.isPrepared)
        await #expect(throws: CocoaError.self) {
            try await preparation.prepare(token: quitToken, operation: "applicationQuit") {
                Issue.record("The acknowledged failed quit ran twice")
            }
        }
    }

    @Test func failedDisableCannotSwitchToQuitOrUnknownOperation() async throws {
        let preparation = HostWorkerPreparation()
        await #expect(throws: CocoaError.self) {
            try await preparation.prepare { throw CocoaError(.userCancelled) }
        }
        for operation in ["applicationQuit", "unknown"] {
            await #expect(throws: HostWorkerPreparation.Failure.self) {
                try await preparation.prepare(operation: operation) {
                    Issue.record("An unrelated cleanup operation was admitted")
                }
            }
        }
        #expect(preparation.isClosed)
        #expect(!preparation.isPrepared)
        try await preparation.prepare {}
        #expect(preparation.isPrepared)
    }

}
