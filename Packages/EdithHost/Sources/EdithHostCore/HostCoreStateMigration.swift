import Darwin
import Foundation

@MainActor enum HostCoreStateMigration {
    private struct Receipt: Codable {
        let version: Int
        let tasks: Int
        let schedules: Int
        let events: Int
    }

    static func importExisting(identity: HostIdentity) throws {
        guard identity.identifier == "com.pulkit.edith" else { return }
        let core = try HostAgentJournal(directory: identity.root.appendingPathComponent("Core"))
        let marker = "state-import.json"
        if try core.files().contains(where: { $0.lastPathComponent == marker }) {
            let receipt = try JSONDecoder().decode(
                Receipt.self, from: core.read(marker, maximumBytes: 1024))
            guard receipt.version == 1 else { throw invalid() }
            return
        }
        let tasks = try existingTasks(root: identity.root)
        let commands = try HostAgentJournal(
            directory: core.directory.appendingPathComponent("Commands"))
        let taskJournal = try HostAgentJournal(
            directory: commands.directory.appendingPathComponent("Tasks"))
        let scheduleJournal = try HostAgentJournal(
            directory: commands.directory.appendingPathComponent("Schedules"))
        let hasSchedules = try scheduleJournal.files().contains {
            $0.lastPathComponent == "schedules.json"
        }
        let hasEvents = try core.files().contains { $0.lastPathComponent == "agent.json" }
        let snapshot = try HostCoreStateSnapshot.read(
            source: identity.root, temporaryParent: core.directory,
            schedules: !hasSchedules, events: !hasEvents)
        let schedules = try JSONEncoder().encode(snapshot.schedules)
        let events = try JSONEncoder().encode(
            HostCoreAgentStore.initialJournal(events: snapshot.events))
        guard schedules.count <= HostAgentScheduleService.maximumJournalBytes,
            events.count <= 2_097_152
        else { throw invalid() }
        let selectedTasks = try availableTasks(tasks, journal: taskJournal)
        for task in selectedTasks {
            try taskJournal.write(task.data, name: task.name, maximumBytes: 17 << 20)
        }
        if !hasSchedules {
            try scheduleJournal.write(
                schedules, name: "schedules.json",
                maximumBytes: HostAgentScheduleService.maximumJournalBytes)
        }
        if !hasEvents { try core.write(events, name: "agent.json", maximumBytes: 2_097_152) }
        try core.write(
            JSONEncoder().encode(
                Receipt(
                    version: 1, tasks: selectedTasks.count, schedules: snapshot.schedules.count,
                    events: snapshot.events.count)),
            name: marker, maximumBytes: 1024)
    }

    private static func availableTasks(
        _ tasks: [(name: String, data: Data)], journal: HostAgentJournal
    ) throws -> [(name: String, data: Data)] {
        var identities: Set<UUID> = []
        var resultBytes = 0
        var readBytes = 0
        for file in try journal.files() where file.pathExtension == "json" {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent) else {
                throw invalid()
            }
            let data = try journal.read(file.lastPathComponent, maximumBytes: 17 << 20)
            readBytes += data.count
            guard readBytes <= 64 << 20 else { throw invalid() }
            let entry = try HostAgentPayload.decode(PersistedHostAgentTask.self, from: data)
            guard entry.status.snapshot.id == id, identities.insert(id).inserted else {
                throw invalid()
            }
            resultBytes += entry.status.result?.count ?? 0
        }
        var available = max(0, 100 - identities.count)
        var result: [(name: String, data: Data)] = []
        for task in tasks {
            let entry = try HostAgentPayload.decode(PersistedHostAgentTask.self, from: task.data)
            let bytes = entry.status.result?.count ?? 0
            guard available > 0, resultBytes + bytes <= 16 << 20,
                identities.insert(entry.status.snapshot.id).inserted
            else { continue }
            available -= 1
            resultBytes += bytes
            result.append(task)
        }
        return result
    }

    private static func existingTasks(root: URL) throws -> [(name: String, data: Data)] {
        let directory = root.appendingPathComponent("Tasks")
        guard let source = try HostCoreStateSource(directory: directory) else { return [] }
        let names = try source.names().filter { $0.hasSuffix(".json") }
        var entries: [(name: String, data: Data, task: PersistedHostAgentTask)] = []
        var totalBytes = 0
        for name in names {
            guard let id = UUID(uuidString: String(name.dropLast(5))) else { throw invalid() }
            let data = try source.read(name, maximumBytes: 17 << 20)
            totalBytes += data.count
            guard totalBytes <= 64 << 20 else { throw invalid() }
            let entry = try HostAgentPayload.decode(PersistedHostAgentTask.self, from: data)
            let status = entry.status
            guard status.snapshot.id == id, status.snapshot.operation.count <= 160,
                status.snapshot.title.count <= 160, (status.snapshot.failure?.count ?? 0) <= 2000,
                (status.snapshot.failureCode?.count ?? 0) <= 160,
                (status.snapshot.lastActivity?.count ?? 0) <= 1000,
                (status.result?.count ?? 0) <= 8 << 20, status.output.count <= 128,
                status.output.allSatisfy({ $0.text.count <= 1000 })
            else { throw invalid() }
            entries.append(("\(id.uuidString).json", data, entry))
        }
        guard Set(entries.map(\.name)).count == entries.count else { throw invalid() }
        entries.sort { $0.task.status.snapshot.submittedAt > $1.task.status.snapshot.submittedAt }
        var retainedBytes = 0
        var retained: [(name: String, data: Data)] = []
        let now = Date()
        for entry in entries {
            let status = entry.task.status
            let bytes = status.result?.count ?? 0
            guard retained.count < 100, retainedBytes + bytes <= 16 << 20,
                !status.snapshot.state.isTerminal
                    || now.timeIntervalSince(
                        status.snapshot.finishedAt ?? status.snapshot.submittedAt) <= 86_400
            else { continue }
            retainedBytes += bytes
            retained.append((entry.name, entry.data))
        }
        return retained
    }

    nonisolated static func invalid(_ stage: String = "validation") -> HostAgentCommandError {
        HostAgentCommandError(
            .refused,
            "Existing task or schedule history could not be imported safely (\(stage)). The original files were left intact."
        )
    }
}

final class HostCoreStateSource {
    private let descriptor: Int32
    private let directory: URL
    private let device: dev_t
    private let inode: ino_t

    init?(directory: URL) throws {
        self.directory = directory.standardizedFileURL
        guard self.directory == self.directory.resolvingSymlinksInPath() else {
            throw HostCoreStateMigration.invalid("source validation")
        }
        descriptor = open(self.directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw HostCoreStateMigration.invalid("source validation")
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_uid == geteuid(),
            status.st_mode & 0o022 == 0
        else {
            close(descriptor)
            throw HostCoreStateMigration.invalid("source validation")
        }
        device = status.st_dev
        inode = status.st_ino
    }

    deinit { close(descriptor) }

    func contains(_ name: String) throws -> Bool {
        try validateDirectory()
        var status = stat()
        if fstatat(descriptor, name, &status, AT_SYMLINK_NOFOLLOW) == 0 { return true }
        guard errno == ENOENT else { throw HostCoreStateMigration.invalid("source validation") }
        return false
    }

    func names() throws -> [String] {
        try validateDirectory()
        let duplicate = dup(descriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { close(duplicate) }
            throw HostCoreStateMigration.invalid("source validation")
        }
        defer { closedir(stream) }
        var names: [String] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            guard names.count < HostAgentJournal.maximumFiles else {
                throw HostCoreStateMigration.invalid("source validation")
            }
            names.append(name)
        }
        try validateDirectory()
        return names
    }

    func read(_ name: String, maximumBytes: Int) throws -> Data {
        let file = try openFile(name, maximumBytes: maximumBytes)
        defer { close(file.descriptor) }
        let handle = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        guard data.count == file.metadata.st_size else {
            throw HostCoreStateMigration.invalid("source validation")
        }
        try validate(file, name: name)
        return data
    }

    func copy(_ name: String, to destination: URL, maximumBytes: Int) throws -> stat {
        let file = try openFile(name, maximumBytes: maximumBytes)
        defer { close(file.descriptor) }
        let output = open(
            destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw HostCoreStateMigration.invalid("source validation") }
        defer { close(output) }
        let reader = FileHandle(fileDescriptor: file.descriptor, closeOnDealloc: false)
        let writer = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        var copied = 0
        while let data = try reader.read(upToCount: 1 << 20), !data.isEmpty {
            copied += data.count
            guard copied <= maximumBytes else {
                throw HostCoreStateMigration.invalid("source validation")
            }
            try writer.write(contentsOf: data)
        }
        guard copied == file.metadata.st_size else {
            throw HostCoreStateMigration.invalid("source validation")
        }
        try validate(file, name: name)
        return file.metadata
    }

    func validate(_ metadata: stat, name: String) throws {
        try validateDirectory()
        var current = stat()
        guard fstatat(descriptor, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
            Self.same(metadata, current)
        else { throw HostCoreStateMigration.invalid("source validation") }
    }

    private func validate(_ file: (descriptor: Int32, metadata: stat), name: String) throws {
        var after = stat()
        guard fstat(file.descriptor, &after) == 0, Self.same(file.metadata, after) else {
            throw HostCoreStateMigration.invalid("source validation")
        }
        try validate(file.metadata, name: name)
    }

    private func openFile(_ name: String, maximumBytes: Int) throws -> (
        descriptor: Int32, metadata: stat
    ) {
        try validateDirectory()
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0)
        else {
            throw HostCoreStateMigration.invalid("source validation")
        }
        let file = openat(descriptor, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { throw HostCoreStateMigration.invalid("source validation") }
        var status = stat()
        guard fstat(file, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            status.st_uid == geteuid(), status.st_nlink == 1, status.st_mode & 0o022 == 0,
            status.st_size >= 0, status.st_size <= maximumBytes
        else {
            close(file)
            throw HostCoreStateMigration.invalid("source validation")
        }
        return (file, status)
    }

    private func validateDirectory() throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0, status.st_mode & S_IFMT == S_IFDIR,
            status.st_dev == device, status.st_ino == inode, status.st_uid == geteuid(),
            status.st_mode & 0o022 == 0
        else {
            throw HostCoreStateMigration.invalid("source directory changed")
        }
    }

    private static func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_size == rhs.st_size
            && lhs.st_uid == rhs.st_uid && lhs.st_mode == rhs.st_mode && rhs.st_nlink == 1
            && lhs.st_mtimespec.tv_sec == rhs.st_mtimespec.tv_sec
            && lhs.st_mtimespec.tv_nsec == rhs.st_mtimespec.tv_nsec
            && lhs.st_ctimespec.tv_sec == rhs.st_ctimespec.tv_sec
            && lhs.st_ctimespec.tv_nsec == rhs.st_ctimespec.tv_nsec
    }
}
