import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostSettingsSchedulerTests {
    @Test func unchangedPreferencesDoNotWriteAgainUntilTheDailyBackupIsDue() async {
        let state = State()
        let scheduler = state.scheduler()
        await scheduler.runIfNeeded()
        await scheduler.runIfNeeded()
        #expect(state.runs == 1)
        state.date.addTimeInterval(86399)
        await scheduler.runIfNeeded()
        #expect(state.runs == 1)
        state.date.addTimeInterval(1)
        await scheduler.runIfNeeded()
        #expect(state.runs == 2)
        state.signature = Data("edited".utf8)
        await scheduler.runIfNeeded()
        #expect(state.runs == 3)
        await scheduler.shutdown()
    }

    @Test func failedAndIncompleteBackupsRetryWithoutMarkingTheSettingsAsSaved() async {
        let state = State()
        let scheduler = state.scheduler(run: {
            state.runs += 1
            if state.runs == 1 { throw CocoaError(.fileWriteNoPermission) }
            return state.runs > 2
        })
        await scheduler.runIfNeeded()
        await scheduler.runIfNeeded()
        await scheduler.runIfNeeded()
        await scheduler.runIfNeeded()
        #expect(state.runs == 3)
        await scheduler.shutdown()
    }

    @Test func disabledAndBatteryPausedBackupsResumeOnlyWhenAllowed() async {
        let state = State()
        state.enabled = false
        let scheduler = state.scheduler()
        await scheduler.runIfNeeded()
        state.enabled = true; state.battery = true
        await scheduler.runIfNeeded()
        #expect(state.runs == 0)
        state.battery = false
        await scheduler.runIfNeeded()
        #expect(state.runs == 1)
        await scheduler.shutdown()
        await scheduler.runIfNeeded()
        scheduler.start(); scheduler.preferencesChanged()
        #expect(state.runs == 1)
    }

    @Test func aBurstOfPreferenceChangesProducesOneBackupOfTheFinalPreferences() async {
        let state = State()
        let scheduler = state.scheduler(run: {
            state.captured.append(state.signature); return true
        })
        scheduler.preferencesChanged()
        state.signature = Data("second".utf8); scheduler.preferencesChanged()
        state.signature = Data("final".utf8); scheduler.preferencesChanged()
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while state.captured.isEmpty, ContinuousClock.now < deadline { await Task.yield() }
        #expect(state.captured == [Data("final".utf8)])
        await scheduler.shutdown()
    }

    @Test func shutdownCancelsAndDrainsTheOwnedBackupBeforeReturning() async {
        let state = State()
        let scheduler = state.scheduler(run: {
            state.started = true
            defer { state.drained = true }
            try await Task.sleep(for: .seconds(5))
            return true
        })
        let running = Task { await scheduler.runIfNeeded() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !state.started, ContinuousClock.now < deadline { await Task.yield() }
        #expect(state.started && !state.drained)
        await scheduler.shutdown()
        #expect(state.drained)
        await running.value
    }

    @MainActor private final class State {
        var signature = Data("first".utf8)
        var date = Date(timeIntervalSince1970: 1_000_000)
        var runs = 0
        var enabled = true
        var battery = false
        var captured: [Data] = []
        var started = false
        var drained = false
        func scheduler(run: (@MainActor () async throws -> Bool)? = nil) -> HostSettingsScheduler {
            HostSettingsScheduler(
                signature: { self.signature }, enabled: { self.enabled },
                onBattery: { self.battery }, now: { self.date },
                delay: { _ in try await Task.sleep(for: .milliseconds(10)) },
                run: run ?? {
                    self.runs += 1; return true
                })
        }
    }
}
