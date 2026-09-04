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
    case notApplicable

    public var title: String {
        switch self {
        case .newestPerKey: "Newest wins per key, device stamped"
        case .unionByID: "Union by id"
        case .unionByPrimaryKey: "Union by primary key"
        case .unionByHash: "Union by content hash"
        case .newestFile: "Newest file wins"
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
            merge: .newestPerKey, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.settings),
        BackupClass(
            id: "machines", title: "Machines, forwards, snippets", location: "machines/*.json",
            sync: .always, merge: .unionByID, retention: "Forever", carriesSecrets: true),
        BackupClass(
            id: "database", title: "Database connections", location: "edith.sqlite",
            sync: .always, merge: .unionByID, retention: "Forever", carriesSecrets: true),
        BackupClass(
            id: "usage", title: "Usage days and sessions", location: "edith.sqlite",
            sync: .always, merge: .unionByPrimaryKey, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.usage),
        BackupClass(
            id: "limits", title: "Provider limits", location: "edith.sqlite",
            sync: .always, merge: .unionByPrimaryKey, retention: "Forever",
            defaultsKey: AppStorageKeys.Backup.limits),
        BackupClass(
            id: "attention", title: "Attention events", location: "edith.sqlite", sync: .optIn,
            merge: .unionByPrimaryKey, retention: "365 days"),
        BackupClass(
            id: "clipboard", title: "Clipboard history", location: "clipboard/", sync: .optIn,
            merge: .unionByHash, retention: "200 items or 30 days",
            defaultsKey: AppStorageKeys.Clipboard.backup),
        BackupClass(
            id: "music", title: "Music library and download queue",
            location: "music/, queue in edith.sqlite", sync: .optIn, merge: .newestFile,
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

public struct BackupFootprint: Identifiable, Equatable, Sendable {
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

public enum BackupFootprintReader {
    public static func entries(fileManager: FileManager = .default) -> [BackupFootprint] {
        let targets: [(String, String, URL)] = [
            ("store", "Store", AppData.supportDir.appendingPathComponent("edith.sqlite")),
            ("machines", "Machines", DataRoot.machines),
            ("clipboard", "Clipboard", DataRoot.clipboard),
            ("seo", "Site audits", DataRoot.siteAudit),
            ("usage", "Usage files", DataRoot.usage),
            ("music", "Music", Repo.musicDir),
            ("caches", "Caches", DataRoot.caches),
            ("logs", "Logs", DataRoot.logs),
        ]
        return targets.map { id, title, url in
            BackupFootprint(
                id: id, title: title, url: url, bytes: size(of: url, fileManager: fileManager),
                exists: fileManager.fileExists(atPath: url.path))
        }
    }

    public static func size(of url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            let attributes = try? fileManager.attributesOfItem(atPath: url.path)
            return (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        guard
            let enumerator = fileManager.enumerator(
                at: url, includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles])
        else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }
}
