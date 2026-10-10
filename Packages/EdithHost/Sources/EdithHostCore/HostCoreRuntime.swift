import Darwin
import EdithExtensionSupport
import Foundation

@MainActor public final class HostCoreRuntime {
    public let identity: HostIdentity
    private let startedAt = Date()
    private let cloud: URL
    private var storage: HostStorageSnapshot?
    private var tasks: [HostCoreTaskSnapshot] = []
    private var inspection: Task<HostStorageSnapshot, Error>?
    private var cancellation: WorkCancellation?
    private let journal: URL
    private let agent: HostCoreAgentStore
    private var stopping = false
    private let settings: HostSettingsArchive
    private var backup: Task<HostSettingsBackupResult, Error>?
    private var backupResult: HostSettingsBackupResult?

    public init(identity: HostIdentity, cloudDirectory: URL? = nil) throws {
        self.identity = identity
        cloud = cloudDirectory ?? HostCoreCloud.directory(identity: identity)
        let directory = identity.root.appendingPathComponent("Core")
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var metadata = stat()
        guard lstat(directory.path, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_uid == getuid(),
            metadata.st_mode & 0o077 == 0
        else { throw CocoaError(.fileReadNoPermission) }
        agent = try HostCoreAgentStore(directory: directory)
        journal = directory.appendingPathComponent("tasks.json")
        settings = try HostSettingsArchive(identity: identity, cloudDirectory: cloud)
        if lstat(journal.path, &metadata) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFREG, metadata.st_uid == getuid(),
                metadata.st_nlink == 1, metadata.st_mode & 0o077 == 0,
                metadata.st_size <= 131_072
            else { throw CocoaError(.fileReadNoPermission) }
            tasks = try JSONDecoder().decode(
                [HostCoreTaskSnapshot].self,
                from: Data(contentsOf: journal)
            ).suffix(32).map {
                guard $0.phase == .running else { return $0 }
                return HostCoreTaskSnapshot(
                    id: $0.id, title: $0.title, startedAt: $0.startedAt,
                    finishedAt: Date(), phase: .cancelled,
                    message: "Interrupted when the service stopped.")
            }
            try saveTasks()
        }
    }

    public func snapshot() -> HostCoreSnapshot {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let valid = proc_pidinfo(getpid(), PROC_PIDTASKINFO, 0, &info, Int32(size)) == size
        return HostCoreSnapshot(
            pid: getpid(), startedAt: startedAt, collectedAt: Date(),
            residentBytes: valid ? info.pti_resident_size : 0,
            cpuSeconds: valid ? Double(info.pti_total_user + info.pti_total_system) / 1e9 : 0,
            storage: storage, tasks: tasks, cloudDirectory: cloud,
            cloudAvailable: HostCoreCloud.available(identity: identity, directory: cloud),
            settingsBackup: backupResult, agent: agent.snapshot())
    }

    public func inspect() async throws -> HostCoreSnapshot {
        try Task.checkCancellation()
        guard !stopping, backup == nil else { throw HostWorkerError.rejected }
        if let inspection { storage = try await inspection.value; return snapshot() }
        let id = UUID()
        try agent.begin(job: "storage.inspect", execution: id)
        tasks.append(
            HostCoreTaskSnapshot(
                id: id, title: "Inspecting storage and backup sizes",
                startedAt: Date(), finishedAt: nil, phase: .running, message: nil))
        tasks = Array(tasks.suffix(32))
        try saveTasks()
        let cancellation = WorkCancellation()
        self.cancellation = cancellation
        let targets = HostStorageTarget.defaults(identity: identity)
        let cloud = cloud
        let work = Task.detached(priority: .utility) {
            try HostStorageInspection.inspect(
                targets: targets, cloud: cloud,
                isCancelled: { cancellation.isCancelled })
        }
        inspection = work
        defer { inspection = nil; self.cancellation = nil }
        do {
            storage = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                cancellation.cancel(); work.cancel()
            }
            try finish(id, phase: .completed, message: nil)
            return snapshot()
        } catch {
            try finish(
                id, phase: error is CancellationError ? .cancelled : .failed,
                message: error is CancellationError
                    ? "Cancelled." : "Storage could not be inspected.")
            throw error
        }
    }

    public func synchronizeSettings(restoreOnly: Bool = false) async throws -> HostCoreSnapshot {
        try Task.checkCancellation()
        guard !stopping, inspection == nil, backup == nil else { throw HostWorkerError.rejected }
        let id = UUID()
        try agent.begin(job: restoreOnly ? "backup.restore" : "backup.sync", execution: id)
        tasks.append(
            HostCoreTaskSnapshot(
                id: id,
                title: restoreOnly ? "Restoring settings from iCloud" : "Backing up settings",
                startedAt: Date(), finishedAt: nil, phase: .running, message: nil))
        tasks = Array(tasks.suffix(32))
        try saveTasks()
        let settings = settings
        let work = Task { try await settings.synchronize(restoreOnly: restoreOnly) }
        backup = work
        defer { backup = nil }
        do {
            backupResult = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            try finish(id, phase: .completed, message: nil)
            return snapshot()
        } catch {
            try finish(
                id, phase: error is CancellationError ? .cancelled : .failed,
                message: error is CancellationError
                    ? "Cancelled." : "Settings backup could not finish.")
            throw error
        }
    }

    public func cancel() {
        cancellation?.cancel(); inspection?.cancel()
        settings.cancel(); backup?.cancel()
    }

    public func shutdown() async {
        stopping = true
        cancel()
        _ = try? await inspection?.value
        await settings.shutdown()
        _ = try? await backup?.value
        try? agent.stopped()
    }

    private func finish(_ id: UUID, phase: HostCoreTaskSnapshot.Phase, message: String?) throws {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = tasks[index]
        tasks[index] = HostCoreTaskSnapshot(
            id: id, title: previous.title, startedAt: previous.startedAt,
            finishedAt: Date(), phase: phase, message: message)
        try saveTasks()
        try agent.finish(execution: id, phase: phase, message: message)
    }

    private func saveTasks() throws {
        let data = try JSONEncoder().encode(tasks)
        guard data.count <= 131_072 else { throw CocoaError(.fileWriteOutOfSpace) }
        try HostCoreFiles.write(data, to: journal)
    }
}
