import EdithExtensionSupport_attention_native
import Foundation
import Testing

@testable import AttentionNative

@MainActor @Suite(.serialized)
struct AttentionAmbientPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func policyOnlySynchronizationDoesNotEnqueueExplicitIngestion() throws {
        var explicitCalls = 0
        let controller = AttentionExtensionController(
            bundle: .main, notifySettingsChanged: { explicitCalls += 1 }, admitFixture: { _ in nil }
        )
        let context: NSMutableDictionary = [
            "operation": "synchronize", "ambientPolicyOnly": true,
            "ambientPolicy": [
                "pauseAmbientOnBattery": true, "subscribers": ["attention.ingest": 0],
            ],
        ]
        #expect((controller.execute(context) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(explicitCalls == 0)
        context["ambientPolicyOnly"] = false
        #expect((controller.execute(context) as? NSDictionary)?["ok"] as? Bool == true)
        context.removeObject(forKey: "ambientPolicyOnly")
        #expect((controller.execute(context) as? NSDictionary)?["ok"] as? Bool == true)
        #expect(explicitCalls == 2)
        context["ambientPolicyOnly"] = "true"
        #expect((controller.execute(context) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(explicitCalls == 2)
    }

    @Test func pausedPeriodicIngestPreservesManualAndFilesystemAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        try fixture.append("first", at: now)
        try await fixture.service.runPeriodicMaintenance(now: now)
        #expect(try fixture.ids() == [])
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == nil)
        _ = try await fixture.service.run(now: now)
        #expect(try fixture.ids() == ["first"])
        try fixture.append("filesystem", at: now)
        _ = try await fixture.service.importSpool()
        #expect(try fixture.ids() == ["filesystem", "first"])
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func actualOwnedDemandUsesNineHundredSecondsAndReleaseRestoresPause() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.power.constrained = true
        try fixture.apply(paused: true, subscribers: 1)
        try fixture.append("first", at: now)
        try await fixture.service.runPeriodicMaintenance(now: now)
        #expect(try fixture.ids() == ["first"])
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == 900)
        try fixture.append("second", at: now.addingTimeInterval(1))
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(899))
        #expect(try fixture.ids() == ["first"])
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(900))
        #expect(try fixture.ids() == ["first", "second"])
        try fixture.apply(paused: true)
        try fixture.append("released", at: now.addingTimeInterval(2))
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(1800))
        #expect(try fixture.ids() == ["first", "second"])
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == nil)
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func defaultFalseAndOffBatteryResumeExistingIngestCadence() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.append("first", at: now)
        try await fixture.service.runPeriodicMaintenance(now: now)
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == 900)
        try fixture.apply(paused: true)
        try fixture.append("resumed", at: now.addingTimeInterval(1))
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(900))
        #expect(try fixture.ids() == ["first"])
        fixture.power.onBattery = false
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(900))
        #expect(try fixture.ids() == ["first", "resumed"])
        fixture.power.constrained = true
        #expect(
            await fixture.service.nextMaintenanceDelay(now: now.addingTimeInterval(900)) == 2700)
        await fixture.service.stop()
        await #expect(throws: CancellationError.self) {
            try await fixture.service.runPeriodicMaintenance(now: now)
        }
        try fixture.database.close()
    }

    @Test func policyReschedulesOwnedSleeperAndStopDrainsItWithoutStartingCollectors() async throws
    {
        let sleep = RecordedSleep()
        let fixture = try Fixture(sleep: { duration in try await sleep.wait(duration) })
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        try fixture.append("startup", at: now)
        await fixture.service.start()
        #expect(try fixture.ids() == [])
        #expect(await sleep.count == 0)
        try fixture.apply(paused: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while true {
            let imported = try fixture.ids()
            let active = await sleep.active
            if imported == ["startup"] && active > 0 { break }
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        let imported = try fixture.ids()
        #expect(imported == ["startup"])
        #expect(await sleep.duration == .seconds(900))
        #expect(try await fixture.service.runtimeStatus().browserListening == false)
        await fixture.service.stop()
        #expect(await sleep.cancelled)
        #expect(await sleep.active == 0)
        try fixture.database.close()
    }

    @Test func observerFailureIsTruthfulAndDoesNotRestrictExplicitWork() async throws {
        let fixture = try Fixture(observe: { _ in throw CocoaError(.featureUnsupported) })
        defer { fixture.remove() }
        try fixture.append("manual", at: now)
        await fixture.service.start()
        #expect(try await fixture.service.runtimeStatus().schedulingFailure != nil)
        #expect(try fixture.ids() == [])
        _ = try await fixture.service.run(now: now)
        #expect(try fixture.ids() == ["manual"])
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func explicitSettingsEventSurvivesCoalescingWhilePeriodicIngestIsPaused() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        await fixture.service.start()
        try fixture.append("settings", at: now)
        fixture.notifications.post(name: Notification.Name(IPC.Name.settingsChanged), object: nil)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while try fixture.ids() != ["settings"] {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == nil)
        await fixture.service.stop()
        try fixture.database.close()
    }

    @Test func existingBackupEligibilityRemainsIndependentOfAmbientIngestPause() async throws {
        let fixture = try Fixture(backupEnabled: true)
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        var settings = fixture.repository.loadSettings()
        settings.iCloudBackupEnabled = true
        settings.profileNote = "First fixture generation"
        try fixture.repository.saveSettings(settings)
        try await fixture.service.runPeriodicMaintenance(now: now)
        #expect(try await fixture.service.runtimeStatus().lastBackupAt == now)
        #expect(await fixture.service.nextMaintenanceDelay(now: now) == 900)
        let file = fixture.root.appendingPathComponent("cloud/settings.json")
        let first = try Data(contentsOf: file)
        settings.profileNote = "Second fixture generation"
        try fixture.repository.saveSettings(settings)
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(899))
        #expect(try Data(contentsOf: file) == first)
        try await fixture.service.runPeriodicMaintenance(now: now.addingTimeInterval(900))
        #expect(try Data(contentsOf: file) != first)
        #expect(try await fixture.service.runtimeStatus().browserListening == false)
        await fixture.service.stop()
        try fixture.database.close()
    }

    @MainActor private final class Power {
        var onBattery = true
        var constrained = false
    }

    @MainActor private struct Fixture {
        let root: URL
        let defaultsSuite: String
        let database: AttentionDatabase
        let repository: AttentionRepository
        let service: AttentionBackgroundService
        let policy: ExtensionAmbientPolicy
        let power: Power
        let notifications: NotificationCenter

        init(
            backupEnabled: Bool = false,
            sleep: @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            },
            observe: @escaping ExtensionAmbientPolicy.BatteryObservation = { _ in {} }
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defaultsSuite = "attention.ambient.tests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: defaultsSuite))
            database = try AttentionDatabase(url: root.appendingPathComponent("history.sqlite"))
            repository = AttentionRepository(root: root)
            power = Power()
            notifications = NotificationCenter()
            let power = power
            policy = ExtensionAmbientPolicy(
                jobs: ["attention.ingest": ExtensionAmbientCadence(ambient: 900, live: 900)],
                onBattery: { power.onBattery }, constrained: { power.constrained },
                notificationCenter: NotificationCenter(), observeBatteryChanges: observe)
            service = AttentionBackgroundService(
                store: database, root: root, cloudDirectory: root.appendingPathComponent("cloud"),
                defaults: defaults, cloudAvailable: { backupEnabled },
                collectsSystemActivity: backupEnabled,
                ambientPolicy: policy, notificationCenter: notifications,
                clock: { Date(timeIntervalSince1970: 1_800_000_000) }, sleep: sleep,
                decider: { nil })
        }

        func apply(paused: Bool, subscribers: Int = 0) throws {
            try policy.apply(context: [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": paused,
                    "subscribers": ["attention.ingest": subscribers],
                ]
            ])
        }

        func append(_ id: String, at date: Date) throws {
            try repository.append(
                AttentionEvent(
                    id: id, startedAt: date, duration: 10, source: .application,
                    appName: "Fixture Editor"))
        }

        func ids() throws -> [String] {
            try AttentionEventStore(store: database).events(
                from: Date(timeIntervalSince1970: 1_799_999_000),
                to: Date(timeIntervalSince1970: 1_800_010_000)
            ).map(\.id).sorted()
        }

        func remove() {
            UserDefaults(suiteName: defaultsSuite)?.removePersistentDomain(forName: defaultsSuite)
            try? FileManager.default.removeItem(at: root)
        }
    }
}

private actor RecordedSleep {
    private(set) var count = 0
    private(set) var active = 0
    private(set) var duration: Duration?
    private(set) var cancelled = false
    func wait(_ duration: Duration) async throws {
        count += 1
        active += 1
        defer { active -= 1 }
        self.duration = duration
        do { try await Task.sleep(for: .seconds(30)) } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}
