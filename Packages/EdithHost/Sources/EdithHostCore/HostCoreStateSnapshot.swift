import Darwin
import Foundation
import SQLite3

struct HostCoreStateSnapshot {
    var schedules: [HostAgentScheduleService.Entry] = []
    var events: [HostCoreAgentEvent] = []

    @MainActor static func read(
        source root: URL, temporaryParent: URL, schedules: Bool, events: Bool
    ) throws -> Self {
        guard schedules || events, let source = try HostCoreStateSource(directory: root),
            try source.contains("edith.sqlite")
        else { return Self() }
        let temporary = temporaryParent.appendingPathComponent(".state-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let database = temporary.appendingPathComponent("edith.sqlite")
        let hasWAL = try source.contains("edith.sqlite-wal")
        let original = try source.copy("edith.sqlite", to: database, maximumBytes: 512 << 20)
        var wal: stat?
        if hasWAL {
            wal = try source.copy(
                "edith.sqlite-wal", to: temporary.appendingPathComponent("edith.sqlite-wal"),
                maximumBytes: 512 << 20)
        }
        try source.validate(original, name: "edith.sqlite")
        if let wal { try source.validate(wal, name: "edith.sqlite-wal") }
        guard try source.contains("edith.sqlite-wal") == hasWAL else {
            throw HostCoreStateMigration.invalid("database changed")
        }
        guard let canonicalPath = realpath(database.path, nil) else {
            throw HostCoreStateMigration.invalid("database path")
        }
        defer { free(canonicalPath) }
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            canonicalPath, &handle,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard code == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw HostCoreStateMigration.invalid("database open \(code)")
        }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 500)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, 4 << 20)
        var budget = Budget(
            deadline: DispatchTime.now().uptimeNanoseconds + 5_000_000_000, remaining: 10_000)
        return try withUnsafeMutablePointer(to: &budget) { pointer in
            sqlite3_progress_handler(
                handle, 1000,
                { context in
                    guard let context else { return 1 }
                    let pointer = context.assumingMemoryBound(to: Budget.self)
                    pointer.pointee.remaining -= 1
                    return pointer.pointee.remaining <= 0
                        || DispatchTime.now().uptimeNanoseconds >= pointer.pointee.deadline ? 1 : 0
                }, pointer)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            guard
                sqlite3_exec(
                    handle, "PRAGMA trusted_schema=OFF; PRAGMA query_only=ON; BEGIN", nil, nil, nil)
                    == SQLITE_OK
            else {
                throw HostCoreStateMigration.invalid("database transaction")
            }
            defer { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil) }
            let version = try schemaVersion(handle)
            var result = Self()
            if schedules, version >= 6 { result.schedules = try readSchedules(handle) }
            if events, version >= 3 { result.events = try readEvents(handle) }
            return result
        }
    }

    private struct Budget {
        let deadline: UInt64
        var remaining: Int
    }

    private static func schemaVersion(_ database: OpaquePointer) throws -> Int {
        var userVersion: Int64?
        try rows(database, sql: "PRAGMA user_version") { statement in
            guard userVersion == nil, sqlite3_column_type(statement, 0) == SQLITE_INTEGER else {
                throw HostCoreStateMigration.invalid("schema version")
            }
            userVersion = sqlite3_column_int64(statement, 0)
        }
        guard let userVersion, (0...6).contains(userVersion) else {
            throw HostCoreStateMigration.invalid("schema version")
        }
        try requireTable("grdb_migrations", database: database)
        let known = [
            "0001-foundations", "0002-companion-health", "0003-agent-events",
            "0004-attention-delivery-receipts", "0005-attention-event-kind", "0006-scheduled-tasks",
        ]
        var migrations: [String] = []
        try rows(
            database, sql: "SELECT identifier FROM grdb_migrations ORDER BY identifier LIMIT 7"
        ) { statement in
            migrations.append(try string(statement, column: 0))
        }
        guard !migrations.isEmpty, migrations == Array(known.prefix(migrations.count)) else {
            throw HostCoreStateMigration.invalid("database migrations")
        }
        return migrations.count
    }

    private static func readSchedules(_ database: OpaquePointer) throws -> [HostAgentScheduleService
        .Entry]
    {
        try requireTable("scheduled_task", database: database)
        var result: [HostAgentScheduleService.Entry] = []
        try rows(
            database,
            sql: """
                SELECT id, name, definition, enabled,
                    (julianday(nextRunAt) - 2440587.5) * 86400.0,
                    (julianday(lastRunAt) - 2440587.5) * 86400.0,
                    lastTaskID, nextRunAt, lastRunAt
                FROM scheduled_task ORDER BY name LIMIT 65
                """
        ) { statement in
            guard result.count < 64, let id = UUID(uuidString: try string(statement, column: 0))
            else {
                throw HostCoreStateMigration.invalid("schedule identifiers")
            }
            let definition = try HostAgentPayload.decode(
                HostScheduledTaskDefinition.self,
                from: blob(statement, column: 2, maximumBytes: 1 << 20))
            try definition.validate()
            let enabled = sqlite3_column_int64(statement, 3)
            guard sqlite3_column_type(statement, 3) == SQLITE_INTEGER, enabled == 0 || enabled == 1,
                definition.name == (try string(statement, column: 1))
            else { throw HostCoreStateMigration.invalid("schedule definition") }
            let next = try date(statement, column: 4, original: 7)
            let last = try date(statement, column: 5, original: 8)
            var taskID: UUID?
            if sqlite3_column_type(statement, 6) != SQLITE_NULL {
                guard let value = UUID(uuidString: try string(statement, column: 6)) else {
                    throw HostCoreStateMigration.invalid("schedule task identifier")
                }
                taskID = value
            }
            result.append(
                .init(
                    id: id, definition: definition, enabled: enabled == 1,
                    nextRunAt: enabled == 1 ? next : nil, lastRunAt: last, lastTaskID: taskID))
        }
        guard Set(result.map(\.id)).count == result.count,
            Set(result.map(\.definition.name)).count == result.count
        else { throw HostCoreStateMigration.invalid("duplicate schedules") }
        return result
    }

    private static func readEvents(_ database: OpaquePointer) throws -> [HostCoreAgentEvent] {
        try requireTable("agent_event", database: database)
        var result: [HostCoreAgentEvent] = []
        try rows(database, sql: "SELECT payload FROM agent_event ORDER BY sequence DESC LIMIT 500")
        { statement in
            let event = try HostAgentPayload.decode(
                HostCoreAgentEvent.self, from: blob(statement, column: 0, maximumBytes: 32_768))
            guard event.category.count <= 80, event.name.count <= 160, event.message.count <= 2000,
                event.duration.map({ $0.isFinite && $0 >= 0 }) ?? true
            else { throw HostCoreStateMigration.invalid("event bounds") }
            result.append(event)
        }
        guard Set(result.map(\.id)).count == result.count else {
            throw HostCoreStateMigration.invalid("duplicate events")
        }
        return result.reversed()
    }

    private static func date(_ statement: OpaquePointer, column: Int32, original: Int32) throws
        -> Date?
    {
        if sqlite3_column_type(statement, original) == SQLITE_NULL { return nil }
        guard sqlite3_column_type(statement, column) == SQLITE_FLOAT else {
            throw HostCoreStateMigration.invalid("schedule date")
        }
        let value = sqlite3_column_double(statement, column)
        guard value.isFinite else { throw HostCoreStateMigration.invalid("schedule date") }
        return Date(timeIntervalSince1970: value)
    }

    private static func requireTable(_ name: String, database: OpaquePointer) throws {
        var found = false
        try rows(database, sql: "SELECT type FROM sqlite_schema WHERE name = '\(name)' LIMIT 2") {
            statement in
            guard !found, try string(statement, column: 0) == "table" else {
                throw HostCoreStateMigration.invalid("database table")
            }
            found = true
        }
        guard found else { throw HostCoreStateMigration.invalid("database table") }
    }

    private static func rows(
        _ database: OpaquePointer, sql: String, consume: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw HostCoreStateMigration.invalid("text value")
        }
        defer { sqlite3_finalize(statement) }
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return }
            guard code == SQLITE_ROW else {
                throw HostCoreStateMigration.invalid("SQL read \(code)")
            }
            try consume(statement)
        }
    }

    private static func string(_ statement: OpaquePointer, column: Int32) throws -> String {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
            sqlite3_column_bytes(statement, column) <= 4096,
            let bytes = sqlite3_column_text(statement, column)
        else { throw HostCoreStateMigration.invalid("UTF-8 text") }
        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
        guard let value = String(data: data, encoding: .utf8), !value.utf8.contains(0) else {
            throw HostCoreStateMigration.invalid("database payload")
        }
        return value
    }

    private static func blob(_ statement: OpaquePointer, column: Int32, maximumBytes: Int) throws
        -> Data
    {
        let count = Int(sqlite3_column_bytes(statement, column))
        guard sqlite3_column_type(statement, column) == SQLITE_BLOB, count > 0,
            count <= maximumBytes,
            let bytes = sqlite3_column_blob(statement, column)
        else { throw HostCoreStateMigration.invalid("database validation") }
        return Data(bytes: bytes, count: count)
    }
}
