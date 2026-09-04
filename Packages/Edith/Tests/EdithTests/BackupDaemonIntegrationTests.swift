import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private struct BackupDaemonFixture {
    let root: URL
    let store: AgentStore
    let defaults: UserDefaults
    let suite: String
    var cloud: URL { root.appendingPathComponent("cloud") }

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupDaemon.\(UUID().uuidString)")
        store = try AgentStore(url: root.appendingPathComponent("store.sqlite"), build: "test")
        suite = "BackupDaemon.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppStorageKeys.Backup.icloud)
    }

    func job(attention: Bool = false) -> BackupJob {
        BackupJob(
            store: store, cloudDirectory: cloud, defaults: defaults,
            cloudAvailable: { true }, attentionBackupEnabled: { attention })
    }

    func run(_ job: BackupJob, now: Date = Date()) async throws -> BackupSnapshotResult {
        let data = try #require(try await job.run(now: now))
        return try AgentPayload.decode(BackupSnapshotResult.self, from: data)
    }

    func close() {
        try? store.close()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

@Suite struct BackupDaemonIntegrationTests {
    @Test func disabledClassesDoNotCreateSnapshotsOrRecordSuccess() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        for key in [
            AppStorageKeys.Backup.settings, AppStorageKeys.Backup.usage,
            AppStorageKeys.Backup.limits,
        ] {
            fixture.defaults.set(false, forKey: key)
        }
        let result = try await fixture.run(fixture.job())
        #expect(result.snapshotTables.isEmpty)
        #expect(!result.classes.contains("settings"))
        #expect(!result.classes.contains("usage"))
        #expect(!result.classes.contains("limits"))
        #expect(!result.classes.contains("attention"))
        #expect(fixture.defaults.object(forKey: BackupSnapshotTables.timestampKey) == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.cloud.path))
    }

    @Test func optedInAttentionSnapshotsContainTheActualSQLiteEvents() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.usage)
        fixture.defaults.set(false, forKey: AppStorageKeys.Backup.limits)
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let event = AttentionEvent(
            startedAt: now, duration: 30, source: .application, appName: "Writing")
        try AttentionEventStore(store: fixture.store).record(AttentionBatch(events: [event]))
        let result = try await fixture.run(fixture.job(attention: true), now: now)
        #expect(result.snapshotTables == ["attention_event"])
        let file = fixture.cloud.appendingPathComponent("snapshots")
            .appendingPathComponent(
                BackupSnapshotTables.fileName(table: "attention_event", day: now))
        let data = try Data(contentsOf: file)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try #require(
            (object["payload"] as? String).flatMap { Data(base64Encoded: $0) })
        #expect(try AgentPayload.decode(AttentionEvent.self, from: payload) == event)
    }

    @Test func snapshotCadenceUsesItsOwnTimestampAndTracksEachEnabledTable() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        let now = Date()
        fixture.defaults.set(now.timeIntervalSince1970, forKey: AppStorageKeys.Backup.lastBackupAt)
        let first = try await fixture.run(fixture.job(), now: now)
        #expect(first.snapshotTables == ["usage_day", "limits_sample"])
        let repeated = try await fixture.run(fixture.job(), now: now.addingTimeInterval(60))
        #expect(repeated.snapshotTables.isEmpty)
        let attention = try await fixture.run(
            fixture.job(attention: true), now: now.addingTimeInterval(61))
        #expect(attention.snapshotTables == ["attention_event"])
        let nextDay = try await fixture.run(
            fixture.job(attention: true), now: now.addingTimeInterval(86_500))
        #expect(nextDay.snapshotTables == BackupSnapshotTables.synced)
    }

    @Test func emptyTablesPublishAnEmptySnapshotInsteadOfRetainingOldRows() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        let now = Date()
        let directory = fixture.cloud.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            BackupSnapshotTables.fileName(table: "usage_day", day: now))
        try Data("old-row\n".utf8).write(to: file)
        _ = try await fixture.run(fixture.job(), now: now)
        #expect(try Data(contentsOf: file).isEmpty)
    }

    @Test func failedDatabaseSnapshotPreservesTheArchiveAndSuccessTimestamp() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        let now = Date()
        let directory = fixture.cloud.appendingPathComponent("snapshots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(
            BackupSnapshotTables.fileName(table: "usage_day", day: now))
        let original = Data("original-archive\n".utf8)
        try original.write(to: file)
        try fixture.store.close()
        await #expect(throws: (any Error).self) { try await fixture.run(fixture.job(), now: now) }
        #expect(try Data(contentsOf: file) == original)
        #expect(fixture.defaults.object(forKey: BackupSnapshotTables.timestampKey) == nil)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: directory.path) == [
                file.lastPathComponent
            ])
    }

    @Test func unwritableDestinationAndMissingStoreAreReported() async throws {
        let fixture = try BackupDaemonFixture()
        defer { fixture.close() }
        try Data("occupied".utf8).write(to: fixture.cloud)
        await #expect(throws: (any Error).self) { try await fixture.run(fixture.job()) }
        let missing = BackupJob(
            store: nil, cloudDirectory: fixture.cloud, defaults: fixture.defaults,
            cloudAvailable: { true }, attentionBackupEnabled: { false })
        await #expect(throws: (any Error).self) { try await missing.run() }
        #expect(fixture.defaults.object(forKey: BackupSnapshotTables.timestampKey) == nil)
    }

    @Test func cloudPathCanBeIsolatedWithoutChangingTheHomeDirectory() {
        let local = URL(fileURLWithPath: "/tmp/backup-fixture")
        #expect(
            AppData.resolveCloudDirectory(environment: ["EDITH_CLOUD_ROOT": local.path]) == local)
        #expect(
            AppData.resolveCloudDirectory(environment: [:], homeDirectory: local)
                == local.appendingPathComponent(
                    "Library/Mobile Documents/com~apple~CloudDocs/Edith"))
    }
}
