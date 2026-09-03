import EdithKit
import Foundation
import GRDB

public struct BackupSnapshotResult: Codable, Equatable, Sendable {
    public let ranAt: Date
    public let classes: [String]
    public let snapshotTables: [String]
    public let skipped: Bool

    public init(ranAt: Date, classes: [String], snapshotTables: [String], skipped: Bool) {
        self.ranAt = ranAt
        self.classes = classes
        self.snapshotTables = snapshotTables
        self.skipped = skipped
    }
}

public enum BackupSnapshotTables {
    public static let synced = ["usage_day", "limits_sample", "attention_event"]

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

    public init(
        store: AgentStore?, cloudDirectory: URL = AppData.cloudDir,
        fileManager: FileManager = .default, defaults: UserDefaults = SharedDefaults.store
    ) {
        self.store = store
        self.cloudDirectory = cloudDirectory
        self.fileManager = fileManager
        self.defaults = defaults
    }

    public func run() async throws -> Data? {
        let now = Date()
        let enabled = BackupCatalog.enabled(in: defaults)
        guard !enabled.isEmpty, AppData.cloudAvailable else {
            return try AgentPayload.encode(
                BackupSnapshotResult(
                    ranAt: now, classes: [], snapshotTables: [], skipped: true))
        }
        let lastSnapshot = defaults.object(forKey: AppStorageKeys.Backup.lastBackupAt) as? Date
        var written: [String] = []
        if BackupCadence.shouldSnapshot(lastSnapshot: lastSnapshot, now: now) {
            written = writeSnapshots(now: now)
            defaults.set(now, forKey: AppStorageKeys.Backup.lastBackupAt)
        }
        return try AgentPayload.encode(
            BackupSnapshotResult(
                ranAt: now, classes: enabled.map(\.id), snapshotTables: written, skipped: false))
    }

    private func writeSnapshots(now: Date) -> [String] {
        guard let store else { return [] }
        let directory = cloudDirectory.appendingPathComponent("snapshots")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var written: [String] = []
        for table in BackupSnapshotTables.synced {
            guard let lines = try? rows(in: table), !lines.isEmpty else { continue }
            let target = directory.appendingPathComponent(
                BackupSnapshotTables.fileName(table: table, day: now))
            let document = lines.joined(separator: "\n")
            guard
                (try? document.write(to: target, atomically: true, encoding: .utf8)) != nil
            else { continue }
            written.append(table)
        }
        return written
    }

    private func rows(in table: String) throws -> [String] {
        guard let store else { return [] }
        return try store.read { database in
            try Row.fetchAll(database, sql: "SELECT * FROM \(table)")
                .compactMap { row in
                    let object = BackupRowEncoder.object(from: row)
                    guard
                        let data = try? JSONSerialization.data(
                            withJSONObject: object, options: [.sortedKeys])
                    else { return nil }
                    return String(data: data, encoding: .utf8)
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
