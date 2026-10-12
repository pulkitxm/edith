import Foundation
import EdithExtensionSupport
import Testing

@testable import AppMaintenanceExtension

@MainActor
@Suite(.serialized) struct MaintenanceBackgroundDiscoveryTests {
    @Test func unopenedDiscoveryPersistsUpdatesAndRespectsSixHourCadence() async throws {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        let clock = MaintenanceBackgroundClock()
        let probe = MaintenanceBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        await model.discoverIfDue(onBattery: false)
        #expect(probe.calls == 1)
        #expect(model.updates.map(\.id) == ["fixture-update"])
        #expect(model.lastUpdateRefresh == clock.now())
        #expect(model.updateHistory.isEmpty)
        #expect(model.installPlan == nil)
        let stored = await fixture.snapshots.load()
        #expect(stored?.updates.map(\.id) == ["fixture-update"])
        let tile = SurfaceTile(.ability("appMaintenance"))
        #expect(AppMaintenanceSurface.snapshot(model, tile: tile).metrics.last?.value == "1")
        clock.advance(21_599)
        await model.discoverIfDue(onBattery: false)
        #expect(probe.calls == 1)
        clock.advance(1)
        await model.discoverIfDue(onBattery: false)
        #expect(probe.calls == 2)
        await model.shutdown()
    }

    @Test func restartUsesPersistedDiscoveryInsteadOfScanningAgain() async throws {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        let clock = MaintenanceBackgroundClock()
        let probe = MaintenanceBackgroundProbe()
        let first = fixture.model(clock: clock, probe: probe)
        await first.discoverIfDue(onBattery: false)
        await first.shutdown()
        let second = fixture.model(clock: clock, probe: probe)
        await second.discoverIfDue(onBattery: false)
        #expect(probe.calls == 1)
        #expect(second.updates.map(\.id) == ["fixture-update"])
        #expect(second.lastUpdateRefresh == clock.now())
        await second.shutdown()
    }

    @Test func batteryPausesDiscoveryAndPageRefreshPreferenceDoesNotDisableOriginalJob()
        async throws
    {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        fixture.defaults.set(false, forKey: MaintenancePreferences.updateAutoRefresh)
        let clock = MaintenanceBackgroundClock()
        let probe = MaintenanceBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        await model.discoverIfDue(onBattery: true)
        #expect(probe.calls == 0)
        await model.discoverIfDue(onBattery: false)
        #expect(probe.calls == 1)
        #expect(!model.preferences.autoRefresh)
        await model.shutdown()
        clock.advance(21_600)
        await model.discoverIfDue(onBattery: false)
        model.startBackgroundDiscovery(onBattery: { false })
        #expect(probe.calls == 1)
    }

    @Test func explicitRefreshCoalescesWithOwnedBackgroundDiscovery() async throws {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        let gate = MaintenanceBackgroundGate()
        let probe = MaintenanceBackgroundProbe()
        let clock = MaintenanceBackgroundClock()
        let model = fixture.model(clock: clock, probe: probe, gate: gate)
        let discovery = Task { await model.discoverIfDue(onBattery: false) }
        #expect(await wait { gate.started })
        model.refresh()
        #expect(probe.calls == 1)
        gate.open()
        await discovery.value
        #expect(probe.calls == 1)
        #expect(model.updates.count == 1)
        await model.shutdown()
    }

    @Test func shutdownCancelsOwnedPollingAndDoesNotRestart() async throws {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        let clock = MaintenanceBackgroundClock()
        let probe = MaintenanceBackgroundProbe()
        let delay = MaintenanceBackgroundProbe()
        let model = fixture.model(clock: clock, probe: probe)
        model.startBackgroundDiscovery(
            onBattery: { false },
            delay: { _ in
                delay.record()
                try await Task.sleep(for: .seconds(3_600))
            })
        #expect(await wait { delay.calls == 1 })
        #expect(probe.calls == 1)
        await model.shutdown()
        #expect(model.ownedOperationCount == 0)
        #expect(model.stopped)
        model.startBackgroundDiscovery(onBattery: { false })
        #expect(probe.calls == 1)
    }

    @Test func stoppingCancelsInFlightDiscoveryAndRejectsLateSnapshot() async throws {
        let fixture = try MaintenanceBackgroundFixture()
        defer { fixture.remove() }
        let clock = MaintenanceBackgroundClock()
        let probe = MaintenanceBackgroundProbe()
        let gate = MaintenanceBackgroundGate()
        let model = fixture.model(clock: clock, probe: probe, gate: gate)
        model.startBackgroundDiscovery(onBattery: { false })
        #expect(await wait { gate.started })
        let shutdown = Task { await model.shutdown() }
        #expect(await wait { model.stopped })
        gate.open()
        await shutdown.value
        #expect(model.ownedOperationCount == 0)
        #expect(model.updates.isEmpty)
        #expect(await fixture.snapshots.load() == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.persistence.fileURL.path))
    }

    private func wait(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
}

private final class MaintenanceBackgroundClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_800_000_000)
    func now() -> Date { lock.withLock { value } }
    func advance(_ interval: TimeInterval) { lock.withLock { value.addTimeInterval(interval) } }
}

private final class MaintenanceBackgroundProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func record() { lock.withLock { count += 1 } }
}

private final class MaintenanceBackgroundGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var didStart = false
    private var opened = false
    var started: Bool { lock.withLock { didStart } }
    func wait() async {
        await withCheckedContinuation { continuation in
            let ready = lock.withLock {
                didStart = true
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

@MainActor private struct MaintenanceBackgroundFixture {
    let root: URL
    let defaults: UserDefaults
    let suite: String
    var snapshots: AppMaintenanceSnapshotStore {
        AppMaintenanceSnapshotStore(fileURL: root.appendingPathComponent("snapshot.json"))
    }
    var persistence: AppUpdatePersistence {
        AppUpdatePersistence(fileURL: root.appendingPathComponent("state.json"))
    }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "maintenance-background-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
    }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    func model(
        clock: MaintenanceBackgroundClock, probe: MaintenanceBackgroundProbe,
        gate: MaintenanceBackgroundGate? = nil
    ) -> AppMaintenanceModel {
        AppMaintenanceModel(
            defaults: defaults, persistence: persistence, snapshots: snapshots,
            inventory: { _ in
                probe.record()
                await gate?.wait()
                return []
            }, now: { clock.now() },
            discover: { _, _, _, _ in
                [
                    AppUpdateItem(
                        id: "fixture-update", name: "Example", source: .sparkle,
                        currentVersion: "1", availableVersion: "2", confidence: .high,
                        checkedAt: clock.now(), action: .install,
                        executablePath: "/synthetic/never-execute", arguments: [])
                ]
            })
    }
}
