import EdithExtensionSupport
import Foundation
import Testing

@testable import ClipboardExtension

@MainActor
@Suite(.serialized) struct ClipboardBackupBatteryTests {
    @Test func automaticQueueRetainsNewestChangeUntilPowerReturns() async {
        var battery = true
        var newest = "first"
        var transferred: [String] = []
        let clock = ClipboardBackupBatterySleep()
        let queue = ClipboardBackupEventQueue(
            debounce: .zero, onBattery: { battery }, sleep: { try await clock.sleep($0) },
            enabled: { true }
        ) { transferred.append(newest) }
        queue.changed()
        await wait { await clock.count == 1 }
        #expect(queue.pausedOnBattery)
        newest = "second"
        queue.changed()
        newest = "latest"
        queue.changed()
        await clock.resumeFirst()
        await wait { await clock.count == 2 }
        #expect(transferred.isEmpty)
        #expect(queue.scheduled)
        #expect(await clock.durations == [.seconds(60), .seconds(60)])
        battery = false
        await clock.resumeFirst()
        await wait { !queue.scheduled }
        #expect(transferred == ["latest"])
        #expect(!queue.pausedOnBattery)
        await queue.shutdown()
        #expect(await clock.pending == 0)
    }

    @Test func cancellationDiscardsPausedWorkAndDrainsOwnedPoll() async {
        var battery = true
        var calls = 0
        let clock = ClipboardBackupBatterySleep()
        let queue = ClipboardBackupEventQueue(
            debounce: .zero, onBattery: { battery }, sleep: { try await clock.sleep($0) },
            enabled: { true }
        ) { calls += 1 }
        queue.changed()
        await wait { await clock.count == 1 }
        await queue.cancel()
        #expect(!queue.scheduled)
        #expect(!queue.pausedOnBattery)
        #expect(await clock.pending == 0)
        #expect(calls == 0)
        battery = false
        queue.changed()
        await wait { !queue.scheduled }
        #expect(calls == 1)
        await queue.shutdown()
    }

    @Test func disabledConsentAndShutdownPreventPausedWorkFromResuming() async {
        var enabled = true
        var battery = true
        var calls = 0
        let clock = ClipboardBackupBatterySleep()
        let queue = ClipboardBackupEventQueue(
            debounce: .zero, onBattery: { battery }, sleep: { try await clock.sleep($0) },
            enabled: { enabled }
        ) { calls += 1 }
        queue.changed()
        await wait { await clock.count == 1 }
        enabled = false
        queue.changed()
        await queue.cancel()
        #expect(await clock.pending == 0)
        battery = false
        queue.changed()
        #expect(calls == 0)
        #expect(!queue.scheduled)
        await queue.shutdown()
        enabled = true
        queue.changed()
        #expect(!queue.scheduled)
        #expect(calls == 0)
    }

    @Test func powerChangeDoesNotCancelStartedTransferButPausesItsNextChange() async {
        var battery = false
        var calls = 0
        var active = false
        let clock = ClipboardBackupBatterySleep()
        let queue = ClipboardBackupEventQueue(
            debounce: .zero, onBattery: { battery }, sleep: { try await clock.sleep($0) },
            enabled: { true }
        ) {
            calls += 1
            active = true
            defer { active = false }
            try await clock.sleep(.seconds(3_600))
        }
        queue.changed()
        await wait { await clock.count == 1 }
        #expect(active)
        battery = true
        queue.changed()
        #expect(active)
        await clock.resumeFirst()
        await wait { await clock.count == 2 }
        #expect(!active)
        #expect(calls == 1)
        #expect(queue.pausedOnBattery)
        await queue.shutdown()
        #expect(await clock.pending == 0)
        #expect(calls == 1)
    }

    @Test func ownedProviderResumesLatestSyntheticDataWithoutAnotherChange() async throws {
        let fixture = try ClipboardBackupBatteryFixture()
        defer { fixture.remove() }
        var battery = true
        let clock = ClipboardBackupBatterySleep()
        try fixture.write("first")
        let provider = fixture.provider(onBattery: { battery }, clock: clock)
        provider.startScheduling(debounce: .zero)
        await wait { await clock.count == 1 }
        let status = try await provider.execute("backup.status", payload: Data())
        let object = try JSONSerialization.jsonObject(with: status) as? [String: Any]
        #expect(object?["pausedOnBattery"] as? Bool == true)
        #expect(object?["scheduled"] as? Bool == true)
        #expect(!fixture.exportExists)
        try fixture.write("latest")
        provider.preferencesChanged()
        await clock.resumeFirst()
        await wait { await clock.count == 2 }
        #expect(!fixture.exportExists)
        battery = false
        await clock.resumeFirst()
        await wait { fixture.exportExists }
        await wait {
            guard let data = try? await provider.execute("backup.status", payload: Data()),
                let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return false }
            return value["scheduled"] as? Bool == false
        }
        try fixture.verifyLatest()
        await provider.shutdown()
        #expect(await clock.pending == 0)
    }

    @Test func explicitSyncStillWorksOnBatteryAndClearsPausedAutomaticWork() async throws {
        let fixture = try ClipboardBackupBatteryFixture()
        defer { fixture.remove() }
        let clock = ClipboardBackupBatterySleep()
        try fixture.write("latest")
        let provider = fixture.provider(onBattery: { true }, clock: clock)
        provider.startScheduling(debounce: .zero)
        await wait { await clock.count == 1 }
        #expect(!fixture.exportExists)
        _ = try await provider.execute("backup.synchronize", payload: Data())
        try fixture.verifyLatest()
        let status = try await provider.execute("backup.status", payload: Data())
        let object = try JSONSerialization.jsonObject(with: status) as? [String: Any]
        #expect(object?["pausedOnBattery"] as? Bool == false)
        #expect(object?["scheduled"] as? Bool == false)
        #expect(await clock.pending == 0)
        await provider.shutdown()
    }

    private func wait(_ ready: () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await ready()), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        #expect(await ready())
    }
}

private actor ClipboardBackupBatterySleep {
    private var waits: [(UUID, CheckedContinuation<Void, Error>)] = []
    private(set) var durations: [Duration] = []
    var count: Int { durations.count }
    var pending: Int { waits.count }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError()); return
                }
                durations.append(duration)
                waits.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    func resumeFirst() {
        guard !waits.isEmpty else { return }
        waits.removeFirst().1.resume()
    }
    private func cancel(_ id: UUID) {
        guard let index = waits.firstIndex(where: { $0.0 == id }) else { return }
        waits.remove(at: index).1.resume(throwing: CancellationError())
    }
}

@MainActor private struct ClipboardBackupBatteryFixture {
    let root: URL
    let defaults: UserDefaults
    let suite = "com.pulkit.edith.tests.backup-battery-" + UUID().uuidString
    var local: URL { root.appendingPathComponent("local") }
    var cloud: URL { root.appendingPathComponent("cloud") }
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("local"), withIntermediateDirectories: true)
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
        defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
    }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    var exportExists: Bool {
        FileManager.default.fileExists(atPath: cloud.appendingPathComponent("index.jsonl").path)
    }
    func write(_ value: String) throws {
        let capture = ClipboardCapture(
            payload: .init(
                data: Data(value.utf8),
                types: ["public.utf8-plain-text"], ext: "txt", preview: value),
            sourceApp: nil, sourceBundleID: nil,
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        _ = try ClipboardArchive(root: local).capture(
            capture, maxItems: 200, maxBytes: 1000, maxAge: nil)
    }
    func verifyLatest() throws {
        let entries = try ClipboardArchive(root: cloud).snapshot(.init()).entries
        #expect(entries.contains { $0.preview == "latest" })
    }
    func provider(onBattery: @escaping () -> Bool, clock: ClipboardBackupBatterySleep)
        -> ClipboardBackupProvider
    {
        ClipboardBackupProvider(
            archive: ClipboardArchive(root: local), cloud: cloud,
            applicationDefaults: defaults, defaults: defaults,
            onBattery: onBattery, sleep: { try await clock.sleep($0) })
    }
}
