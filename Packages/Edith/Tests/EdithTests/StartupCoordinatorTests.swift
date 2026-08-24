import EdithKit
import Foundation
import Testing

private actor StartupGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waitingCount = 0

    func wait() async {
        waitingCount += 1
        await withCheckedContinuation { continuations.append($0) }
    }

    func waitUntilBlocked(_ count: Int) async {
        while waitingCount < count { await Task.yield() }
    }

    func releaseAll() {
        let blocked = continuations
        continuations.removeAll()
        blocked.forEach { $0.resume() }
    }
}

@MainActor
@Suite struct StartupCoordinatorTests {
    @Test func phasesWaitForTheCurrentLaunchTurn() async {
        let gate = StartupGate()
        let coordinator = StartupCoordinator(suspend: { await gate.wait() })
        var events: [String] = []

        coordinator.start([
            StartupPhase(name: "first") { events.append("first") },
            StartupPhase(name: "second") { events.append("second") },
        ])

        await gate.waitUntilBlocked(1)
        #expect(events.isEmpty)
        await gate.releaseAll()
        await gate.waitUntilBlocked(2)
        #expect(events == ["first"])
        await gate.releaseAll()
        await coordinator.waitForCurrent()
        #expect(events == ["first", "second"])
    }

    @Test func newestGenerationOwnsPublication() async {
        let gate = StartupGate()
        let coordinator = StartupCoordinator(suspend: { await gate.wait() })
        var events: [String] = []

        coordinator.start([StartupPhase(name: "stale") { events.append("stale") }])
        await gate.waitUntilBlocked(1)
        coordinator.start([StartupPhase(name: "current") { events.append("current") }])
        await gate.waitUntilBlocked(2)
        await gate.releaseAll()
        await coordinator.waitForCurrent()

        #expect(events == ["current"])
    }

    @Test func cancellationPreventsRemainingPhases() async {
        let gate = StartupGate()
        let coordinator = StartupCoordinator(suspend: { await gate.wait() })
        var events: [String] = []

        coordinator.start([
            StartupPhase(name: "first") { events.append("first") },
            StartupPhase(name: "second") { events.append("second") },
        ])
        await gate.waitUntilBlocked(1)
        await gate.releaseAll()
        await gate.waitUntilBlocked(2)
        coordinator.cancel()
        await gate.releaseAll()
        await coordinator.waitForCurrent()

        #expect(events == ["first"])
    }
}
