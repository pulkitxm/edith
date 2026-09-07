import Foundation

public struct AttentionCloudBackup: Sendable {
    public let localDirectory: URL
    public let cloudDirectory: URL

    public init(
        localDirectory: URL = AttentionPaths.directory,
        cloudDirectory: URL = AppData.cloudDir.appendingPathComponent("Attention")
    ) {
        self.localDirectory = localDirectory
        self.cloudDirectory = cloudDirectory
    }

    public var available: Bool {
        FileManager.default.fileExists(atPath: cloudDirectory.path)
    }

    public var lastBackupAt: Date? {
        try? cloudDirectory.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate
    }

    @discardableResult
    public func backup(now: Date = Date()) throws -> Date {
        let manager = FileManager.default
        let publication = try AttentionArchivePublication(
            source: localDirectory, destination: cloudDirectory)
        try publication.publish()
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: cloudDirectory.path)
        publication.finish()
        return now
    }

    public func restoreWhenLocalStoreIsEmpty() throws {
        guard available else { throw AttentionCloudBackupError.noBackup }
        let localEvents = localDirectory.appendingPathComponent("events")
        let eventFiles =
            (try? FileManager.default.contentsOfDirectory(atPath: localEvents.path)) ?? []
        guard !eventFiles.contains(where: { $0.hasSuffix(".jsonl") }) else {
            throw AttentionCloudBackupError.localStoreNotEmpty
        }
        try FileManager.default.createDirectory(
            at: localDirectory, withIntermediateDirectories: true)
        try AttentionArchiveCopy.copy(from: cloudDirectory, to: localDirectory)
    }
}

public enum AttentionCloudBackupError: LocalizedError, Equatable {
    case noBackup
    case localStoreNotEmpty

    public var errorDescription: String? {
        switch self {
        case .noBackup: return "No Attention backup is available in iCloud Drive."
        case .localStoreNotEmpty:
            return "Restore is available only before this Mac has recorded attention events."
        }
    }
}
