import Foundation
internal import GRDB

struct AttentionLegacyHistoryReport: Equatable, Sendable {
    let events: Int
    let receipts: Int
    let skipped: Bool
}

enum AttentionLegacyHistoryImport {
    static let markerName = "attention-legacy-import.done"
    static let sourceName = "edith.sqlite"
    private static let batchSize = 500

    @discardableResult
    static func run(
        source: URL, marker: URL, into database: AttentionDatabase, now: Date = Date()
    ) throws -> AttentionLegacyHistoryReport {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: marker.path),
            fileManager.fileExists(atPath: source.path)
        else { return AttentionLegacyHistoryReport(events: 0, receipts: 0, skipped: true) }
        var configuration = Configuration()
        configuration.readonly = true
        configuration.busyMode = .timeout(5)
        let legacy = try DatabaseQueue(path: source.path, configuration: configuration)
        defer { try? legacy.close() }
        let tables = try legacy.read { database in
            Set(
                try String.fetchAll(
                    database, sql: "SELECT name FROM sqlite_master WHERE type = 'table'"))
        }
        var events = 0
        var receipts = 0
        if tables.contains("attention_event") {
            let cutoff = AttentionRetention.cutoff(now: now)
            var offset = 0
            while true {
                try Task.checkCancellation()
                let rows = try legacy.read { database in
                    try Row.fetchAll(
                        database,
                        sql: """
                            SELECT id, startedAt, kind, payload FROM attention_event
                            WHERE startedAt >= ? ORDER BY startedAt, id LIMIT ? OFFSET ?
                            """,
                        arguments: [cutoff, batchSize, offset])
                }
                if rows.isEmpty { break }
                offset += rows.count
                events += try database.write { target in
                    var inserted = 0
                    for row in rows {
                        guard let payload: Data = row["payload"],
                            (try? AttentionPayload.decode(AttentionEvent.self, from: payload))
                                != nil
                        else { continue }
                        try target.execute(
                            sql: """
                                INSERT OR IGNORE INTO attention_event (id, startedAt, kind, payload)
                                VALUES (?, ?, ?, ?)
                                """,
                            arguments: [row["id"], row["startedAt"], row["kind"], payload])
                        inserted += target.changesCount
                    }
                    return inserted
                }
            }
        }
        if tables.contains("attention_delivery_receipt") {
            let rows = try legacy.read { database in
                try Row.fetchAll(
                    database,
                    sql:
                        "SELECT producerID, lastSequence, updatedAt FROM attention_delivery_receipt"
                )
            }
            receipts = try database.write { target in
                var inserted = 0
                for row in rows {
                    try target.execute(
                        sql: """
                            INSERT OR IGNORE INTO attention_delivery_receipt
                            (producerID, lastSequence, updatedAt) VALUES (?, ?, ?)
                            """,
                        arguments: [row["producerID"], row["lastSequence"], row["updatedAt"]])
                    inserted += target.changesCount
                }
                return inserted
            }
        }
        try Data().write(to: marker, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: marker.path)
        return AttentionLegacyHistoryReport(events: events, receipts: receipts, skipped: false)
    }
}
