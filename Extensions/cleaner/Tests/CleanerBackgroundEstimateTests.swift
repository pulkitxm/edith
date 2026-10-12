import EdithExtensionSupport
import Foundation
import Testing

@testable import CleanerExtension

@MainActor
@Suite(.serialized) struct CleanerBackgroundEstimateTests {
    @Test func unopenedEstimateUsesOwnedScannerAndNeverCleans() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        await model.estimateIfDue(onBattery: false)
        #expect(probe.calls == 1)
        #expect(model.latestEstimate?.reclaimableBytes == 32)
        #expect(model.latestEstimate?.categoryCount == 1)
        #expect(model.scanned)
        #expect(model.uiSnapshot().categories.map(\.id) == ["fixture-cache"])
        #expect(CleanerSurface.snapshot(model).metrics.first?.value == JunkScanner.format(32))
        #expect(CleanerSurface.snapshot(model).updatedAt == clock.now())
        #expect(model.lastReclaimed == 0)
        clock.advance(604_799)
        await model.estimateIfDue(onBattery: false)
        #expect(probe.calls == 1)
        clock.advance(1)
        await model.estimateIfDue(onBattery: false)
        #expect(probe.calls == 2)
        await model.shutdown()
    }

    @Test func restartLoadsBoundedEstimateAndSkipsNotDueScan() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let first = fixture.model(clock: clock, probe: probe)
        await first.estimateIfDue(onBattery: false)
        await first.shutdown()
        let second = fixture.model(clock: clock, probe: probe)
        await second.estimateIfDue(onBattery: false)
        #expect(probe.calls == 1)
        #expect(!second.scanned)
        #expect(second.latestEstimate?.scannedAt == clock.now())
        #expect(CleanerSurface.snapshot(second).metrics.count == 2)
        #expect(CleanerSurface.snapshot(second).metrics.first?.value == JunkScanner.format(32))
        #expect(fixture.defaults.data(forKey: CleanerModel.backgroundEstimateKey)!.count <= 1_024)
        await second.shutdown()
    }

    @Test func batteryPauseAndDisabledModelNeverScan() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        await model.estimateIfDue(onBattery: true)
        #expect(probe.calls == 0)
        await model.estimateIfDue(onBattery: false)
        #expect(probe.calls == 1)
        await model.shutdown()
        clock.advance(604_800)
        await model.estimateIfDue(onBattery: false)
        model.startBackgroundEstimates(onBattery: { false })
        #expect(probe.calls == 1)
    }

    @Test func explicitScanCoalescesWithBackgroundEstimate() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let gate = CleanerBackgroundGate()
        let model = fixture.model(clock: clock, probe: probe, gate: gate)
        let estimate = Task { await model.estimateIfDue(onBattery: false) }
        #expect(await wait { gate.started })
        model.scan()
        #expect(probe.calls == 1)
        gate.open()
        await estimate.value
        #expect(probe.calls == 1)
        #expect(model.scanned)
        await model.shutdown()
    }

    @Test func shutdownDrainsPollingAndInFlightScanWithoutPublishingLateEstimate() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let gate = CleanerBackgroundGate()
        let model = fixture.model(clock: clock, probe: probe, gate: gate)
        model.startBackgroundEstimates(onBattery: { false })
        #expect(await wait { gate.started })
        let shutdown = Task { await model.shutdown() }
        #expect(await wait { gate.cancelled })
        gate.open()
        await shutdown.value
        #expect(model.categories.isEmpty)
        #expect(model.latestEstimate == nil)
        #expect(!model.scanning)
        #expect(fixture.defaults.data(forKey: CleanerModel.backgroundEstimateKey) == nil)
        model.scan()
        model.startBackgroundEstimates(onBattery: { false })
        #expect(probe.calls == 1)
    }

    @Test func shutdownCancelsSleepingPollWithoutAnotherEstimate() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        let clock = CleanerBackgroundClock()
        let probe = CleanerBackgroundProbe()
        let delay = CleanerBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        model.startBackgroundEstimates(
            onBattery: { false },
            delay: { _ in
                delay.record()
                try await Task.sleep(for: .seconds(3_600))
            })
        #expect(await wait { delay.calls == 1 })
        await model.shutdown()
        #expect(probe.calls == 1)
        #expect(model.stopped)
    }

    @Test func malformedOrOversizedCachedEstimateCannotSuppressOwnedScan() async throws {
        let fixture = CleanerBackgroundFixture()
        defer { fixture.remove() }
        for data in [Data("not-json".utf8), Data(repeating: 32, count: 1_025)] {
            fixture.defaults.set(data, forKey: CleanerModel.backgroundEstimateKey)
            let probe = CleanerBackgroundProbe()
            let model = fixture.model(clock: CleanerBackgroundClock(), probe: probe)
            #expect(model.latestEstimate == nil)
            await model.estimateIfDue(onBattery: false)
            #expect(probe.calls == 1)
            #expect(model.latestEstimate?.reclaimableBytes == 32)
            await model.shutdown()
        }
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private final class CleanerBackgroundClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class CleanerBackgroundProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private final class CleanerBackgroundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var cancellation: CleanerCancellation?
    private var opened = false
    var started: Bool { lock.withLock { cancellation != nil } }
    var cancelled: Bool { lock.withLock { cancellation?.isCancelled == true } }
    func wait(_ cancellation: CleanerCancellation) async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                self.cancellation = cancellation
                if opened { return true }
                self.continuation = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }
    func open() {
        let waiting = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

@MainActor private struct CleanerBackgroundFixture {
    let suite = "cleaner-background-" + UUID().uuidString
    let defaults: UserDefaults
    init() { defaults = UserDefaults(suiteName: suite)! }
    func remove() { defaults.removePersistentDomain(forName: suite) }
    func model(
        clock: CleanerBackgroundClock, probe: CleanerBackgroundProbe,
        gate: CleanerBackgroundGate? = nil
    ) -> CleanerModel {
        CleanerModel(
            defaults: defaults,
            services: CleanerServices(
                drives: { [] },
                scan: { _, cancellation, _ in
                    probe.record()
                    await gate?.wait(cancellation)
                    return CleanerScanResult(categories: [
                        JunkCategory(
                            id: "fixture-cache", name: "Example cache", detail: "Synthetic cache",
                            items: [
                                JunkItem(
                                    id: "fixture-item", name: "Example item",
                                    path: URL(fileURLWithPath: "/synthetic/never-delete"),
                                    sizeBytes: 32, selected: false)
                            ])
                    ])
                },
                clean: { _, _ in
                    Issue.record("An automatic estimate must never clean.")
                    return CleanerCleanResult(items: 0, requestedBytes: 0, reclaimedBytes: 0)
                }), now: { clock.now() })
    }
}
