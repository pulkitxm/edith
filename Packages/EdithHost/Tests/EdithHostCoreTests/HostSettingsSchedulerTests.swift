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

    @Test(.timeLimit(.minutes(1)))
    func aBurstOfPreferenceChangesProducesOneBackupOfTheFinalPreferences() async {
        let state = State()
        let delay = ControlledDelay()
        let completed = Signal()
        let scheduler = state.scheduler(
            delay: { try await delay.wait($0) },
            run: {
                state.captured.append(state.signature)
                await completed.open()
                return true
            })
        scheduler.preferencesChanged()
        await delay.waitUntilStarted(1)
        state.signature = Data("second".utf8); scheduler.preferencesChanged()
        await delay.waitUntilStarted(2)
        state.signature = Data("final".utf8); scheduler.preferencesChanged()
        await delay.waitUntilStarted(3)
        await delay.waitUntilCancelled(2)
        #expect(state.captured.isEmpty)
        #expect(await delay.durations == Array(repeating: .seconds(2), count: 3))
        #expect(await delay.pendingCount == 1)
        await delay.release()
        await completed.wait()
        await scheduler.shutdown()
        #expect(state.captured == [Data("final".utf8)])
        #expect(await delay.pendingCount == 0)
    }

    @Test func shutdownCancelsAndDrainsTheOwnedBackupBeforeReturning() async {
        let state = State()
        let started = Signal()
        let scheduler = state.scheduler(run: {
            state.started = true
            await started.open()
            defer { state.drained = true }
            try await Task.sleep(for: .seconds(5))
            return true
        })
        let running = Task { await scheduler.runIfNeeded() }
        await started.wait()
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
        func scheduler(
            delay: @escaping @Sendable (Duration) async throws -> Void = {
                _ in try await Task.sleep(for: .milliseconds(10))
            },
            run: (@MainActor () async throws -> Bool)? = nil
        ) -> HostSettingsScheduler {
            HostSettingsScheduler(
                signature: { self.signature }, enabled: { self.enabled },
                onBattery: { self.battery }, now: { self.date },
                delay: delay,
                run: run ?? {
                    self.runs += 1; return true
                })
        }
    }

    private actor Signal {
        private var opened = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !opened { await withCheckedContinuation { waiters.append($0) } }
        }
        func open() {
            opened = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor ControlledDelay {
        private(set) var durations: [Duration] = []
        private var cancelled = 0
        private var pending: [UUID: CheckedContinuation<Void, Error>] = [:]
        private var observers: [CheckedContinuation<Void, Never>] = []
        var pendingCount: Int { pending.count }
        func wait(_ duration: Duration) async throws {
            let id = UUID()
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    pending[id] = continuation
                    durations.append(duration)
                    changed()
                }
            } onCancel: {
                Task { await self.cancel(id) }
            }
        }
        private func cancel(_ id: UUID) {
            guard let continuation = pending.removeValue(forKey: id) else { return }
            cancelled += 1
            continuation.resume(throwing: CancellationError())
            changed()
        }
        func release() {
            let waiting = pending.values
            pending.removeAll()
            for continuation in waiting { continuation.resume() }
            changed()
        }
        func waitUntilStarted(_ count: Int) async {
            while durations.count < count {
                await withCheckedContinuation { observers.append($0) }
            }
        }
        func waitUntilCancelled(_ count: Int) async {
            while cancelled < count {
                await withCheckedContinuation { observers.append($0) }
            }
        }
        private func changed() {
            let waiting = observers
            observers.removeAll()
            for continuation in waiting { continuation.resume() }
        }
    }

}
