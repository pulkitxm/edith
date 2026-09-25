import Foundation
import SQLite3

enum ChromeSameSite: Int, Sendable {
    case unspecified = -1
    case none = 0
    case lax = 1
    case strict = 2
}

struct ChromeCookie: Equatable, Sendable {
    let host: String
    let name: String
    let value: String
    let path: String
    let expires: Date?
    let isSecure: Bool
    let isHTTPOnly: Bool
    let sameSite: ChromeSameSite
    let updated: Date

    var httpCookie: HTTPCookie? {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .domain: host,
            .path: path.isEmpty ? "/" : path,
            .name: name,
            .value: value,
        ]
        if let expires { properties[.expires] = expires }
        if isSecure { properties[.secure] = "TRUE" }
        if isHTTPOnly { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        switch sameSite {
        case .lax: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteLax.rawValue
        case .strict: properties[.sameSitePolicy] = HTTPCookieStringPolicy.sameSiteStrict.rawValue
        case .none, .unspecified: break
        }
        return HTTPCookie(properties: properties)
    }
}

enum ChromeCookieReaderError: Error, Equatable, LocalizedError {
    case missingDatabase
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .missingDatabase: "This Chrome profile has no cookie database yet."
        case .unreadable(let reason): "Chrome's cookie database could not be read: \(reason)"
        }
    }
}

enum ChromeCookieReader {
    static let hashPrefixVersion = 24
    private static let windowsEpochOffset: TimeInterval = 11_644_473_600

    static func date(chromeMicroseconds value: Int64) -> Date? {
        guard value > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(value) / 1_000_000 - windowsEpochOffset)
    }

    static func chromeMicroseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 + windowsEpochOffset) * 1_000_000)
    }

    static func read(
        database: URL, key: ChromeCookieKey, updatedAfter: Date? = nil, now: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [ChromeCookie] {
        guard fileManager.fileExists(atPath: database.path) else {
            throw ChromeCookieReaderError.missingDatabase
        }
        var lastError: Error = ChromeCookieReaderError.unreadable("the database kept changing")
        for attempt in 0..<snapshotAttempts {
            if attempt > 0 { Thread.sleep(forTimeInterval: 0.15) }
            let scratch = fileManager.temporaryDirectory
                .appendingPathComponent("edith-cookies-\(UUID().uuidString)", isDirectory: true)
            defer { try? fileManager.removeItem(at: scratch) }
            do {
                let copy = try snapshot(database, into: scratch, fileManager: fileManager)
                return try rows(in: copy, key: key, updatedAfter: updatedAfter, now: now)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    static let snapshotAttempts = 3
    static let sidecarSuffixes = ["-journal", "-wal", "-shm"]

    static func fingerprint(_ database: URL, fileManager: FileManager = .default) -> [String] {
        ([""] + sidecarSuffixes).map { suffix in
            let path = database.path + suffix
            guard let attributes = try? fileManager.attributesOfItem(atPath: path) else {
                return "\(suffix):absent"
            }
            let size = attributes[.size] as? Int ?? -1
            let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            return "\(suffix):\(size):\(modified)"
        }
    }

    private static func snapshot(_ database: URL, into scratch: URL, fileManager: FileManager)
        throws -> URL
    {
        try fileManager.createDirectory(at: scratch, withIntermediateDirectories: true)
        let before = fingerprint(database, fileManager: fileManager)
        let copy = scratch.appendingPathComponent("Cookies")
        try fileManager.copyItem(at: database, to: copy)
        for suffix in sidecarSuffixes {
            let sidecar = URL(fileURLWithPath: database.path + suffix)
            guard fileManager.fileExists(atPath: sidecar.path) else { continue }
            try fileManager.copyItem(at: sidecar, to: URL(fileURLWithPath: copy.path + suffix))
        }
        guard fingerprint(database, fileManager: fileManager) == before else {
            throw ChromeCookieReaderError.unreadable("the database changed while it was copied")
        }
        return copy
    }

    private static func rows(in file: URL, key: ChromeCookieKey, updatedAfter: Date?, now: Date)
        throws -> [ChromeCookie]
    {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(file.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK,
            let db = handle
        else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(handle)
            throw ChromeCookieReaderError.unreadable(reason)
        }
        defer { sqlite3_close(db) }
        let version = Int(scalar(db, "SELECT value FROM meta WHERE key = 'version'") ?? "") ?? 0
        let columns = columnNames(db, table: "cookies")
        let updatedColumn = columns.contains("last_update_utc") ? "last_update_utc" : "creation_utc"
        var sql = """
            SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure,
            is_httponly, samesite, \(updatedColumn) FROM cookies
            """
        var filters: [String] = []
        if columns.contains("top_frame_site_key") { filters.append("top_frame_site_key = ''") }
        if updatedAfter != nil { filters.append("\(updatedColumn) > ?") }
        if !filters.isEmpty { sql += " WHERE " + filters.joined(separator: " AND ") }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
        else { throw ChromeCookieReaderError.unreadable(String(cString: sqlite3_errmsg(db))) }
        defer { sqlite3_finalize(statement) }
        if let updatedAfter {
            sqlite3_bind_int64(statement, 1, chromeMicroseconds(updatedAfter))
        }
        var cookies: [ChromeCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let cookie = cookie(from: statement, key: key, version: version, now: now)
            else { continue }
            cookies.append(cookie)
        }
        return cookies
    }

    private static func cookie(
        from statement: OpaquePointer, key: ChromeCookieKey, version: Int, now: Date
    ) -> ChromeCookie? {
        let host = text(statement, 0)
        let name = text(statement, 1)
        guard !host.isEmpty, !name.isEmpty else { return nil }
        let expires = date(chromeMicroseconds: sqlite3_column_int64(statement, 5))
        if let expires, expires <= now { return nil }
        var value = text(statement, 2)
        let encrypted = blob(statement, 3)
        if value.isEmpty, !encrypted.isEmpty {
            guard
                let decrypted = ChromeSafeStorage.decrypt(
                    encrypted, key: key, host: host, hashPrefixed: version >= hashPrefixVersion)
            else { return nil }
            value = decrypted
        }
        return ChromeCookie(
            host: host, name: name, value: value, path: text(statement, 4), expires: expires,
            isSecure: sqlite3_column_int(statement, 6) != 0,
            isHTTPOnly: sqlite3_column_int(statement, 7) != 0,
            sameSite: ChromeSameSite(rawValue: Int(sqlite3_column_int(statement, 8)))
                ?? .unspecified,
            updated: date(chromeMicroseconds: sqlite3_column_int64(statement, 9)) ?? now)
    }

    private static func scalar(_ db: OpaquePointer, _ sql: String) -> String? {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let statement = prepared
        else { return nil }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return text(statement, 0)
    }

    private static func columnNames(_ db: OpaquePointer, table: String) -> Set<String> {
        var prepared: OpaquePointer?
        guard
            sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &prepared, nil)
                == SQLITE_OK, let statement = prepared
        else { return [] }
        defer { sqlite3_finalize(statement) }
        var names: Set<String> = []
        while sqlite3_step(statement) == SQLITE_ROW { names.insert(text(statement, 1)) }
        return names
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        guard let raw = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: raw)
    }

    private static func blob(_ statement: OpaquePointer, _ column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }
}
