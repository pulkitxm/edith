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

    @Test func historyCompletionCannotStartPollingWhilePaused() {
        #expect(UsageStore.pollingAllowed(locked: false, sleeping: false))
        #expect(!UsageStore.pollingAllowed(locked: true, sleeping: false))
        #expect(!UsageStore.pollingAllowed(locked: false, sleeping: true))
        #expect(!UsageStore.pollingAllowed(locked: true, sleeping: true))
    }

    @MainActor
    @Test func credentialLookupFailuresStayActionableAndSecretSafe() {
        let missing = UsageStore.credentialLookupFailurePresentation(for: .missing)
        let rejected = UsageStore.credentialLookupFailurePresentation(for: .rejected)
        let malformed = UsageStore.credentialLookupFailurePresentation(for: .malformed)
        let oversized = UsageStore.credentialLookupFailurePresentation(for: .oversized)

        #expect(missing.message == "Claude Code token not found")
        #expect(!missing.schedulesQuickRetry)
        #expect(rejected.message.contains("re-login"))
        #expect(rejected.notifiesExpiredSession)
        #expect(malformed.message.contains("invalid"))
        #expect(oversized.message.contains("too large"))
        #expect(!malformed.schedulesQuickRetry)
        #expect(!oversized.schedulesQuickRetry)
        for presentation in [missing, rejected, malformed, oversized] {
            #expect(!presentation.message.contains("token-value"))
            #expect(!presentation.diagnostic.contains("token-value"))
        }
    }

    @MainActor
    @Test func transientCredentialLookupFailuresScheduleBoundedRetry() {
        let timedOut = UsageStore.credentialLookupFailurePresentation(for: .timedOut)
        let failed = UsageStore.credentialLookupFailurePresentation(for: .failed)

        #expect(timedOut.schedulesQuickRetry)
        #expect(failed.schedulesQuickRetry)
        #expect(!timedOut.notifiesExpiredSession)
        #expect(!failed.notifiesExpiredSession)
    }

    @Test func historyWritesWaitForSeedAndFlushOncePerProvider() {
        var gate = HistoryWriteGate()
        let firstClaude = gate.record(.claude)
        let codex = gate.record(.codex)
        let secondClaude = gate.record(.claude)
        let pending = gate.finish()
        let readyClaude = gate.record(.claude)
        let drained = gate.finish()
        #expect(!firstClaude)
        #expect(!codex)
        #expect(!secondClaude)
        #expect(pending == [.codex, .claude])
        #expect(readyClaude)
        #expect(drained.isEmpty)
    }
}
