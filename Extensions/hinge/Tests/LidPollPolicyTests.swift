import Testing

@testable import HingeExtension

@Suite struct LidPollPolicyTests {
    @Test func theSensorIsNotPolledWhileHingeIsOffAndNothingIsTracking() {
        #expect(!LidPollPolicy.polls(tracking: false, idlePolling: false))
    }

    @Test func enabledHingeAndActiveTrackingKeepPolling() {
        #expect(LidPollPolicy.polls(tracking: false, idlePolling: true))
        #expect(LidPollPolicy.polls(tracking: true, idlePolling: false))
    }
}
