import EdithKit
import Foundation
import GRDB

public struct AgentStoreError: LocalizedError, Equatable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum AgentStoreLayout {
    public static let fileName = "edith.sqlite"
    public static let backupRetention: TimeInterval = 30 * 24 * 60 * 60

    public static func storeURL(root: URL = AppData.supportDir) -> URL {
        root.appendingPathComponent(fileName)
    }

    public static func backupURL(root: URL = AppData.supportDir, build: String) -> URL {
        root.appendingPathComponent("\(fileName).pre-\(build)")
    }

    public static func expiredBackups(
        in names: [String], now: Date, ages: [String: Date]
    ) -> [String] {
        names.filter { name in
            guard name.hasPrefix("\(fileName).pre-"), let created = ages[name] else { return false }
            return now.timeIntervalSince(created) > backupRetention
        }
    }
}

public enum AgentSchema {
    public static let version = 1

    public static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("0001-foundations") { database in
            try database.create(table: "usage_day") { table in
                table.primaryKey("day", .text)
                table.column("source", .text).notNull()
                table.column("costCents", .integer).notNull().defaults(to: 0)
                table.column("inputTokens", .integer).notNull().defaults(to: 0)
                table.column("outputTokens", .integer).notNull().defaults(to: 0)
                table.column("updatedAt", .datetime).notNull()
            }
            try database.create(table: "limits_sample") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("provider", .text).notNull()
                table.column("capturedAt", .datetime).notNull().indexed()
                table.column("sessionPercent", .double)
                table.column("weeklyPercent", .double)
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "session_snapshot") { table in
                table.primaryKey("id", .text)
                table.column("machine", .text).notNull().indexed()
                table.column("capturedAt", .datetime).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "machine_metric") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("machine", .text).notNull().indexed()
                table.column("capturedAt", .datetime).notNull().indexed()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "update_candidate") { table in
                table.primaryKey("id", .text)
                table.column("source", .text).notNull()
                table.column("checkedAt", .datetime).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "cleaner_scan") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("reclaimableBytes", .integer).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "download_item") { table in
                table.primaryKey("id", .text)
                table.column("queuedAt", .datetime).notNull().indexed()
                table.column("status", .text).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "attention_event") { table in
                table.primaryKey("id", .text)
                table.column("startedAt", .datetime).notNull().indexed()
                table.column("kind", .text).notNull()
                table.column("payload", .blob).notNull()
            }
            try database.create(table: "job_run") { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("job", .text).notNull().indexed()
                table.column("startedAt", .datetime).notNull()
                table.column("duration", .double).notNull()
                table.column("failure", .text)
            }
        }
        return migrator
    }
}

public final class AgentStore: @unchecked Sendable {
    public let url: URL
    private let pool: DatabasePool

    public init(url: URL, build: String, fileManager: FileManager = .default) throws {
        self.url = url
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let preexisting = fileManager.fileExists(atPath: url.path)
        var configuration = Configuration()
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA journal_mode = WAL")
            try database.execute(sql: "PRAGMA foreign_keys = ON")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try Self.refuseNewerSchema(pool)
        if preexisting, try Self.needsMigration(pool) {
            try Self.copyBeforeMigrating(url: url, build: build, fileManager: fileManager)
        }
        try AgentSchema.migrator.migrate(pool)
        try Self.stampVersion(pool)
        Self.pruneBackups(root: url.deletingLastPathComponent(), fileManager: fileManager)
    }

    public var schemaVersion: Int {
        (try? pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }) ?? 0
    }

    public func read<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.read(body)
    }

    @discardableResult
    public func write<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.write(body)
    }

    public func close() throws {
        try pool.close()
    }

    private static func needsMigration(_ pool: DatabasePool) throws -> Bool {
        try pool.read { database in
            try !AgentSchema.migrator.hasCompletedMigrations(database)
        }
    }

    private static func refuseNewerSchema(_ pool: DatabasePool) throws {
        let stored = try pool.read { try Int.fetchOne($0, sql: "PRAGMA user_version") ?? 0 }
        guard stored <= AgentSchema.version else {
            throw AgentStoreError(
                "The Edith store was written by a newer build (schema \(stored), this build "
                    + "understands \(AgentSchema.version)). Update Edith to open it.")
        }
    }

    private static func stampVersion(_ pool: DatabasePool) throws {
        try pool.write { database in
            try database.execute(sql: "PRAGMA user_version = \(AgentSchema.version)")
        }
    }

    private static func copyBeforeMigrating(
        url: URL, build: String, fileManager: FileManager
    ) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let backup = AgentStoreLayout.backupURL(
            root: url.deletingLastPathComponent(), build: build)
        if fileManager.fileExists(atPath: backup.path) {
            try fileManager.removeItem(at: backup)
        }
        try fileManager.copyItem(at: url, to: backup)
    }

    private static func pruneBackups(root: URL, fileManager: FileManager) {
        guard let names = try? fileManager.contentsOfDirectory(atPath: root.path) else { return }
        var ages: [String: Date] = [:]
        for name in names {
            let candidate = root.appendingPathComponent(name)
            guard
                let created = (try? fileManager.attributesOfItem(atPath: candidate.path))?[
                    .creationDate] as? Date
            else { continue }
            ages[name] = created
        }
        for name in AgentStoreLayout.expiredBackups(in: names, now: Date(), ages: ages) {
            try? fileManager.removeItem(at: root.appendingPathComponent(name))
        }
    }
}
