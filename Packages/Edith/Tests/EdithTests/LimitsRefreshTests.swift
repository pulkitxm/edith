import EdithKit
import Foundation
import Testing

@testable import EdithHelper

@Suite struct LimitsRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func refreshesEveryEnabledProviderRegardlessOfSelection() {
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: true) == [.claude, .codex])
        #expect(UsageStore.enabledLimitProviders(claude: true, codex: false) == [.claude])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: true) == [.codex])
        #expect(UsageStore.enabledLimitProviders(claude: false, codex: false).isEmpty)
    }

    @Test func startsWhenNothingIsInFlight() {
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: nil, now: now) == .start)
    }

    @Test func skipsWhileARefreshIsStillRunning() {
        let started = now.addingTimeInterval(-30)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: started, retryNotBefore: nil, now: now)
                == .skipInFlight)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: started, retryNotBefore: nil, now: now)
                == .skipInFlight)
    }

    @Test func recoversWhenAnInFlightRefreshNeverFinished() {
        let wedged = now.addingTimeInterval(-LimitsRefreshGate.stallTimeout)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: wedged, retryNotBefore: nil, now: now)
                == .recoverStalled)
    }

    @Test func recoveryStillHonoursBackoffUnlessForced() {
        let wedged = now.addingTimeInterval(-3600)
        let gate = now.addingTimeInterval(600)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: wedged, retryNotBefore: gate, now: now)
                == .skipBackoff)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: wedged, retryNotBefore: gate, now: now)
                == .recoverStalled)
    }

    @Test func backoffBlocksPollingUntilItExpires() {
        let gate = now.addingTimeInterval(600)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: gate, now: now) == .skipBackoff)
        #expect(
            LimitsRefreshGate.decide(
                force: true, inFlightSince: nil, retryNotBefore: gate, now: now) == .start)
        #expect(
            LimitsRefreshGate.decide(
                force: false, inFlightSince: nil, retryNotBefore: now.addingTimeInterval(-1),
                now: now) == .start)
    }

    @Test func backoffNeverParksThePollerForDays() {
        let week: TimeInterval = 7 * 24 * 3600
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: week, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.maximumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: 5, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.minimumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: nil, now: now)
                == now.addingTimeInterval(LimitsRefreshGate.maximumBackoff))
        #expect(
            LimitsRefreshGate.backoffDeadline(retryAfter: 300, now: now)
                == now.addingTimeInterval(300))
    }
}
