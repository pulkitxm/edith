import Foundation
import Testing

@testable import EdithHost

@MainActor
@Suite(.serialized)
struct HostUtilityActionsTests {
    @Test func pollingSleepsForTheFullIntervalInsteadOfTickingEveryHundredMilliseconds() {
        #expect(HostUtilityActions.pollInterval >= .seconds(2))
    }

    @Test func refreshTickWakesTheWaitImmediately() async throws {
        let actions = HostUtilityActions()
        let started = ContinuousClock.now
        let waiting = Task { await actions.waitForRefresh(after: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        actions.refreshTick += 1
        await waiting.value
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func cancellationEndsTheWaitImmediately() async throws {
        let actions = HostUtilityActions()
        let started = ContinuousClock.now
        let waiting = Task { await actions.waitForRefresh(after: .seconds(30)) }
        try await Task.sleep(for: .milliseconds(100))
        waiting.cancel()
        await waiting.value
        #expect(started.duration(to: .now) < .seconds(2))
    }

    @Test func theWaitEndsAfterTheInterval() async {
        let actions = HostUtilityActions()
        let started = ContinuousClock.now
        await actions.waitForRefresh(after: .milliseconds(150))
        #expect(started.duration(to: .now) >= .milliseconds(100))
        #expect(started.duration(to: .now) < .seconds(5))
    }
}
