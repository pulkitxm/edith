import Darwin
import EdithExtensionSupport
import Foundation
import Testing

@testable import EdithHostCore

@Suite @MainActor struct HostCoreAgentTests {
    @Test func originalStatusReportsRealProcessAndOwnedJournal() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity)
        let snapshot = runtime.snapshot()
        let agent = try #require(snapshot.agent)
        let status = try HostCoreAgentStatus(snapshot: snapshot, cpuPercent: 0)
        #expect(status.pid == getpid())
        #expect(status.residentBytes > 0)
        #expect(status.state == "enabled")
        #expect(
            status.store == fixture.identity.root.appendingPathComponent("Core/agent.json").path)
        #expect(status.schemaVersion == 1)
        #expect(status.protocolVersion == 1)
        #expect(FileManager.default.fileExists(atPath: status.store))
        #expect(agent.jobs.map(\.id) == ["backup.sync", "backup.restore", "storage.inspect"])
        #expect(agent.jobs.allSatisfy { $0.phase == .idle && $0.runCount == 0 })
        #expect(agent.events.last?.name == "core.started")
        await runtime.shutdown()
    }

    @Test func realStorageRunRecordsDescriptorCountEventsAndRestart() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity)
        let data = fixture.identity.extensionDirectory("usage")
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 71).write(to: data.appendingPathComponent("synthetic"))
        let result = try await runtime.inspect()
        #expect(result.storage?.footprints.first { $0.id == "usage" }?.bytes == 71)
        let agent = try #require(result.agent)
        let job = try #require(agent.jobs.first { $0.id == "storage.inspect" })
        #expect(job.descriptor.trigger == .queue)
        #expect(job.descriptor.cadence.ambient == nil)
        #expect(job.runCount == 1)
        #expect(job.phase == .idle)
        #expect(job.lastRun != nil && job.lastDuration != nil && job.lastError == nil)
        let events = agent.events.filter { $0.name == job.id }
        #expect(events.map(\.message) == ["Started.", "Completed."])
        #expect(events[0].taskID == events[1].taskID)
        #expect(events[1].taskID == result.tasks.last?.id)
        await runtime.shutdown()
        let reopened = try HostCoreRuntime(identity: fixture.identity)
        #expect(reopened.snapshot().agent?.jobs.first { $0.id == job.id }?.runCount == 1)
        #expect(reopened.snapshot().agent?.events.contains { $0.name == "core.stopped" } == true)
        await reopened.shutdown()
    }

    @Test func realBackupAndInvalidRestoreKeepDistinctCountsAndErrors() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let defaults = try #require(
            SharedDefaults.applicationStore(identifier: fixture.identity.identifier))
        defer { defaults.removePersistentDomain(forName: fixture.identity.identifier) }
        defaults.set("synthetic", forKey: AppStorageKeys.General.theme)
        let cloud = fixture.directory.appendingPathComponent("cloud")
        let runtime = try HostCoreRuntime(identity: fixture.identity, cloudDirectory: cloud)
        let exported = try await runtime.synchronizeSettings()
        #expect(exported.settingsBackup?.exported == true)
        #expect(exported.agent?.jobs.first { $0.id == "backup.sync" }?.runCount == 1)
        try Data("invalid".utf8).write(to: cloud.appendingPathComponent("settings.json"))
        await #expect(throws: (any Error).self) {
            try await runtime.synchronizeSettings(restoreOnly: true)
        }
        let restore = try #require(
            runtime.snapshot().agent?.jobs.first { $0.id == "backup.restore" })
        #expect(restore.runCount == 1 && restore.phase == .failed)
        #expect(restore.lastError == "Settings backup could not finish.")
        #expect(runtime.snapshot().agent?.events.last?.level == .error)
        await runtime.shutdown()
    }

    @Test func failedJobJournalWritesNeverLeaveAnOwnedJobRunning() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let directory = fixture.identity.root.appendingPathComponent("Core")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = try HostCoreAgentStore(directory: directory)
        let journal = directory.appendingPathComponent("agent.json")
        let saved = directory.appendingPathComponent("saved.json")
        let execution = UUID()
        try FileManager.default.moveItem(at: journal, to: saved)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.begin(job: "storage.inspect", execution: execution)
        }
        var job = try #require(store.snapshot().jobs.first { $0.id == "storage.inspect" })
        #expect(job.phase == .idle && job.runCount == 0)
        #expect(!store.snapshot().events.contains { $0.taskID == execution })
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.moveItem(at: saved, to: journal)
        try store.begin(job: "storage.inspect", execution: execution)
        try FileManager.default.moveItem(at: journal, to: saved)
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            try store.finish(execution: execution, phase: .completed, message: nil)
        }
        job = try #require(store.snapshot().jobs.first { $0.id == "storage.inspect" })
        #expect(job.phase == .failed && job.runCount == 1)
        #expect(job.lastError == "The core job journal could not be saved.")
        try FileManager.default.removeItem(at: journal)
        try FileManager.default.moveItem(at: saved, to: journal)
        let retry = UUID()
        try store.begin(job: "storage.inspect", execution: retry)
        try store.finish(execution: retry, phase: .completed, message: nil)
        #expect(store.snapshot().jobs.first { $0.id == job.id }?.runCount == 2)
        #expect(store.snapshot().jobs.allSatisfy { $0.phase != .running })
    }

    @Test func failedTaskJournalWriteStopsBeforeStorageWorkAndCanRetry() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity)
        let journal = fixture.identity.root.appendingPathComponent("Core/tasks.json")
        try FileManager.default.createDirectory(at: journal, withIntermediateDirectories: false)
        await #expect(throws: (any Error).self) { try await runtime.inspect() }
        let failed = runtime.snapshot()
        #expect(failed.storage == nil)
        #expect(failed.tasks.last?.phase == .failed)
        #expect(failed.tasks.allSatisfy { $0.phase != .running })
        #expect(failed.agent?.jobs.first { $0.id == "storage.inspect" }?.phase == .failed)
        try FileManager.default.removeItem(at: journal)
        let retry = try await runtime.inspect()
        #expect(retry.storage != nil)
        #expect(retry.agent?.jobs.first { $0.id == "storage.inspect" }?.runCount == 2)
        #expect(retry.tasks.allSatisfy { $0.phase != .running })
        await runtime.shutdown()
    }

    @Test func overflowingPersistedJobCounterIsRejected() throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let directory = fixture.identity.root.appendingPathComponent("Core")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try HostCoreAgentStore(directory: directory)
        let journal = directory.appendingPathComponent("agent.json")
        var document = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any])
        var jobs = try #require(document["jobs"] as? [[String: Any]])
        jobs[0]["runCount"] = Int.max
        document["jobs"] = jobs
        try HostCoreFiles.write(JSONSerialization.data(withJSONObject: document), to: journal)
        #expect(throws: CocoaError.self) { try HostCoreAgentStore(directory: directory) }
    }

    @Test func ownedRunningJobIsRecoveredAndUnsafeJournalIsRejected() async throws {
        let fixture = try CoreAgentFixture()
        defer { fixture.remove() }
        let runtime = try HostCoreRuntime(identity: fixture.identity)
        await runtime.shutdown()
        let directory = fixture.identity.root.appendingPathComponent("Core")
        let store = try HostCoreAgentStore(directory: directory)
        try store.begin(job: "storage.inspect", execution: UUID())
        let reopened = try HostCoreAgentStore(directory: directory)
        let job = try #require(reopened.snapshot().jobs.first { $0.id == "storage.inspect" })
        #expect(job.phase == .failed && job.runCount == 1)
        #expect(job.lastError == "Interrupted when the service stopped.")
        let journal = directory.appendingPathComponent("agent.json")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644], ofItemAtPath: journal.path)
        #expect(throws: CocoaError.self) { try HostCoreRuntime(identity: fixture.identity) }
        try FileManager.default.removeItem(at: journal)
        let foreign = fixture.directory.appendingPathComponent("foreign")
        try Data("private".utf8).write(to: foreign)
        try FileManager.default.createSymbolicLink(at: journal, withDestinationURL: foreign)
        #expect(throws: CocoaError.self) { try HostCoreRuntime(identity: fixture.identity) }
        #expect(try Data(contentsOf: foreign) == Data("private".utf8))
    }
}

private struct CoreAgentFixture {
    let directory: URL
    let identity: HostIdentity
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "core-agent-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        identity = try HostIdentity(
            identifier: "com.pulkit.edith.tests.core-" + UUID().uuidString,
            supportDirectory: directory)
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
}
