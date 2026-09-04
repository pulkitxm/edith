import Darwin
import EdithKit
import Foundation
import GRDB

public enum BackupSnapshotTables {
    public static let synced = ["usage_day", "limits_sample", "attention_event"]
    public static let timestampKey = "backupLastSnapshotAt"

    public static func fileName(table: String, day: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: day)
        let stamp = String(
            format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0,
            components.day ?? 0)
        return "\(table)-\(stamp).jsonl"
    }
}

public final class BackupJob: @unchecked Sendable {
    private let store: AgentStore?
    private let cloudDirectory: URL
    private let fileManager: FileManager
    private let defaults: UserDefaults
    private let cloudAvailable: @Sendable () -> Bool
    private let attentionBackupEnabled: @Sendable () -> Bool

    public init(
        store: AgentStore?, cloudDirectory: URL = AppData.cloudDir,
        fileManager: FileManager = .default, defaults: UserDefaults = SharedDefaults.store,
        cloudAvailable: @escaping @Sendable () -> Bool = { AppData.cloudAvailable },
        attentionBackupEnabled: @escaping @Sendable () -> Bool = {
            AttentionRepository().loadSettings().iCloudBackupEnabled
        }
    ) {
        self.store = store
        self.cloudDirectory = cloudDirectory
        self.fileManager = fileManager
        self.defaults = defaults
        self.cloudAvailable = cloudAvailable
        self.attentionBackupEnabled = attentionBackupEnabled
    }

    public func run(now: Date = Date()) async throws -> Data? {
        let enabled = BackupCatalog.enabled(
            in: defaults, attentionBackupEnabled: attentionBackupEnabled())
        guard !enabled.isEmpty, cloudAvailable() else {
            return try AgentPayload.encode(
                BackupSnapshotResult(
                    ranAt: now, classes: [], snapshotTables: [], skipped: true))
        }
        let classes = Set(enabled.map(\.id))
        let tables = [
            ("usage", "usage_day"), ("limits", "limits_sample"), ("attention", "attention_event"),
        ]
        .compactMap { classes.contains($0.0) ? $0.1 : nil }
        let due = tables.filter { table in
            let lastSnapshot =
                (defaults.object(forKey: "\(BackupSnapshotTables.timestampKey).\(table)")
                as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return BackupCadence.shouldSnapshot(lastSnapshot: lastSnapshot, now: now)
        }
        if !due.isEmpty {
            try writeSnapshots(tables: due, now: now)
            for table in due {
                defaults.set(
                    now.timeIntervalSince1970,
                    forKey: "\(BackupSnapshotTables.timestampKey).\(table)")
            }
            defaults.set(now.timeIntervalSince1970, forKey: BackupSnapshotTables.timestampKey)
        }
        return try AgentPayload.encode(
            BackupSnapshotResult(
                ranAt: now, classes: enabled.map(\.id), snapshotTables: due, skipped: false))
    }

    private func writeSnapshots(tables: [String], now: Date) throws {
        guard let store else { throw AgentStoreError("The backup store is unavailable.") }
        let directory = cloudDirectory.appendingPathComponent("snapshots")
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        for table in tables {
            try Task.checkCancellation()
            let target = directory.appendingPathComponent(
                BackupSnapshotTables.fileName(table: table, day: now))
            let temporary = directory.appendingPathComponent(".\(UUID().uuidString).jsonl")
            guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
                throw AgentStoreError("The backup snapshot could not be created.")
            }
            defer { try? fileManager.removeItem(at: temporary) }
            let handle = try FileHandle(forWritingTo: temporary)
            defer { try? handle.close() }
            try store.read { database in
                let rows = try Row.fetchCursor(database, sql: "SELECT * FROM \(table)")
                while let row = try rows.next() {
                    try Task.checkCancellation()
                    let data = try JSONSerialization.data(
                        withJSONObject: BackupRowEncoder.object(from: row), options: [.sortedKeys])
                    try handle.write(contentsOf: data)
                    try handle.write(contentsOf: Data([0x0A]))
                }
            }
            try handle.synchronize()
            try handle.close()
            guard rename(temporary.path, target.path) == 0 else {
                throw AgentStoreError("The backup snapshot could not be published.")
            }
        }
    }
}

enum BackupRowEncoder {
    static func object(from row: Row) -> [String: Any] {
        var object: [String: Any] = [:]
        for (name, value) in row {
            switch value.storage {
            case let .int64(number): object[name] = number
            case let .double(number): object[name] = number
            case let .string(text): object[name] = text
            case let .blob(data): object[name] = data.base64EncodedString()
            case .null: continue
            }
        }
        return object
    }
}
