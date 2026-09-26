import Foundation
import Testing

@testable import EdithStudio

@Suite struct VisionQueueTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        var isSet: Bool { lock.withLock { value } }

        func set() { lock.withLock { value = true } }
    }

    @Test func cancelledWorkNeverRunsAndDoesNotWaitItsTurn() async throws {
        let busy = Task { try await StudioVision.run { Thread.sleep(forTimeInterval: 0.8) } }
        try await Task.sleep(for: .milliseconds(50))
        let ran = Flag()
        let waiting = Task { try await StudioVision.run { ran.set() } }
        try await Task.sleep(for: .milliseconds(50))
        let cancelledAt = Date()
        waiting.cancel()
        let outcome = await waiting.result
        #expect(Date().timeIntervalSince(cancelledAt) < 0.5)
        if case .success = outcome { Issue.record("cancelled work finished") }
        _ = try await busy.value
        try await Task.sleep(for: .milliseconds(50))
        #expect(!ran.isSet)
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private var peak = 0

        var highest: Int { lock.withLock { peak } }

        func enter() {
            lock.withLock {
                current += 1
                peak = max(peak, current)
            }
        }

        func leave() { lock.withLock { current -= 1 } }
    }

    @Test func workRunsOneAtATime() async throws {
        let counter = Counter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    try await StudioVision.run {
                        counter.enter()
                        Thread.sleep(forTimeInterval: 0.02)
                        counter.leave()
                    }
                }
            }
            try await group.waitForAll()
        }
        #expect(counter.highest == 1)
    }
}
