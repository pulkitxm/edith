import EdithCore
import Foundation

public enum BackupSync: String, Codable, Sendable {
    case always
    case optIn
    case never

    public var title: String {
        switch self {
        case .always: "Always"
        case .optIn: "Opt in"
        case .never: "Never"
        }
    }
}

public enum BackupMerge: String, Codable, Sendable {
    case newestPerKey
    case unionByID
    case unionByPrimaryKey
    case unionByHash
    case newestFile
    case missingFiles
    case replaceSnapshot
    case notApplicable

    public var title: String {
        switch self {
        case .newestPerKey: "Newest wins per key, device stamped"
        case .unionByID: "Union by id"
        case .unionByPrimaryKey: "Union by primary key"
        case .unionByHash: "Union by content hash"
        case .newestFile: "Newest file wins"
        case .missingFiles: "Restore missing files"
        case .replaceSnapshot: "Replace with saved snapshot"
        case .notApplicable: "Not restored"
        }
    }
}

public struct BackupClass: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let location: String
    public let sync: BackupSync
    public let merge: BackupMerge
    public let retention: String
    public let defaultsKey: String?
    public let carriesSecrets: Bool

    public init(
        id: String, title: String, location: String, sync: BackupSync, merge: BackupMerge,
        retention: String, defaultsKey: String? = nil, carriesSecrets: Bool = false
    ) {
        self.id = id
        self.title = title
        self.location = location
        self.sync = sync
        self.merge = merge
        self.retention = retention
        self.defaultsKey = defaultsKey
        self.carriesSecrets = carriesSecrets
    }

    public func isEnabled(in defaults: UserDefaults, attentionBackupEnabled: Bool = false) -> Bool {
        switch sync {
        case .never: return false
        case .always:
            guard defaults.bool(forKey: AppStorageKeys.Backup.icloud) else { return false }
            guard let defaultsKey else { return true }
            return defaults.object(forKey: defaultsKey) as? Bool ?? true
        case .optIn:
            guard defaults.bool(forKey: AppStorageKeys.Backup.icloud) else { return false }
            if id == "attention" { return attentionBackupEnabled }
            guard let defaultsKey else { return false }
            return defaults.bool(forKey: defaultsKey)
        }
    }
}

public enum BackupCatalog {
    public static let classes: [BackupClass] = [
        BackupClass(
            id: "settings", title: "Settings and suite selection",
            location: "defaults suite, exported to settings.json", sync: .always,
            merge: .newestFile, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.settings),
        BackupClass(
            id: "machines", title: "Machines, forwards, snippets", location: "machines/*.json",
            sync: .never, merge: .notApplicable, retention: "Until deleted"),
        BackupClass(
            id: "database", title: "Database connections", location: "database/metadata.sqlite3",
            sync: .never, merge: .notApplicable, retention: "Until deleted"),
        BackupClass(
            id: "usage", title: "Usage days and sessions", location: "data/usage.json",
            sync: .always, merge: .unionByPrimaryKey, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.usage),
        BackupClass(
            id: "limits", title: "Provider limits", location: "data/limits-history.jsonl",
            sync: .always, merge: .unionByPrimaryKey, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.limits),
        BackupClass(
            id: "attention", title: "Attention events", location: "attention/", sync: .optIn,
            merge: .replaceSnapshot, retention: "365 days"),
        BackupClass(
            id: "clipboard", title: "Clipboard history", location: "clipboard/", sync: .optIn,
            merge: .unionByHash, retention: "Configured retention",
            defaultsKey: AppStorageKeys.Clipboard.backup),
        BackupClass(
            id: "music", title: "Music library",
            location: "Selected music folder", sync: .optIn, merge: .missingFiles,
            retention: "Forever", defaultsKey: AppStorageKeys.Music.backup),
        BackupClass(
            id: "metrics", title: "Machine metrics, cleaner scans, update cache",
            location: "edith.sqlite", sync: .never, merge: .notApplicable,
            retention: "24h ring, 7d, 6h"),
        BackupClass(
            id: "memories", title: "Companion memories", location: "Postgres on the host",
            sync: .never, merge: .notApplicable, retention: "Service policy"),
    ]

    public static func classes(in defaults: UserDefaults = SharedDefaults.store) -> [BackupClass] {
        classes
    }

    public static func enabled(
        in defaults: UserDefaults = SharedDefaults.store, attentionBackupEnabled: Bool = false
    ) -> [BackupClass] {
        classes.filter {
            $0.isEnabled(in: defaults, attentionBackupEnabled: attentionBackupEnabled)
        }
    }

    public static func byID(_ id: String) -> BackupClass? {
        classes.first { $0.id == id }
    }
}

public enum BackupCadence {
    public static let debounce: TimeInterval = 60
    public static let snapshotInterval: TimeInterval = 24 * 60 * 60

    public static func shouldSnapshot(
        lastSnapshot: Date?, now: Date, interval: TimeInterval = snapshotInterval
    ) -> Bool {
        guard let lastSnapshot else { return true }
        return now.timeIntervalSince(lastSnapshot) >= interval
    }

    public static func nextRun(after change: Date, now: Date) -> TimeInterval {
        max(0, debounce - now.timeIntervalSince(change))
    }
}

public struct BackupFootprint: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let url: URL
    public let bytes: Int64
    public let exists: Bool

    public init(id: String, title: String, url: URL, bytes: Int64, exists: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.bytes = bytes
        self.exists = exists
    }
}
