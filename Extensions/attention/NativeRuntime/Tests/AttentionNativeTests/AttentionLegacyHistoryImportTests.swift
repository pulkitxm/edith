import Foundation
import GRDB
import Testing

@testable import AttentionNative

private struct LegacyImportFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let now = Date(timeIntervalSince1970: 1_783_000_000)
    var source: URL { root.appendingPathComponent("edith.sqlite") }
    var marker: URL { root.appendingPathComponent("attention-legacy-import.done") }

    init() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func close() { try? FileManager.default.removeItem(at: root) }

    func event(_ id: String, daysAgo: Double) -> AttentionEvent {
        AttentionEvent(
            id: id, startedAt: now.addingTimeInterval(-daysAgo * 86_400), duration: 30,
            source: .application, appName: "Synthetic App", bundleID: "com.example.synthetic")
    }

    func makeSource(events: [AttentionEvent], receipts: [(String, Int)] = []) throws {
        let queue = try DatabaseQueue(path: source.path)
        try queue.write { database in
            try database.execute(
                sql:
                    "CREATE TABLE attention_event (id TEXT PRIMARY KEY NOT NULL, startedAt DATETIME NOT NULL, kind TEXT NOT NULL, payload BLOB NOT NULL)"
            )
            try database.execute(
                sql:
                    "CREATE TABLE attention_delivery_receipt (producerID TEXT PRIMARY KEY NOT NULL, lastSequence INTEGER NOT NULL, updatedAt DATETIME NOT NULL)"
            )
            for event in events {
                try database.execute(
                    sql: "INSERT INTO attention_event VALUES (?, ?, ?, ?)",
                    arguments: [
                        event.id, event.startedAt, event.source.rawValue,
                        try AttentionPayload.encode(event),
                    ])
            }
            try database.execute(
                sql: "INSERT INTO attention_event VALUES ('bad', ?, 'application', ?)",
                arguments: [now, Data("not json".utf8)])
            for (producer, sequence) in receipts {
                try database.execute(
                    sql: "INSERT INTO attention_delivery_receipt VALUES (?, ?, ?)",
                    arguments: [producer, sequence, now])
            }
        }
        try queue.close()
    }

    func destination() throws -> AttentionDatabase {
        try AttentionDatabase(url: root.appendingPathComponent("attention-history.sqlite"))
    }
}

@Suite struct AttentionLegacyHistoryImportTests {
    @Test func copiesEventsAndReceiptsOnceAndWritesMarker() throws {
        let fixture = try LegacyImportFixture()
        defer { fixture.close() }
        try fixture.makeSource(
            events: [fixture.event("a", daysAgo: 1), fixture.event("b", daysAgo: 2)],
            receipts: [("producer-1", 7)])
        let database = try fixture.destination()
        let report = try AttentionLegacyHistoryImport.run(
            source: fixture.source, marker: fixture.marker, into: database, now: fixture.now)
        #expect(report == AttentionLegacyHistoryReport(events: 2, receipts: 1, skipped: false))
        #expect(FileManager.default.fileExists(atPath: fixture.marker.path))
        let ids = try database.read {
            try String.fetchAll($0, sql: "SELECT id FROM attention_event ORDER BY id")
        }
        #expect(ids == ["a", "b"])
        let sequence = try database.read {
            try Int.fetchOne($0, sql: "SELECT lastSequence FROM attention_delivery_receipt")
        }
        #expect(sequence == 7)
        let again = try AttentionLegacyHistoryImport.run(
            source: fixture.source, marker: fixture.marker, into: database, now: fixture.now)
        #expect(again.skipped)
    }

    @Test func skipsExpiredEventsAndKeepsExistingRows() throws {
        let fixture = try LegacyImportFixture()
        defer { fixture.close() }
        try fixture.makeSource(events: [
            fixture.event("old", daysAgo: 400), fixture.event("kept", daysAgo: 3),
        ])
        let database = try fixture.destination()
        let newer = AttentionEvent(
            id: "kept", startedAt: fixture.now, duration: 99, source: .application,
            appName: "Current", bundleID: "com.example.current")
        try database.write { target in
            try target.execute(
                sql: "INSERT INTO attention_event VALUES (?, ?, ?, ?)",
                arguments: [
                    "kept", newer.startedAt, "application", try AttentionPayload.encode(newer),
                ])
        }
        let report = try AttentionLegacyHistoryImport.run(
            source: fixture.source, marker: fixture.marker, into: database, now: fixture.now)
        #expect(report.events == 0)
        let rows = try database.read {
            try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM attention_event")
        }
        #expect(rows == 1)
    }

    @Test func leavesSourceUntouchedAndSkipsWhenMissing() throws {
        let fixture = try LegacyImportFixture()
        defer { fixture.close() }
        let database = try fixture.destination()
        let missing = try AttentionLegacyHistoryImport.run(
            source: fixture.source, marker: fixture.marker, into: database, now: fixture.now)
        #expect(missing.skipped)
        #expect(!FileManager.default.fileExists(atPath: fixture.marker.path))
        try fixture.makeSource(events: [fixture.event("a", daysAgo: 1)])
        let before = try Data(contentsOf: fixture.source)
        try AttentionLegacyHistoryImport.run(
            source: fixture.source, marker: fixture.marker, into: database, now: fixture.now)
        #expect(try Data(contentsOf: fixture.source) == before)
    }
}
