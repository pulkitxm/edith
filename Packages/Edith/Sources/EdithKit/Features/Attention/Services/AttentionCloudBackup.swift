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
        try manager.createDirectory(at: cloudDirectory, withIntermediateDirectories: true)
        try copyTree(from: localDirectory, to: cloudDirectory, skippingLock: true)
        try manager.setAttributes([.modificationDate: now], ofItemAtPath: cloudDirectory.path)
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
        try copyTree(from: cloudDirectory, to: localDirectory, skippingLock: true)
    }

    private func copyTree(from source: URL, to destination: URL, skippingLock: Bool) throws {
        let manager = FileManager.default
        guard manager.fileExists(atPath: source.path) else { return }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let items = try manager.contentsOfDirectory(
            at: source,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles])
        for item in items {
            if skippingLock, item.lastPathComponent == ".lock" { continue }
            let target = destination.appendingPathComponent(item.lastPathComponent)
            let values = try item.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                try copyTree(from: item, to: target, skippingLock: skippingLock)
            } else if values.isRegularFile == true {
                try Data(contentsOf: item).write(to: target, options: .atomic)
            }
        }
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
