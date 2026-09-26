import Foundation
import Network
import SQLite3

@testable import EdithHelper

struct SyntheticChromeCookie {
    var host: String
    var name: String
    var value: String
    var path = "/"
    var expires: Date? = Date(timeIntervalSinceNow: 86_400)
    var secure = false
    var httpOnly = false
    var sameSite = 1
    var updated = Date(timeIntervalSinceNow: -60)
    var encrypted = true
    var partition = ""
}

struct SyntheticChromeProfile {
    var directory: String
    var name: String
    var email: String?
    var cookies: [SyntheticChromeCookie] = []
    var localStorage: [String: [String: String]] = [:]
    var colorARGB: Int64?
}

struct SyntheticChrome {
    static let passphrase = "mock-safe-storage"
    static var key: ChromeCookieKey { ChromeCookieKey(passphrase: passphrase) }

    let root: URL
    var userData: ChromeUserData { ChromeUserData(root: root) }

    init(profiles: [SyntheticChromeProfile], cookieVersion: Int = 24) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "edith-synthetic-chrome-\(UUID().uuidString)", isDirectory: true)
        var cache: [String: [String: Any]] = [:]
        for profile in profiles {
            let folder = root.appendingPathComponent(profile.directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var info: [String: Any] = ["name": profile.name]
            if let email = profile.email { info["user_name"] = email }
            if let color = profile.colorARGB { info["profile_highlight_color"] = color }
            cache[profile.directory] = info
            try Self.writeCookies(
                profile.cookies, to: folder.appendingPathComponent("Cookies"),
                version: cookieVersion)
            if !profile.localStorage.isEmpty {
                let storage = folder.appendingPathComponent(
                    "Local Storage/leveldb", isDirectory: true)
                try FileManager.default.createDirectory(
                    at: storage, withIntermediateDirectories: true)
                try Self.localStorageLog(profile.localStorage)
                    .write(to: storage.appendingPathComponent("000003.log"))
            }
        }
        let state: [String: Any] = [
            "profile": ["info_cache": cache, "profiles_order": profiles.map(\.directory)]
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: root.appendingPathComponent("Local State"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    static func writeCookies(_ cookies: [SyntheticChromeCookie], to url: URL, version: Int)
        throws
    {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let db = handle else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
            CREATE TABLE cookies(creation_utc INTEGER NOT NULL, host_key TEXT NOT NULL,
            top_frame_site_key TEXT NOT NULL, name TEXT NOT NULL, value TEXT NOT NULL,
            encrypted_value BLOB NOT NULL, path TEXT NOT NULL, expires_utc INTEGER NOT NULL,
            is_secure INTEGER NOT NULL, is_httponly INTEGER NOT NULL,
            last_access_utc INTEGER NOT NULL, has_expires INTEGER NOT NULL,
            is_persistent INTEGER NOT NULL, priority INTEGER NOT NULL, samesite INTEGER NOT NULL,
            source_scheme INTEGER NOT NULL, source_port INTEGER NOT NULL,
            last_update_utc INTEGER NOT NULL, source_type INTEGER NOT NULL,
            has_cross_site_ancestor INTEGER NOT NULL);
            INSERT INTO meta VALUES('version', '\(version)');
            """
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw CocoaError(.fileWriteUnknown)
        }
        let insert = """
            INSERT INTO cookies VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?, 1, ?, 2, 443, ?, 0, 0)
            """
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, insert, -1, &prepared, nil) == SQLITE_OK,
            let statement = prepared
        else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for cookie in cookies {
            sqlite3_reset(statement)
            let updated = ChromeCookieReader.chromeMicroseconds(cookie.updated)
            let blob =
                cookie.encrypted
                ? ChromeSafeStorage.encrypt(
                    cookie.value, key: key, host: version >= 24 ? cookie.host : nil) ?? Data()
                : Data()
            sqlite3_bind_int64(statement, 1, updated)
            sqlite3_bind_text(statement, 2, cookie.host, -1, transient)
            sqlite3_bind_text(statement, 3, cookie.partition, -1, transient)
            sqlite3_bind_text(statement, 4, cookie.name, -1, transient)
            sqlite3_bind_text(statement, 5, cookie.encrypted ? "" : cookie.value, -1, transient)
            _ = blob.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 6, bytes.baseAddress, Int32(blob.count), transient)
            }
            sqlite3_bind_text(statement, 7, cookie.path, -1, transient)
            sqlite3_bind_int64(
                statement, 8, cookie.expires.map(ChromeCookieReader.chromeMicroseconds) ?? 0)
            sqlite3_bind_int(statement, 9, cookie.secure ? 1 : 0)
            sqlite3_bind_int(statement, 10, cookie.httpOnly ? 1 : 0)
            sqlite3_bind_int(statement, 11, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 12, cookie.expires == nil ? 0 : 1)
            sqlite3_bind_int(statement, 13, Int32(cookie.sameSite))
            sqlite3_bind_int64(statement, 14, updated)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
    }

    static func localStorageLog(_ origins: [String: [String: String]]) -> Data {
        var batch = Data()
        var count: UInt32 = 0
        for (origin, items) in origins.sorted(by: { $0.key < $1.key }) {
            for (name, value) in items.sorted(by: { $0.key < $1.key }) {
                let key = Data([0x5F]) + Data(origin.utf8) + Data([0]) + latin1(name)
                batch.append(1)
                batch.append(varint(key.count))
                batch.append(key)
                let encoded = utf16(value)
                batch.append(varint(encoded.count))
                batch.append(encoded)
                count += 1
            }
        }
        var record = little(UInt64(1), count: 8) + little(UInt64(count), count: 4)
        record.append(batch)
        var log = Data(repeating: 0, count: 4)
        log.append(little(UInt64(record.count), count: 2))
        log.append(1)
        log.append(record)
        return log
    }

    private static func latin1(_ text: String) -> Data {
        Data([1]) + Data(text.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })
    }

    private static func utf16(_ text: String) -> Data {
        var data = Data([0])
        for unit in text.utf16 { data.append(little(UInt64(unit), count: 2)) }
        return data
    }

    private static func varint(_ value: Int) -> Data {
        var remaining = UInt64(value)
        var data = Data()
        while remaining >= 0x80 {
            data.append(UInt8(remaining & 0x7F) | 0x80)
            remaining >>= 7
        }
        data.append(UInt8(remaining))
        return data
    }

    private static func little(_ value: UInt64, count: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: value >> (8 * UInt64($0))) })
    }
}

final class BrowserHTTPFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "edith.browser.fixture")
    private let lock = NSLock()
    private var connections: [NWConnection] = []
    private var boundPort: UInt16?
    private let pages: [String: String]

    init(pages: [String: String]) throws {
        self.pages = pages
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, case .ready = state, let port = self.listener.port, port.rawValue > 0
            else { return }
            self.lock.withLock { self.boundPort = port.rawValue }
        }
        listener.start(queue: queue)
    }

    func origin() async throws -> URL {
        for _ in 0..<200 {
            if let port = lock.withLock({ boundPort }) {
                return URL(string: "http://127.0.0.1:\(port)/")!
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadUnknown)
    }

    func stop() {
        listener.cancel()
        for connection in lock.withLock({ connections }) { connection.cancel() }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) {
            [weak self] data, _, _, _ in
            guard let self, let data else { return }
            let request = String(decoding: data, as: UTF8.self)
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "/"
            let body = self.pages[path]
            let status = body == nil ? "404 Not Found" : "200 OK"
            let payload = body ?? "missing"
            let response =
                "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(payload.utf8.count)\r\nConnection: close\r\n\r\n\(payload)"
            connection.send(
                content: Data(response.utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}
