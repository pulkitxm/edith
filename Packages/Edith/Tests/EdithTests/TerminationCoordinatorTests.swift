import Foundation
import Testing

@testable import EdithHelper

@MainActor @Suite struct TerminationCoordinatorTests {
    @Test func safetyAndPersistenceStartConcurrently() async {
        let coordinator = TerminationCoordinator()
        var safetyStarted = false
        var persistenceStarted = false
        var safetyContinuation: CheckedContinuation<Void, Never>?
        var finishCount = 0

        coordinator.begin(
            timeout: .seconds(1),
            safety: {
                safetyStarted = true
                await withCheckedContinuation { safetyContinuation = $0 }
            },
            persistence: {
                persistenceStarted = true
            },
            finish: {
                finishCount += 1
            })

        await Task.yield()
        await Task.yield()
        #expect(safetyStarted)
        #expect(persistenceStarted)
        #expect(finishCount == 0)

        safetyContinuation?.resume()
        await waitUntil { finishCount == 1 }
        #expect(finishCount == 1)
    }

    @Test func timeoutFinishesWithoutWaitingForSafety() async {
        let coordinator = TerminationCoordinator()
        let clock = ContinuousClock()
        let started = clock.now
        var finishCount = 0
        var safetyContinuation: CheckedContinuation<Void, Never>?

        coordinator.begin(
            timeout: .milliseconds(20),
            safety: {
                await withCheckedContinuation { safetyContinuation = $0 }
            },
            persistence: {},
            finish: {
                finishCount += 1
            })

        await waitUntil { finishCount == 1 }
        #expect(finishCount == 1)
        #expect(started.duration(to: clock.now) < .seconds(1))
        safetyContinuation?.resume()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(finishCount == 1)
    }

    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}
