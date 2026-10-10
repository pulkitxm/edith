import Foundation
import Testing
@testable import HerdrUI

@MainActor @Suite(.serialized) struct HerdrDiscoveryAdmissionTests {
    @Test func noDemandWaitsWithoutTimersAndAuthenticatedDemandWakesAdmission() async {
        var interval: TimeInterval?
        let admission = HerdrDiscoveryAdmission(interval: { interval })
        var admitted = false
        let waiting = Task { admitted = await admission.admit("local") }
        #expect(await waitUntil { admission.pendingCount == 1 })
        #expect(!admitted && admission.timerCount == 0)
        interval = 2
        admission.refresh()
        await waiting.value
        #expect(admitted && admission.pendingCount == 0)
        admission.stop()
        #expect(await admission.admit("local") == false)
    }

    @Test func cadenceChangesRescheduleOnlyPendingAdmission() async {
        var instant = ContinuousClock.now
        var interval: TimeInterval? = 30
        let admission = HerdrDiscoveryAdmission(interval: { interval }, now: { instant })
        #expect(await admission.admit("snapshot"))
        instant += .seconds(2)
        var second = false
        let pending = Task { second = await admission.admit("snapshot") }
        #expect(await waitUntil { admission.pendingCount == 1 })
        #expect(!second)
        interval = 2
        admission.refresh()
        await pending.value
        #expect(second)
        interval = nil
        admission.refresh()
        let paused = Task { await admission.admit("snapshot") }
        #expect(await waitUntil { admission.pendingCount == 1 })
        instant += .seconds(90)
        admission.refresh()
        #expect(await waitUntil { admission.pendingCount == 1 })
        interval = 30
        admission.refresh()
        #expect(await paused.value)
        admission.stop()
    }

    @Test func cancellationAndDisableReleaseEverySleepingOwner() async {
        let admission = HerdrDiscoveryAdmission(interval: { nil })
        let tasks = (0..<32).map { index in Task { await admission.admit("host.\(index)") } }
        #expect(await waitUntil { admission.pendingCount == 32 })
        for task in tasks.prefix(16) { task.cancel() }
        for task in tasks.prefix(16) { #expect(await task.value == false) }
        #expect(admission.pendingCount == 16)
        admission.stop()
        for task in tasks.suffix(16) { #expect(await task.value == false) }
        #expect(admission.pendingCount == 0)
    }

    @Test func independentSessionCadencesDoNotThrottleEachOther() async {
        var instant = ContinuousClock.now
        let admission = HerdrDiscoveryAdmission(interval: { 2 }, now: { instant })
        #expect(await admission.admit("one"))
        #expect(await admission.admit("two"))
        let waiting = Task { await admission.admit("one") }
        #expect(await waitUntil { admission.pendingCount == 1 })
        instant += .seconds(2)
        admission.refresh()
        #expect(await waiting.value)
        admission.retire("one")
        #expect(await admission.admit("one"))
        admission.stop()
    }

    @Test func shutdownAwaitsCancelledTimerCompletion() async {
        let admission = HerdrDiscoveryAdmission(interval: { 30 })
        #expect(await admission.admit("snapshot"))
        let waiting = Task { await admission.admit("snapshot") }
        #expect(await waitUntil { admission.pendingCount == 1 && admission.timerCount == 1 })
        await admission.stopAndWait()
        #expect(await waiting.value == false)
        #expect(admission.pendingCount == 0 && admission.timerCount == 0)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        return condition()
    }
}
