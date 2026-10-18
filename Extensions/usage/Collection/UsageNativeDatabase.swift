import Darwin
import Foundation
import SQLite3

final class UsageNativeDatabase {
    private var connection: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static let progress: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { _ in
        Task.isCancelled ? 1 : 0
    }

    init(url: URL, readOnly: Bool = false) throws {
        let descriptor = open(
            url.path, (readOnly ? O_RDONLY : O_CREAT | O_RDWR) | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw UsageNativeFailure.unsafePath }
        var status = stat()
        let valid =
            fstat(descriptor, &status) == 0 && status.st_mode & S_IFMT == S_IFREG
            && (readOnly || (status.st_uid == getuid() && status.st_mode & 0o077 == 0))
        Darwin.close(descriptor)
        guard valid else { throw UsageNativeFailure.unsafePath }
        let flags =
            readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard let resolved = realpath(url.deletingLastPathComponent().path, nil) else {
            throw UsageNativeFailure.unsafePath
        }
        let databasePath = String(cString: resolved) + "/" + url.lastPathComponent
        free(resolved)
        guard
            sqlite3_open_v2(databasePath, &connection, flags | SQLITE_OPEN_NOFOLLOW, nil)
                == SQLITE_OK
        else {
            close(); throw UsageNativeFailure.archive("open")
        }
        sqlite3_busy_timeout(connection, 1000)
        sqlite3_progress_handler(connection, 1000, Self.progress, nil)
        if !readOnly { try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;") }
    }

    deinit { close() }
    func close() {
        if let connection { sqlite3_close_v2(connection); self.connection = nil }
    }

    func execute(_ sql: String) throws {
        try Task.checkCancellation()
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            try Task.checkCancellation(); throw UsageNativeFailure.archive("execute transaction")
        }
    }

    func transaction<Value>(_ operation: () throws -> Value) throws -> Value {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try operation()
            try Task.checkCancellation(); try execute("COMMIT")
            return result
        } catch {
            sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    @discardableResult func run(_ sql: String, _ values: [Any] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            try Task.checkCancellation(); throw UsageNativeFailure.archive("write record")
        }
        return Int(sqlite3_changes(connection))
    }

    func rows(_ sql: String, _ values: [Any] = [], maximum: Int = 2_000_000) throws -> [[String:
        String]]
    {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        var rows: [[String: String]] = []
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return rows }
            guard step == SQLITE_ROW else { throw UsageNativeFailure.archive("read records") }
            var row: [String: String] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                let key = String(cString: sqlite3_column_name(statement, index))
                if let text = sqlite3_column_text(statement, index) {
                    row[key] = String(cString: text)
                }
            }
            rows.append(row)
            guard rows.count <= maximum else { throw UsageNativeFailure.capacity }
        }
    }

    private func prepare(_ sql: String, _ values: [Any]) throws -> OpaquePointer {
        try Task.checkCancellation()
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK, let statement
        else {
            throw UsageNativeFailure.archive("prepare statement")
        }
        do {
            for (offset, value) in values.enumerated() {
                let result: Int32
                let index = Int32(offset + 1)
                if let value = value as? String {
                    result = value.withCString {
                        sqlite3_bind_text(statement, index, $0, -1, transient)
                    }
                } else if let value = value as? Int {
                    result = sqlite3_bind_int64(statement, index, Int64(value))
                } else if let value = value as? Double {
                    result = sqlite3_bind_double(statement, index, value)
                } else if value is NSNull {
                    result = sqlite3_bind_null(statement, index)
                } else {
                    throw UsageNativeFailure.invalidInput("archive parameter")
                }
                guard result == SQLITE_OK else {
                    throw UsageNativeFailure.archive("bind parameter")
                }
            }
            return statement
        } catch { sqlite3_finalize(statement); throw error }
    }
}
