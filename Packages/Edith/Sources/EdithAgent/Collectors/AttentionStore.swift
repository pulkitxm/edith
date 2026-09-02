import EdithKit
import Foundation
import GRDB

public struct AttentionImportReport: Codable, Equatable, Sendable {
    public let files: Int
    public let events: Int
    public let alreadyImported: Bool

    public init(files: Int, events: Int, alreadyImported: Bool) {
        self.files = files
        self.events = events
        self.alreadyImported = alreadyImported
    }
}

public struct AttentionEventStore: Sendable {
    public static let importMarkerKey = "attentionEventsImported"

    private let store: AgentStore
    private let defaults: UserDefaults

    public init(store: AgentStore, defaults: UserDefaults = SharedDefaults.store) {
        self.store = store
        self.defaults = defaults
    }

    public func record(_ batch: AttentionBatch, now: Date = Date()) throws {
        guard !batch.events.isEmpty else { return }
        try store.write { database in
            for event in batch.events where !AttentionRetention.isExpired(event, now: now) {
                try insert(event, into: database)
            }
            try database.execute(
                sql: "DELETE FROM attention_event WHERE startedAt < ?",
                arguments: [AttentionRetention.cutoff(now: now)])
        }
    }

    public func events(from: Date, to: Date) throws -> [AttentionEvent] {
        guard to > from else { return [] }
        return try store.read { database in
            try Row.fetchAll(
                database,
                sql: """
                    SELECT payload FROM attention_event
                    WHERE startedAt < ? AND startedAt >= ?
                    ORDER BY startedAt
                    """,
                arguments: [to, from.addingTimeInterval(-172_800)]
            )
            .compactMap { row -> AttentionEvent? in
                guard let data: Data = row["payload"] else { return nil }
                return try? AgentPayload.decode(AttentionEvent.self, from: data)
            }
            .compactMap { $0.clipped(from: from, to: to) }
        }
    }

    @discardableResult
    public func importLegacyFiles(
        directory: URL = AttentionPaths.eventsDirectory, fileManager: FileManager = .default
    ) throws -> AttentionImportReport {
        guard !defaults.bool(forKey: Self.importMarkerKey) else {
            return AttentionImportReport(files: 0, events: 0, alreadyImported: true)
        }
        let files =
            ((try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }
        var imported = 0
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let events = AttentionLegacyReader.events(in: data)
            guard !events.isEmpty else { continue }
            try store.write { database in
                for event in events { try insert(event, into: database) }
            }
            imported += events.count
        }
        defaults.set(true, forKey: Self.importMarkerKey)
        return AttentionImportReport(
            files: files.count, events: imported, alreadyImported: false)
    }

    private func insert(_ event: AttentionEvent, into database: Database) throws {
        let payload = try AgentPayload.encode(event)
        try database.execute(
            sql: """
                INSERT INTO attention_event (id, startedAt, kind, payload)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET startedAt = excluded.startedAt,
                kind = excluded.kind, payload = excluded.payload
                """,
            arguments: [event.id, event.startedAt, event.source.rawValue, payload])
    }
}

public enum AttentionLegacyReader {
    public static func events(in data: Data) -> [AttentionEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? AgentPayload.decode(AttentionEvent.self, from: lineData)
        }
    }
}
