import Testing

@testable import WindowSweatersExtension

@Suite struct SweaterIdlePolicyTests {
    @Test func anIdleActiveReconcilerFallsBackToOneSecondBecauseEventsWakeItInstantly() {
        #expect(SweaterIdlePolicy.wait(active: true) == .seconds(1))
        #expect(SweaterIdlePolicy.wait(active: true) > .milliseconds(500))
    }

    @Test func aDisabledReconcilerSleepsLongerThanAnActiveOne() {
        #expect(SweaterIdlePolicy.wait(active: false) > SweaterIdlePolicy.wait(active: true))
    }
}
