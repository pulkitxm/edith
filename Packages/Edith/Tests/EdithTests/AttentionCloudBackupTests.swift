import Darwin
import Foundation
import Testing

@testable import EdithKit

@Suite struct AttentionCloudBackupTests {
    @Test func successfulBackupReplacesTheWholePreviousGeneration() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.localRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: fixture.localRoot.appendingPathComponent("old.jsonl"))
        let backup = AttentionCloudBackup(
            localDirectory: fixture.localRoot, cloudDirectory: fixture.cloudRoot)
        try backup.backup()
        try FileManager.default.removeItem(
            at: fixture.localRoot.appendingPathComponent("old.jsonl"))
        try Data("new".utf8).write(to: fixture.localRoot.appendingPathComponent("new.jsonl"))
        try backup.backup()
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.cloudRoot.path) == [
                "new.jsonl"
            ])
        #expect(
            try String(
                contentsOf: fixture.cloudRoot.appendingPathComponent("new.jsonl"), encoding: .utf8)
                == "new")
    }

    @Test func failedGenerationKeepsThePreviousArchiveIntact() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.localRoot, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: fixture.localRoot.appendingPathComponent("settings.json"))
        let backup = AttentionCloudBackup(
            localDirectory: fixture.localRoot, cloudDirectory: fixture.cloudRoot)
        try backup.backup()
        try Data("new".utf8).write(to: fixture.localRoot.appendingPathComponent("settings.json"))
        #expect(mkfifo(fixture.localRoot.appendingPathComponent("pipe").path, 0o600) == 0)
        #expect(throws: AttentionArchiveError.self) { try backup.backup() }
        #expect(
            try String(
                contentsOf: fixture.cloudRoot.appendingPathComponent("settings.json"),
                encoding: .utf8) == "old")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.cloudRoot.path) == [
                "settings.json"
            ])
    }

    @Test func publishedMetadataCanRollBackBeforeTheDatabaseCommit() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.cloudRoot, withIntermediateDirectories: true)
        try Data("new".utf8).write(to: fixture.localRoot.appendingPathComponent("settings.json"))
        try Data("old".utf8).write(to: fixture.cloudRoot.appendingPathComponent("settings.json"))
        let publication = try AttentionArchivePublication(
            source: fixture.localRoot, destination: fixture.cloudRoot)
        try publication.publish()
        #expect(
            try String(
                contentsOf: fixture.cloudRoot.appendingPathComponent("settings.json"),
                encoding: .utf8) == "new")
        try publication.rollback()
        #expect(
            try String(
                contentsOf: fixture.cloudRoot.appendingPathComponent("settings.json"),
                encoding: .utf8) == "old")
    }

    @Test func oversizedArchiveFilePreservesTheExistingDestination() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: fixture.cloudRoot, withIntermediateDirectories: true)
        let source = fixture.localRoot.appendingPathComponent("large.jsonl")
        let target = fixture.cloudRoot.appendingPathComponent("large.jsonl")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: 67_108_865)
        try handle.close()
        try Data("previous".utf8).write(to: target)
        #expect(throws: AttentionArchiveError.self) {
            try AttentionArchiveCopy.copy(from: fixture.localRoot, to: fixture.cloudRoot)
        }
        #expect(try String(contentsOf: target, encoding: .utf8) == "previous")
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: fixture.cloudRoot.path) == [
                "large.jsonl"
            ])
    }

    @Test func archiveRefusesPipesAndLinkedDestinationDirectories() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let source = fixture.localRoot.appendingPathComponent("events")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let pipe = source.appendingPathComponent("pipe.jsonl")
        #expect(mkfifo(pipe.path, 0o600) == 0)
        #expect(throws: AttentionArchiveError.self) {
            try AttentionArchiveCopy.copy(from: fixture.localRoot, to: fixture.cloudRoot)
        }
        try FileManager.default.removeItem(at: pipe)
        try Data("event".utf8).write(to: source.appendingPathComponent("day.jsonl"))
        let outside = fixture.root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let destination = fixture.cloudRoot.appendingPathComponent("events")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: outside)
        #expect(throws: AttentionArchiveError.self) {
            try AttentionArchiveCopy.copy(from: fixture.localRoot, to: fixture.cloudRoot)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }

    @Test func cancelledArchiveDoesNotPublishPartialFiles() async throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        try FileManager.default.createDirectory(
            at: fixture.localRoot, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 1_048_576).write(
            to: fixture.localRoot.appendingPathComponent("data.jsonl"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try AttentionArchiveCopy.copy(from: fixture.localRoot, to: fixture.cloudRoot)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fixture.cloudRoot.path))
    }

    @Test func spoolRefusesAnOccupiedLockAndKeepsItsEvents() throws {
        let fixture = fixture()
        defer { fixture.cleanup() }
        let repository = AttentionRepository(root: fixture.localRoot)
        let event = AttentionEvent(
            startedAt: Date(), duration: 5, source: .application, appName: "Fixture")
        try repository.append(event)
        let lock = open(repository.lockFile.path, O_RDWR | O_CLOEXEC)
        #expect(lock >= 0)
        defer { close(lock) }
        #expect(flock(lock, LOCK_EX | LOCK_NB) == 0)
        defer { _ = flock(lock, LOCK_UN) }
        let start = ContinuousClock.now
        #expect(throws: CocoaError.self) {
            try AttentionFileSpool.drain(directory: repository.eventsDirectory) { _ in true }
        }
        #expect(start.duration(to: .now) < .seconds(1))
        #expect(
            FileManager.default.fileExists(atPath: repository.eventFile(for: event.startedAt).path))
    }

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
