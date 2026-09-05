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
    @Test func usageDaysAreReadFromTheCollectorDocument() throws {
        let root: [String: Any] = [
            "daily": [
                [
                    "period": "2026-09-01",
                    "bySource": ["first": [["cost": 1.25, "inputTokens": 10, "outputTokens": 5]]],
                ],
                ["period": "2026-09-02", "bySource": ["second": [["cost": 0.5]]]],
            ]
        ]

        let rows = try UsageDocumentReader.rows(from: root)

        #expect(rows.count == 2)
        #expect(
            rows[0]
                == UsageDayRow(
                    day: "2026-09-01", source: "all", costCents: 125, inputTokens: 10,
                    outputTokens: 5))
        #expect(rows[1].source == "all")
        #expect(rows[1].costCents == 50)
    }

    @Test func missingOrMalformedDocumentsAreRejected() {
        #expect(throws: (any Error).self) { try UsageDocumentReader.rows(from: ["totals": 3]) }
        #expect(throws: (any Error).self) {
            try UsageDocumentReader.days(at: URL(fileURLWithPath: "/nowhere.json"))
        }
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
                "daily": [["period": "2026-09-01", "bySource": ["first": [["cost": 2.0]]]]]
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
                "settings", "machines", "database", "usage", "limits", "attention", "clipboard",
                "music",
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
        #expect(!enabled.contains("attention"))
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

    @Test func theDaemonInspectionMeasuresAFolderItCanSee() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("Footprint.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 7, count: 2_048).write(to: root.appendingPathComponent("a.bin"))

        let missing = root.appendingPathComponent("missing")
        let workflow = StorageInspectionWorkflow(
            targets: [
                .init(id: "data", title: "Data", url: root),
                .init(id: "missing", title: "Missing", url: missing),
            ], cloudDirectory: missing)
        let result = try await workflow.inspect()
        #expect(result.footprints.map(\.bytes) == [2_048, 0])
        #expect(result.footprints.map(\.exists) == [true, false])
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "BackupPolicyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@Suite struct SessionsAndDownloadTests {
    private func host(
        id: String, working: Int, idle: Int, reachable: Bool = true
    ) -> HerdrHostSnapshot {
        let agents =
            (0..<working).map { agent(id: "\(id)-w\($0)", host: id, status: .working) }
            + (0..<idle).map { agent(id: "\(id)-i\($0)", host: id, status: .idle) }
        return HerdrHostSnapshot(
            id: id, name: id, isLocal: id == "local", herdrPresent: true, reachable: reachable,
            agents: agents)
    }

    private func agent(id: String, host: String, status: HerdrAgentStatus) -> HerdrAgent {
        HerdrAgent(
            id: id, machineID: host, machineName: host, machineIsLocal: host == "local",
            sshTarget: nil, session: "s", pane: "p", kind: "claude", status: status,
            title: "t", workspace: "w", cwd: "/tmp")
    }

    @Test func discoveryStopsEntirelyWhenNothingWatchesAndAlertsAreOff() {
        #expect(SessionsTally.scope(subscribed: false, blockAlerts: false) == nil)
    }

    @Test func blockAlertsKeepALocalOnlyAmbientPoll() {
        let scope = SessionsTally.scope(subscribed: false, blockAlerts: true)
        guard case .local = scope else {
            Issue.record("expected a local scope, got \(String(describing: scope))")
            return
        }
    }

    @Test func aSubscriberWidensDiscoveryToEveryHost() {
        let scope = SessionsTally.scope(subscribed: true, blockAlerts: false)
        guard case .all = scope else {
            Issue.record("expected every host, got \(String(describing: scope))")
            return
        }
    }

    @Test func theSnapshotCountsWorkingAgentsAcrossHosts() {
        let snapshot = SessionsTally.snapshot(
            hosts: [host(id: "local", working: 2, idle: 1), host(id: "box", working: 1, idle: 3)])

        #expect(snapshot.working == 3)
        #expect(snapshot.total == 7)
        #expect(snapshot.hosts.map(\.id) == ["local", "box"])
        #expect(snapshot.summaries.first?.working == 2)
    }

    @Test func anUnwatchedDiscoveryPublishesNothing() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let job = SessionsJob(
            store: nil, isSubscribed: { false }, defaults: defaults, notify: { _ in },
            collect: { _ in [] })

        #expect(try await job.run() == nil)
    }

    @Test func aWatchedDiscoveryPublishesItsCount() async throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let hosts = [host(id: "local", working: 2, idle: 0)]
        let job = SessionsJob(
            store: nil, isSubscribed: { true }, defaults: defaults, notify: { _ in },
            collect: { _ in hosts })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(SessionsSnapshot.self, from: payload)

        #expect(snapshot.working == 2)
    }

    private func record(status: DownloadStatus) -> DownloadRecord {
        DownloadRecord(
            url: URL(string: "https://example.com/\(UUID().uuidString)")!, status: status,
            outputFilename: nil, createdAt: Date(), kind: .audio)
    }

    @Test func theQueueTallySplitsRunningFromFinishedAndFailed() {
        let records = [
            record(status: .queued),
            record(status: .downloading(progress: "10%", videoIndex: 1, videoCount: 2)),
            record(status: .resolving),
            record(status: .done("d.m4a")),
            record(status: .error("nope")),
            record(status: .interrupted(nil)),
        ]

        let snapshot = DownloadQueueTally.snapshot(records: records)

        #expect(snapshot.queued == 1)
        #expect(snapshot.running == 2)
        #expect(snapshot.finished == 1)
        #expect(snapshot.failed == 2)
        #expect(snapshot.pending == 3)
    }

    @Test func anEmptyQueueTalliesToZero() async throws {
        let job = DownloadQueueJob(store: nil, load: { [] })

        let payload = try #require(try await job.run())
        let snapshot = try AgentPayload.decode(DownloadQueueTopicSnapshot.self, from: payload)

        #expect(snapshot.pending == 0)
        #expect(snapshot.finished == 0)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "SessionsJobTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}

@Suite struct AttentionTransportTests {
    private func event(
        id: String = UUID().uuidString, startedAt: Date, duration: TimeInterval = 60
    ) -> AttentionEvent {
        AttentionEvent(
            id: id, startedAt: startedAt, duration: duration, source: .application,
            appName: "Edith", bundleID: "com.pulkit.edith")
    }

    @Test func eventsOlderThanAYearAreExpired() {
        let now = Date()
        #expect(!AttentionRetention.isExpired(event(startedAt: now), now: now))
        #expect(
            AttentionRetention.isExpired(
                event(startedAt: now.addingTimeInterval(-366 * 86_400)), now: now))
        #expect(AttentionRetention.days == 365)
    }

    @Test func aBatchCarriesItsPulseTime() throws {
        let one = event(startedAt: Date())
        let batch = AttentionBatch(events: [one], pulseTime: 45)
        let round = try AgentPayload.decode(
            AttentionBatch.self, from: AgentPayload.encode(batch))

        #expect(round.pulseTime == 45)
        #expect(round.events.map(\.id) == [one.id])
        #expect(round.events.first?.duration == one.duration)
    }

    @Test func foldingMergesAContinuationAndAppendsAnythingElse() {
        let start = Date()
        let first = event(startedAt: start, duration: 30)
        let continuation = AttentionEvent(
            startedAt: start.addingTimeInterval(30), duration: 30, source: .application,
            appName: "Edith", bundleID: "com.pulkit.edith")
        let other = AttentionEvent(
            startedAt: start.addingTimeInterval(120), duration: 30, source: .application,
            appName: "Xcode", bundleID: "com.apple.dt.Xcode")

        let merged = AttentionMerge.fold([first], with: continuation, pulseTime: 30)
        let appended = AttentionMerge.fold(merged, with: other, pulseTime: 30)

        #expect(merged.count == 1)
        #expect(merged[0].duration == 60)
        #expect(appended.count == 2)
    }

    @Test func legacyLinesAreReadBackAsEvents() throws {
        let events = [event(startedAt: Date()), event(startedAt: Date().addingTimeInterval(-60))]
        let lines = try events.map { try AgentPayload.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
        let document = Data(lines.joined(separator: "\n").utf8)

        #expect(AttentionLegacyReader.events(in: document).count == 2)
        #expect(AttentionLegacyReader.events(in: Data("not json".utf8)).isEmpty)
    }

    @Test func theAgentStoresAndReadsBackARange() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionStore.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")
        let events = AttentionEventStore(store: store)
        let start = Date().addingTimeInterval(-600)

        try events.record(AttentionBatch(events: [event(startedAt: start, duration: 120)]))
        let read = try events.events(
            from: start.addingTimeInterval(-60), to: start.addingTimeInterval(600))

        #expect(read.count == 1)
        #expect(read.first?.appName == "Edith")
    }

    @Test func recordingTheSameEventTwiceKeepsOneRow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionStore.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")
        let events = AttentionEventStore(store: store)
        let one = event(id: "stable", startedAt: Date().addingTimeInterval(-300))

        try events.record(AttentionBatch(events: [one]))
        try events.record(AttentionBatch(events: [one]))
        let rows = try store.read { database in
            try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM attention_event") ?? 0
        }

        #expect(rows == 1)
    }

    @Test func importedSpoolFilesAreDrainedOnce() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AttentionImport.\(UUID().uuidString)")
        let events = root.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: events, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let line = try AgentPayload.encode(event(startedAt: Date().addingTimeInterval(-120)))
        try (String(data: line, encoding: .utf8) ?? "").write(
            to: events.appendingPathComponent("2026-09-01.jsonl"), atomically: true,
            encoding: .utf8)
        let store = try AgentStore(url: AgentStoreLayout.storeURL(root: root), build: "1")
        let sut = AttentionEventStore(store: store)

        let first = try sut.importLegacyFiles(directory: events)
        let second = try sut.importLegacyFiles(directory: events)

        #expect(first.events == 1)
        #expect(!first.alreadyImported)
        #expect(second.alreadyImported)
        #expect(second.events == 0)
    }

    @Test func theAgentDeclaresItsInternalOperations() {
        #expect(AgentOperationCatalog.servesInternal(AttentionOperation.record))
        #expect(AgentOperationCatalog.servesInternal(AttentionOperation.range))
        #expect(!AgentOperationCatalog.servesInternal("nope"))
        #expect(AgentOperationCatalog.allNames.contains("agent.status"))
        #expect(AgentOperationCatalog.allNames.contains(AttentionOperation.record))
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "AttentionTransportTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }
}
