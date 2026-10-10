@_implementationOnly import GRDB
import Darwin
import Foundation

final class AttentionDatabase: @unchecked Sendable {
    private let pool: DatabasePool
    init(url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var configuration = Configuration()
        configuration.busyMode = .timeout(5)
        configuration.prepareDatabase { database in
            try database.execute(sql: "PRAGMA synchronous = FULL")
        }
        pool = try DatabasePool(path: url.path, configuration: configuration)
        try pool.write { database in
            try database.execute(
                sql:
                    "CREATE TABLE IF NOT EXISTS attention_event (id TEXT PRIMARY KEY NOT NULL, startedAt DATETIME NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX IF NOT EXISTS attention_event_on_kind_startedAt ON attention_event(kind, startedAt)"
            )
            try database.execute(
                sql:
                    "CREATE INDEX IF NOT EXISTS attention_event_on_startedAt ON attention_event(startedAt)"
            )
            try database.execute(
                sql:
                    "CREATE TABLE IF NOT EXISTS attention_delivery_receipt (producerID TEXT PRIMARY KEY NOT NULL, lastSequence INTEGER NOT NULL, updatedAt DATETIME NOT NULL)"
            )
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func read<T>(_ body: (Database) throws -> T) throws -> T { try pool.read(body) }
    @discardableResult func write<T>(_ body: (Database) throws -> T) throws -> T {
        try pool.write(body)
    }
    @discardableResult func awaitWrite<T: Sendable>(
        _ body: @escaping @Sendable (Database) throws -> T
    ) async throws -> T { try await pool.write(body) }
    func close() throws { try pool.close() }
}
