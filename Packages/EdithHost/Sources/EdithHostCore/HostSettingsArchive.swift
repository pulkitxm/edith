import Darwin
import EdithExtensionSupport
import Foundation

public struct HostSettingsBackupResult: Codable, Sendable {
    public let restored: Bool
    public let exported: Bool
    public let suggestedExtensionIDs: [String]
    public let completedAt: Date
}

@MainActor public final class HostSettingsArchive {
    public nonisolated static let maximumBytes = 1_048_576
    private let identity: HostIdentity
    private let extensionIDs: Set<String>
    private let application: UserDefaults
    private let domains: [String: (String, UserDefaults)]
    private let cloud: URL
    private let local: URL
    private var work: Task<Transfer, Error>?
    private var coordination: HostSettingsCoordination?
    private var stopping = false

    public init(identity: HostIdentity, cloudDirectory: URL) throws {
        self.identity = identity
        extensionIDs = Set(try HostIndex.bundled().map(\.id))
        guard let application = SharedDefaults.applicationStore(identifier: identity.identifier)
        else { throw HostWorkerError.rejected }
        self.application = application
        var domains = ["application": (identity.identifier, application)]
        for id in extensionIDs {
            let name = identity.extensionDefaultsSuite(id)
            guard let defaults = UserDefaults(suiteName: name) else {
                throw HostWorkerError.rejected
            }
            domains[id] = (name, defaults)
        }
        self.domains = domains
        cloud = cloudDirectory.appendingPathComponent("settings.json")
        local = identity.root.appendingPathComponent("Core/settings.json")
    }

    public func synchronize(restoreOnly: Bool = false) async throws -> HostSettingsBackupResult {
        try Task.checkCancellation()
        guard !stopping, work == nil else { throw HostWorkerError.rejected }
        if !restoreOnly,
            !(application.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true
                && application.object(forKey: AppStorageKeys.Backup.settings) as? Bool ?? true)
        {
            return HostSettingsBackupResult(
                restored: false, exported: false, suggestedExtensionIDs: [], completedAt: Date())
        }
        let current = try capture()
        let coordination = HostSettingsCoordination()
        self.coordination = coordination
        let local = local, cloud = cloud, extensionIDs = extensionIDs
        let work = Task.detached(priority: .utility) {
            try Self.transfer(
                current: current, local: local, cloud: cloud,
                extensionIDs: extensionIDs, restoreOnly: restoreOnly, coordination: coordination)
        }
        self.work = work
        defer { self.work = nil; self.coordination = nil }
        let transfer = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            coordination.cancel(); work.cancel()
        }
        try Task.checkCancellation()
        guard !stopping, try capture() == current else { throw HostWorkerError.rejected }
        if transfer.restored {
            let restored = try HostSettingsDocument.decode(
                transfer.data, extensionIDs: extensionIDs)
            for (id, values) in restored.preferences {
                guard let defaults = domains[id]?.1 else { throw HostWorkerError.rejected }
                for (key, value) in values {
                    if ["cleanerSelectedDrives", "cleanerCustomFolders"].contains(key) {
                        guard let paths = value.value as? [String] else {
                            throw HostWorkerError.rejected
                        }
                        defaults.set(
                            paths.filter { RestoredPathValidation.verdict(for: $0) == .keep },
                            forKey: key)
                    } else {
                        defaults.set(value.value, forKey: key)
                    }
                }
            }
        }
        try HostCoreFiles.write(transfer.data, to: local)
        let completed = Date()
        if transfer.exported {
            application.set(
                completed.timeIntervalSince1970, forKey: AppStorageKeys.Backup.lastBackupAt)
        }
        return HostSettingsBackupResult(
            restored: transfer.restored, exported: transfer.exported,
            suggestedExtensionIDs: transfer.enabledIDs, completedAt: completed)
    }

    public func capture() throws -> Data {
        var preferences: [String: [String: HostSettingsValue]] = [:]
        for (id, (name, defaults)) in domains {
            let values = (defaults.persistentDomain(forName: name) ?? [:])
                .filter { HostSettingsCatalog.keys.contains($0.key) }
            if !values.isEmpty {
                preferences[id] = try values.mapValues { try HostSettingsValue($0) }
            }
        }
        let enabled =
            UserDefaults(suiteName: identity.defaultsSuite)?
            .stringArray(forKey: HostExtensionSessions.enabledExtensionsKey) ?? []
        let document = HostSettingsDocument(
            version: 1, preferences: preferences,
            enabledIDs: Set(enabled).intersection(extensionIDs).sorted())
        return try document.encoded()
    }

    public func cancel() { coordination?.cancel(); work?.cancel() }

    public func shutdown() async {
        stopping = true; cancel(); _ = try? await work?.value
    }

    private struct Transfer: Sendable {
        let data: Data
        let restored: Bool
        let exported: Bool
        let enabledIDs: [String]
    }

    private nonisolated static func transfer(
        current: Data, local: URL, cloud: URL, extensionIDs: Set<String>, restoreOnly: Bool,
        coordination: HostSettingsCoordination
    ) throws -> Transfer {
        try Task.checkCancellation()
        let directory = cloud.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            guard !restoreOnly else { throw CocoaError(.fileNoSuchFile) }
            try directoryGuard(directory.deletingLastPathComponent())
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: false)
        }
        try directoryGuard(directory)
        try directoryGuard(local.deletingLastPathComponent())
        if try read(cloud) == nil {
            let placeholder = directory.appendingPathComponent(".settings.json.icloud")
            var metadata = stat()
            if lstat(placeholder.path, &metadata) == 0 {
                try? FileManager.default.startDownloadingUbiquitousItem(at: cloud)
                throw HostWorkerError.rejected
            }
        }
        var result: Result<Transfer, Error>?
        var error: NSError?
        let coordinator = NSFileCoordinator(filePresenter: nil)
        try coordination.register(coordinator)
        defer { coordination.remove(coordinator) }
        coordinator.coordinate(writingItemAt: cloud, options: .forMerging, error: &error) {
            coordinated in
            result = Result {
                try Task.checkCancellation()
                guard !coordination.cancelled else { throw CancellationError() }
                let previous = try read(local)
                let remote = try read(coordinated)
                if let previous {
                    _ = try HostSettingsDocument.decode(previous.0, extensionIDs: extensionIDs)
                }
                let remoteDocument = try remote.map {
                    try HostSettingsDocument.decode($0.0, extensionIDs: extensionIDs)
                }
                guard !restoreOnly || remote != nil else { throw CocoaError(.fileNoSuchFile) }
                let newer =
                    remote.map { $0.1 > (previous?.1 ?? .distantPast).addingTimeInterval(2) }
                    ?? false
                let restore =
                    remote != nil
                    && (restoreOnly || (newer && (previous == nil || previous?.0 == current)))
                let selected = restore ? remote!.0 : current
                try Task.checkCancellation()
                guard !coordination.cancelled else { throw CancellationError() }
                let exported = !restoreOnly && remote?.0 != selected
                if exported {
                    try Task.checkCancellation()
                    guard !coordination.cancelled else { throw CancellationError() }
                    try HostCoreFiles.write(selected, to: coordinated)
                }
                return Transfer(
                    data: selected, restored: restore && selected != current,
                    exported: exported, enabledIDs: restore ? remoteDocument?.enabledIDs ?? [] : [])
            }
        }
        if let error { throw error }
        guard let result else { throw HostWorkerError.rejected }
        return try result.get()
    }

    private nonisolated static func read(_ url: URL) throws -> (Data, Date)? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw CocoaError(.fileReadNoPermission)
        }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_uid == getuid(), before.st_nlink == 1,
            before.st_size >= 0, before.st_size <= maximumBytes
        else { throw HostWorkerError.rejected }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw CocoaError(.fileReadUnknown) }
            if count == 0 { break }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= maximumBytes else { throw HostWorkerError.rejected }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, after.st_size == before.st_size,
            data.count == before.st_size,
            after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
            after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
            after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
            after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec
        else { throw HostWorkerError.rejected }
        return (
            data,
            Date(
                timeIntervalSince1970: Double(before.st_mtimespec.tv_sec) + Double(
                    before.st_mtimespec.tv_nsec) / 1e9)
        )
    }

    private nonisolated static func directoryGuard(_ url: URL) throws {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == getuid()
        else { throw CocoaError(.fileReadNoPermission) }
    }
}

private final class HostSettingsCoordination: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinators: [NSFileCoordinator] = []
    private var stopping = false
    var cancelled: Bool { lock.withLock { stopping } }

    func register(_ coordinator: NSFileCoordinator) throws {
        try lock.withLock {
            guard !stopping else { throw CancellationError() }
            coordinators.append(coordinator)
        }
    }

    func remove(_ coordinator: NSFileCoordinator) {
        lock.withLock { coordinators.removeAll { $0 === coordinator } }
    }

    func cancel() {
        let current = lock.withLock {
            stopping = true; return coordinators
        }
        for coordinator in current { coordinator.cancel() }
    }
}
