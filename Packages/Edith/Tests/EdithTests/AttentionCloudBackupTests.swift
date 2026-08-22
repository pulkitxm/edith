import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionCloudBackupTests {
    @Test func backupAndEmptyRestoreRoundTripRealFiles() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let repository = AttentionRepository(root: fixture.localRoot)
        let now = Date(timeIntervalSince1970: 1_775_000_000)
        try repository.append(
            AttentionEvent(
                startedAt: now, duration: 30, source: .application,
                appName: "Writing", bundleID: "com.example.Writing"))
        let backup = AttentionCloudBackup(
            localDirectory: repository.directory, cloudDirectory: fixture.cloudRoot)
        try backup.backup(now: now)
        #expect(backup.available)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.cloudRoot.appendingPathComponent("events")
                    .appendingPathComponent(repository.eventFile(for: now).lastPathComponent).path))
        try FileManager.default.removeItem(at: repository.directory)
        try backup.restoreWhenLocalStoreIsEmpty()
        #expect(
            FileManager.default.fileExists(
                atPath: repository.eventFile(for: now).path))
        #expect(
            repository.events(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(60))
                .count
                == 1)
    }

    @Test func restoreRefusesToOverwriteRecordedEvents() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let repository = AttentionRepository(root: fixture.localRoot)
        let cloud = fixture.cloudRoot.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: cloud, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: cloud.appendingPathComponent("2026-01-01.jsonl"))
        try repository.append(
            AttentionEvent(
                startedAt: Date(), duration: 30, source: .application, appName: "Xcode"))
        let backup = AttentionCloudBackup(
            localDirectory: repository.directory, cloudDirectory: fixture.cloudRoot)
        #expect(throws: AttentionCloudBackupError.localStoreNotEmpty) {
            try backup.restoreWhenLocalStoreIsEmpty()
        }
    }

    private func fixture() -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-attention-backup-\(UUID().uuidString)")
        return Fixture(
            root: root, localRoot: root.appendingPathComponent("local"),
            cloudRoot: root.appendingPathComponent("cloud"))
    }

    private struct Fixture {
        let root: URL
        let localRoot: URL
        let cloudRoot: URL

        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
}
