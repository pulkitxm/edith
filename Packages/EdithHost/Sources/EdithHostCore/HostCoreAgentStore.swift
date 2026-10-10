import Darwin
import Foundation

@MainActor final class HostCoreAgentStore {
    static let descriptors: [HostCoreJobDescriptor] = [
        .init(
            id: "backup.sync", title: "iCloud backup", trigger: .fileSystem,
            topic: "backup", cadence: .every(ambient: 86400), power: .pauseOnBattery),
        .init(id: "backup.restore", title: "Settings restore", trigger: .queue, topic: "backup"),
        .init(id: "storage.inspect", title: "Storage inspection", trigger: .queue),
    ]
    private struct Journal: Codable {
        let schemaVersion: Int
        var jobs: [HostCoreJobSnapshot]
        var events: [HostCoreAgentEvent]
    }
    private let url: URL
    private var journal: Journal
    private var executions: [UUID: String] = [:]

    init(directory: URL) throws {
        url = directory.appendingPathComponent("agent.json")
        let empty = Self.descriptors.map {
            HostCoreJobSnapshot(
                descriptor: $0, phase: .idle, subscribers: 0,
                lastRun: nil, lastDuration: nil, lastError: nil, runCount: 0)
        }
        journal = Journal(schemaVersion: 1, jobs: empty, events: [])
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd >= 0 {
            defer { close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG,
                metadata.st_uid == getuid(), metadata.st_nlink == 1,
                metadata.st_mode & 0o077 == 0, (0...2_097_152).contains(metadata.st_size)
            else { throw CocoaError(.fileReadNoPermission) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            let data = try handle.readToEnd() ?? Data()
            let saved = try JSONDecoder().decode(Journal.self, from: data)
            guard saved.schemaVersion == 1, saved.events.count <= 500,
                saved.jobs.map(\.descriptor) == Self.descriptors,
                saved.jobs.allSatisfy({ $0.runCount >= 0 && $0.subscribers == 0 })
            else { throw CocoaError(.fileReadCorruptFile) }
            journal = saved
            for index in journal.jobs.indices where journal.jobs[index].phase == .running {
                let previous = journal.jobs[index]
                journal.jobs[index] = Self.finished(
                    previous, error: "Interrupted when the service stopped.")
                journal.events.append(
                    .init(
                        level: .warning, category: "jobs", name: previous.id,
                        message: "Interrupted when the service stopped."))
            }
        } else if errno != ENOENT {
            throw CocoaError(.fileReadNoPermission)
        }
        record(
            .init(
                category: "lifecycle", name: "core.started", message: "Background service started.")
        )
        try save()
    }

    func snapshot() -> HostCoreAgentSnapshot {
        HostCoreAgentSnapshot(
            build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "development",
            storePath: url.path, schemaVersion: journal.schemaVersion, protocolVersion: 1,
            jobs: journal.jobs, events: journal.events)
    }

    func begin(job: String, execution: UUID, now: Date = Date()) throws {
        guard let index = journal.jobs.firstIndex(where: { $0.id == job }),
            journal.jobs[index].phase != .running, executions[execution] == nil
        else { throw HostWorkerError.rejected }
        let previous = journal.jobs[index]
        journal.jobs[index] = HostCoreJobSnapshot(
            descriptor: previous.descriptor, phase: .running, subscribers: 0,
            lastRun: now, lastDuration: nil, lastError: nil, runCount: previous.runCount + 1)
        executions[execution] = job
        record(
            .init(date: now, category: "jobs", name: job, message: "Started.", taskID: execution))
        try save()
    }

    func finish(execution: UUID, phase: HostCoreTaskSnapshot.Phase, message: String?) throws {
        guard let job = executions.removeValue(forKey: execution),
            let index = journal.jobs.firstIndex(where: { $0.id == job })
        else { throw HostWorkerError.rejected }
        let previous = journal.jobs[index]
        journal.jobs[index] = Self.finished(previous, error: phase == .failed ? message : nil)
        record(
            .init(
                level: phase == .failed ? .error : phase == .cancelled ? .warning : .info,
                category: "jobs", name: job,
                message: message ?? (phase == .completed ? "Completed." : "Cancelled."),
                duration: journal.jobs[index].lastDuration, taskID: execution))
        try save()
    }

    func stopped() throws {
        record(
            .init(
                category: "lifecycle", name: "core.stopped", message: "Background service stopped.")
        )
        try save()
    }

    private static func finished(_ job: HostCoreJobSnapshot, error: String?) -> HostCoreJobSnapshot
    {
        HostCoreJobSnapshot(
            descriptor: job.descriptor, phase: error == nil ? .idle : .failed,
            subscribers: 0, lastRun: job.lastRun,
            lastDuration: job.lastRun.map { max(0, Date().timeIntervalSince($0)) },
            lastError: error, runCount: job.runCount)
    }

    private func record(_ event: HostCoreAgentEvent) {
        journal.events.append(event)
        journal.events = Array(journal.events.suffix(500))
    }

    private func save() throws {
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 2_097_152 else { throw CocoaError(.fileWriteOutOfSpace) }
        try HostCoreFiles.write(data, to: url)
    }
}
