import EdithCore
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct FileSystemWatchTests {
    @Test func aFirstEventAlwaysFires() {
        #expect(
            FileSystemWatchPolicy.shouldFire(lastFired: nil, now: Date(), debounce: 30))
    }

    @Test func aSecondEventInsideTheWindowIsHeld() {
        let now = Date()
        #expect(
            !FileSystemWatchPolicy.shouldFire(
                lastFired: now.addingTimeInterval(-5), now: now, debounce: 30))
        #expect(
            FileSystemWatchPolicy.shouldFire(
                lastFired: now.addingTimeInterval(-31), now: now, debounce: 30))
    }

    @Test func onlyExistingDirectoriesAreWatched() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchTests.\(UUID().uuidString)")
        let present = root.appendingPathComponent("present")
        try? FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = FileSystemWatchPolicy.existingPaths(
            [present, root.appendingPathComponent("absent")])

        #expect(paths == [present.path])
    }

    @Test func theUsageWatcherWatchesTheAgentHomes() {
        let home = URL(fileURLWithPath: "/Users/example")
        let directories = UsageWatchPaths.directories(home: home)
        #expect(directories.map(\.lastPathComponent) == [".claude", ".codex"])
    }

    @Test func aWatcherWithNoExistingPathsNeverStarts() {
        let watcher = FileSystemWatcher(
            paths: [URL(fileURLWithPath: "/nowhere-at-all-\(UUID().uuidString)")]
        ) {}
        watcher.start()
        #expect(!watcher.isWatching)
        watcher.stop()
    }
}

@Suite struct UsageCollectorTests {
    @Test func usageDaysAreReadFromTheCollectorDocument() {
        let root: [String: Any] = [
            "daily": [
                ["date": "2026-09-01", "totalCost": 1.25, "inputTokens": 10, "outputTokens": 5],
                ["date": "2026-09-02", "totalCost": 0.5, "source": "codex"],
            ]
        ]

        let rows = UsageDocumentReader.rows(from: root)

        #expect(rows.count == 2)
        #expect(
            rows[0]
                == UsageDayRow(
                    day: "2026-09-01", source: "all", costCents: 125, inputTokens: 10,
                    outputTokens: 5))
        #expect(rows[1].source == "codex")
        #expect(rows[1].costCents == 50)
    }

    @Test func aDocumentWithoutDailyRowsReadsAsEmpty() {
        #expect(UsageDocumentReader.rows(from: ["totals": 3]).isEmpty)
        #expect(UsageDocumentReader.days(at: URL(fileURLWithPath: "/nowhere.json")).isEmpty)
    }

    @Test func aBusyRefreshPublishesNothingRatherThanAnError() async throws {
        let job = UsageCollectorJob(
            store: nil, documentURL: URL(fileURLWithPath: "/nowhere.json"),
            runner: { throw UsageRefreshFailure.busy })

        #expect(try await job.run() == nil)
    }

    @Test func aFailedRefreshPublishesTheFailureRatherThanThrowing() async throws {
        let job = UsageCollectorJob(
            store: nil, documentURL: URL(fileURLWithPath: "/nowhere.json"),
            runner: { throw UsageRefreshFailure.scriptMissing })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(UsageTopicSnapshot.self, from: payload)

        #expect(snapshot.failure != nil)
        #expect(snapshot.days == 0)
    }

    @Test func aSuccessfulRefreshCountsTheDaysItWrote() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("UsageCollector.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("usage.json")
        try JSONSerialization.data(
            withJSONObject: [
                "daily": [["date": "2026-09-01", "totalCost": 2.0]]
            ]
        ).write(to: document)
        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")
        let job = UsageCollectorJob(
            store: store, documentURL: document,
            runner: { UsageRefreshResult(events: [], seconds: 1.5, startedAt: Date()) })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(UsageTopicSnapshot.self, from: payload)
        let stored = try store.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM usage_day") ?? 0
        }

        #expect(snapshot.days == 1)
        #expect(snapshot.totalCostCents == 200)
        #expect(snapshot.failure == nil)
        #expect(stored == 1)
    }
}

@Suite struct MaintenanceCollectorTests {
    @Test func healthProbingNeedsAMachineAndAnAlert() {
        #expect(
            !MachineHealthPolicy.shouldProbe(
                machineCount: 0, notifyDown: true, notifyDiskFull: true))
        #expect(
            !MachineHealthPolicy.shouldProbe(
                machineCount: 3, notifyDown: false, notifyDiskFull: false))
        #expect(
            MachineHealthPolicy.shouldProbe(
                machineCount: 1, notifyDown: true, notifyDiskFull: false))
        #expect(
            MachineHealthPolicy.shouldProbe(
                machineCount: 1, notifyDown: false, notifyDiskFull: true))
    }

    @Test func updateDiscoveryRecordsWhatItFoundAndBadgesIt() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let job = UpdateDiscoveryJob(store: nil, scan: { [] })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(UpdateDiscoverySnapshot.self, from: payload)

        #expect(snapshot.available == 0)
        #expect(snapshot.sources.isEmpty)
    }

    @Test func theCleanerEstimateSumsEveryCategory() async throws {
        let categories = [
            JunkCategory(
                id: "caches", name: "Caches", detail: "",
                items: [
                    JunkItem(
                        id: "a", name: "a", path: URL(fileURLWithPath: "/tmp/a"),
                        sizeBytes: 1_000, selected: true)
                ]),
            JunkCategory(
                id: "logs", name: "Logs", detail: "",
                items: [
                    JunkItem(
                        id: "b", name: "b", path: URL(fileURLWithPath: "/tmp/b"),
                        sizeBytes: 2_500, selected: true)
                ]),
        ]
        let job = CleanerEstimateJob(store: nil, scan: { categories })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(CleanerEstimateSnapshot.self, from: payload)

        #expect(snapshot.reclaimableBytes == 3_500)
        #expect(snapshot.categories == 2)
    }

    @Test func sidebarBadgesRoundTripThroughDefaults() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SidebarBadgeStore.recordUpdates(available: 4, defaults: defaults)
        SidebarBadgeStore.recordReclaimable(bytes: 14_200_000_000, defaults: defaults)
        SidebarBadgeStore.recordSessions(working: 2, defaults: defaults)

        #expect(SidebarBadgeStore.updatesAvailable(defaults) == 4)
        #expect(SidebarBadgeStore.reclaimableBytes(defaults) == 14_200_000_000)
        #expect(SidebarBadgeStore.sessionsWorking(defaults) == 2)
    }

    @Test func negativeBadgeValuesAreClampedToZero() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SidebarBadgeStore.recordUpdates(available: -3, defaults: defaults)
        SidebarBadgeStore.recordReclaimable(bytes: -1, defaults: defaults)

        #expect(SidebarBadgeStore.updatesAvailable(defaults) == 0)
        #expect(SidebarBadgeStore.reclaimableBytes(defaults) == 0)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AgentCollectorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@Suite struct BackupPolicyTests {
    @Test func everyDataClassInThePlanIsCatalogued() {
        let ids = BackupCatalog.classes.map(\.id)
        #expect(
            ids == [
                "settings", "machines", "database", "usage", "attention", "clipboard", "music",
                "metrics", "memories",
            ])
        #expect(Set(ids).count == ids.count)
    }

    @Test func nothingSyncsWhenICloudBackupIsOff() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppStorageKeys.Backup.icloud)

        #expect(BackupCatalog.enabled(in: defaults).isEmpty)
    }

    @Test func alwaysClassesFollowTheMasterSwitchAndOptInOnesNeedTheirOwn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)

        let enabled = Set(BackupCatalog.enabled(in: defaults).map(\.id))

        #expect(enabled.contains("machines"))
        #expect(enabled.contains("attention"))
        #expect(!enabled.contains("clipboard"))
        #expect(!enabled.contains("metrics"))
        #expect(!enabled.contains("memories"))

        defaults.set(true, forKey: AppStorageKeys.Clipboard.backup)
        #expect(BackupCatalog.byID("clipboard")?.isEnabled(in: defaults) == true)
    }

    @Test func neverClassesStayLocalEvenWithEverythingOn() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        for key in [AppStorageKeys.Backup.icloud, AppStorageKeys.Backup.usage] {
            defaults.set(true, forKey: key)
        }

        #expect(BackupCatalog.byID("metrics")?.isEnabled(in: defaults) == false)
        #expect(BackupCatalog.byID("memories")?.isEnabled(in: defaults) == false)
    }

    @Test func theFirstSnapshotAlwaysRunsAndADailyOneWaitsADay() {
        let now = Date()
        #expect(BackupCadence.shouldSnapshot(lastSnapshot: nil, now: now))
        #expect(
            !BackupCadence.shouldSnapshot(
                lastSnapshot: now.addingTimeInterval(-3_600), now: now))
        #expect(
            BackupCadence.shouldSnapshot(
                lastSnapshot: now.addingTimeInterval(-25 * 3_600), now: now))
    }

    @Test func aChangeIsHeldForTheDebounceWindow() {
        let now = Date()
        #expect(BackupCadence.debounce == 60)
        #expect(BackupCadence.nextRun(after: now, now: now) == 60)
        #expect(BackupCadence.nextRun(after: now.addingTimeInterval(-90), now: now) == 0)
    }

    @Test func snapshotFilesAreNamedByTableAndDay() {
        var components = DateComponents()
        components.year = 2026
        components.month = 9
        components.day = 3
        let day = Calendar.current.date(from: components)!

        #expect(
            BackupSnapshotTables.fileName(table: "usage_day", day: day)
                == "usage_day-2026-09-03.jsonl")
    }

    @Test func onlySyncedTablesAreSnapshotted() {
        #expect(
            BackupSnapshotTables.synced == ["usage_day", "limits_sample", "attention_event"])
        #expect(!BackupSnapshotTables.synced.contains("machine_metric"))
        #expect(!BackupSnapshotTables.synced.contains("cleaner_scan"))
    }

    @Test func backupIsSkippedWithNothingEnabled() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppStorageKeys.Backup.icloud)
        let job = BackupJob(store: nil, defaults: defaults)

        let payload = try #require(try await job.run())
        let result = try AgentPayload.decode(BackupSnapshotResult.self, from: payload)

        #expect(result.skipped)
        #expect(result.classes.isEmpty)
    }

    @Test func theFootprintReaderMeasuresAFolderItCanSee() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Footprint.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 2_048).write(to: root.appendingPathComponent("a.bin"))

        #expect(BackupFootprintReader.size(of: root) == 2_048)
        #expect(BackupFootprintReader.size(of: root.appendingPathComponent("missing")) == 0)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "BackupPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
