import Foundation
import Testing
@testable import Edith

@Suite struct HelperLaunchTests {
    @Test @MainActor func relaunchWaitsForActualTermination() async throws {
        var checks = 0
        let ready = try await HelperTerminationWaiter.wait(interval: .milliseconds(1)) {
            checks += 1
            return checks == 3
        }
        #expect(ready)
        #expect(checks == 3)
    }

    @Test @MainActor func aStuckPreviousHelperCannotAuthorizeAnotherLaunch() async throws {
        let ready = try await HelperTerminationWaiter.wait(
            timeout: .milliseconds(20), interval: .milliseconds(2), isTerminated: { false })
        #expect(!ready)
    }

    @Test @MainActor func cancellationStopsTheOwnedRelaunchWait() async throws {
        var checks = 0
        let waiting = Task {
            try await HelperTerminationWaiter.wait(interval: .seconds(5)) {
                checks += 1
                return false
            }
        }
        defer { waiting.cancel() }
        let deadline = ContinuousClock.now + .seconds(2)
        while checks == 0, ContinuousClock.now < deadline { await Task.yield() }
        try #require(checks == 1)
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(checks == 1)
    }

    @Test @MainActor func cancellationPreventsEvenAnAlreadyReadyRelaunch() async throws {
        var checks = 0
        let waiting = Task {
            try await HelperTerminationWaiter.wait {
                checks += 1
                return true
            }
        }
        waiting.cancel()
        await #expect(throws: CancellationError.self) { try await waiting.value }
        #expect(checks == 0)
    }

    @Test func relaunchesHelperRunningFromAnotherAppCopy() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let running = URL(fileURLWithPath: "/tmp/Edith.app/Contents/Library/LoginItems/Edith.app")

        #expect(
            shouldRelaunchHelper(
                runningURL: running, expectedURL: expected,
                launchedAt: .now, installedAt: .now) == true)
    }

    @Test func keepsCurrentHelperWhenItIsNewEnough() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let installedAt = Date(timeIntervalSince1970: 100)

        #expect(
            shouldRelaunchHelper(
                runningURL: expected, expectedURL: expected,
                launchedAt: installedAt.addingTimeInterval(1), installedAt: installedAt) == false)
    }

    @Test func relaunchesCurrentHelperAfterReplacement() {
        let expected = URL(
            fileURLWithPath: "/Applications/Edith.app/Contents/Library/LoginItems/Edith.app")
        let installedAt = Date(timeIntervalSince1970: 100)

        #expect(
            shouldRelaunchHelper(
                runningURL: expected, expectedURL: expected,
                launchedAt: installedAt.addingTimeInterval(-1), installedAt: installedAt) == true)
    }
}
