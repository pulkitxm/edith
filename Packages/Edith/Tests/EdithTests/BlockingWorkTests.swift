import Foundation
import Testing

@testable import EdithKit

@Suite struct BlockingWorkTests {
    @Test func blockingWorkLeavesTheCooperativePoolFree() async {
        let width = ProcessInfo.processInfo.activeProcessorCount + 2
        let entered = Counter()
        let gates = (0..<width).map { _ in DispatchSemaphore(value: 0) }
        let tasks: [Task<Void, Never>] = gates.map { gate in
            Task {
                await BlockingWork.value {
                    entered.increment()
                    gate.wait()
                }
            }
        }
        let started = await waitUntil { entered.value == width }
        #expect(started)
        let began = ContinuousClock.now
        for _ in 0..<10 { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(began.duration(to: .now) < .seconds(2))
        for gate in gates { gate.signal() }
        for task in tasks { await task.value }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }

    var value: Int { lock.withLock { count } }
}

private func waitUntil(
    attempts: Int = 50, pause: Duration = .milliseconds(20),
    _ ready: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await ready() { return true }
        try? await Task.sleep(for: pause)
    }
    return false
}
