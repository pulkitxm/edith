import Foundation
import Testing

@testable import EdithHostCore

@MainActor @Suite struct HostWorkerPreparationTests {
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
}
