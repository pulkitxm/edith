@_implementationOnly import EdithExtensionSupport
@_implementationOnly import EdithExtensionUI
import Foundation
@_implementationOnly import GRDB

struct AttentionImportReport: Codable, Equatable, Sendable {
    let files: Int
    let events: Int
    let alreadyImported: Bool

    init(files: Int, events: Int, alreadyImported: Bool) {
        self.files = files
        self.events = events
        self.alreadyImported = alreadyImported
    }
}

struct AttentionEventStore: Sendable, AttentionEventSink {
    let store: AttentionDatabase

    init(store: AttentionDatabase) {
        self.store = store
    }

    func record(_ batch: AttentionBatch) throws {
        try record(batch, now: Date())
    }

    func record(_ batch: AttentionBatch, now: Date) throws {
        guard !batch.events.isEmpty else { return }
        try store.write { database in
            try record(batch, in: database, now: now)
        }
    }

    func record(_ batch: AttentionBatch, now: Date) async throws {
        guard !batch.events.isEmpty else { return }
        try await store.awaitWrite { database in
            try self.record(batch, in: database, now: now)
        }
    }

    func record(_ batch: AttentionBatch, in database: Database, now: Date) throws {
        for event in batch.events where !AttentionRetention.isExpired(event, now: now) {
            guard event.duration.isFinite, event.duration > 0, event.duration <= 172_800 else {
                continue
            }
            if event.isSegment {
                try insert(event, into: database, preservingExisting: true)
                continue
            }
            let last = try Data.fetchOne(
                database,
                sql:
                    "SELECT payload FROM attention_event WHERE kind = ? ORDER BY startedAt DESC LIMIT 1",
                arguments: [event.source.rawValue]
            )
            .flatMap { try? AttentionPayload.decode(AttentionEvent.self, from: $0) }
            if let last, event.startedAt >= last.startedAt,
                AttentionPaths.utcCalendar.isDate(last.startedAt, inSameDayAs: event.startedAt),
                last.canMerge(with: event, pulseTime: batch.pulseTime)
                    || (last.id == event.id && last.endedAt >= event.endedAt)
            {
                try insert(last.merged(with: event), into: database)
            } else {
                try insert(event, into: database)
            }
        }
        try database.execute(
            sql: "DELETE FROM attention_event WHERE startedAt < ?",
            arguments: [AttentionRetention.cutoff(now: now)])
    }

    func hasEvents() throws -> Bool {
        try store.read { database in
            try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM attention_event)")
                ?? false
        }
    }

    func firstEventDate() throws -> Date? {
        try store.read { database in
            try Date.fetchOne(
                database, sql: "SELECT startedAt FROM attention_event ORDER BY startedAt LIMIT 1")
        }
    }

    func events(from: Date, to: Date) throws -> [AttentionEvent] {
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
                try Task.checkCancellation()
                guard let data: Data = row["payload"] else { return nil }
                return try? AttentionPayload.decode(AttentionEvent.self, from: data)
            }
            .compactMap { $0.clipped(from: from, to: to) }
        }
    }

    @discardableResult
    func importLegacyFiles(
        directory: URL = AttentionPaths.eventsDirectory, now: Date = Date()
    ) throws -> AttentionImportReport {
        var imported = 0
        let files = try AttentionFileSpool.drain(directory: directory) { data in
            let decoded = AttentionLegacyReader.events(in: data)
            let events = decoded.filter { !AttentionRetention.isExpired($0, now: now) }
            try store.write { database in
                for event in events { try insert(event, into: database, preservingExisting: true) }
            }
            imported += events.count
            return String(data: data, encoding: .utf8)?.split(separator: "\n").count
                == decoded.count
        }
        return AttentionImportReport(
            files: files, events: imported, alreadyImported: files == 0)
    }

    func restoreEvents(
        from directory: URL, now: Date = Date(), publish: () throws -> Void = {}
    ) throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        guard files.count <= 4096 else {
            throw AttentionServiceError("The Attention archive has too many event files.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(60))
        var bytes = 0
        try store.write { database in
            guard
                try Bool.fetchOne(database, sql: "SELECT EXISTS(SELECT 1 FROM attention_event)")
                    != true
            else {
                throw AttentionCloudBackupError.localStoreNotEmpty
            }
            for file in files {
                try Task.checkCancellation()
                guard
                    let data = try UsageDataFiles.readRegularFile(
                        at: file, maximumBytes: 67_108_864),
                    let text = String(data: data, encoding: .utf8)
                else {
                    throw AttentionServiceError(
                        "The Attention backup contains an unreadable event file.")
                }
                bytes += data.count
                guard bytes <= 536_870_912 else {
                    throw AttentionServiceError("The Attention archive exceeds 512 MiB.")
                }
                for line in text.split(separator: "\n") {
                    try Task.checkCancellation()
                    guard ContinuousClock.now < deadline else {
                        throw AttentionServiceError("Attention restore exceeded 60 seconds.")
                    }
                    let event = try AttentionPayload.decode(
                        AttentionEvent.self, from: Data(line.utf8))
                    if !AttentionRetention.isExpired(event, now: now) {
                        try insert(event, into: database, preservingExisting: true)
                    }
                }
            }
            try Task.checkCancellation()
            try publish()
        }
    }

    func exportEvents(to directory: URL, now: Date = Date()) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try store.read { database in
            let rows = try Row.fetchCursor(
                database,
                sql:
                    "SELECT startedAt, payload FROM attention_event WHERE startedAt >= ? ORDER BY startedAt",
                arguments: [AttentionRetention.cutoff(now: now)])
            var openName: String?
            var handle: FileHandle?
            var totalBytes = 0
            var fileBytes = 0
            let deadline = ContinuousClock.now.advanced(by: .seconds(60))
            defer { try? handle?.close() }
            while let row = try rows.next() {
                try Task.checkCancellation()
                let startedAt: Date = row["startedAt"]
                let payload: Data = row["payload"]
                let name = AttentionPaths.eventFile(for: startedAt).lastPathComponent
                if name != openName {
                    try handle?.close()
                    let file = directory.appendingPathComponent(name)
                    try Data().write(to: file)
                    handle = try FileHandle(forWritingTo: file)
                    openName = name
                    fileBytes = 0
                }
                totalBytes += payload.count + 1
                fileBytes += payload.count + 1
                guard totalBytes <= 536_870_912, fileBytes <= 67_108_864,
                    ContinuousClock.now < deadline
                else {
                    throw AttentionServiceError(
                        "Attention export exceeded its archive size or 60-second limit.")
                }
                try handle?.write(contentsOf: payload + Data([0x0A]))
            }
        }
    }

    private func insert(
        _ event: AttentionEvent, into database: Database, preservingExisting: Bool = false
    ) throws {
        if preservingExisting,
            let data = try Data.fetchOne(
                database, sql: "SELECT payload FROM attention_event WHERE id = ?",
                arguments: [event.id]),
            let existing = try? AttentionPayload.decode(AttentionEvent.self, from: data),
            existing.startedAt == event.startedAt, existing.endedAt >= event.endedAt
        {
            return
        }
        let payload = try AttentionPayload.encode(event)
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

enum AttentionLegacyReader {
    static func events(in data: Data) -> [AttentionEvent] {
        guard let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? AttentionPayload.decode(AttentionEvent.self, from: lineData)
        }
    }
}
