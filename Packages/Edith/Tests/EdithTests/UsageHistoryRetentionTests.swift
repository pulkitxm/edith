import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageHistoryRetentionTests {
    @Test func missingModelPreservesWholeHistoryWhileNewDaysAndOtherSourcesAdvance() throws {
        let previous = try document([
            day(
                "2026-08-02",
                ["cli": [row("large", 60), row("small", 40)], "cursor": [row("one", 5)]])
        ])
        let fresh = try document([
            day(
                "2026-08-02",
                ["cli": [row("large", 60), row("new", 50)], "cursor": [row("one", 9)]]),
            day("2026-09-05", ["cli": [row("large", 7)]]),
        ])
        let merged = try #require(UsageHistory.mergeRefresh(fresh: fresh, previous: previous))
        #expect(UsageHistory.isValidDocument(merged))
        let result = try object(merged)
        #expect(tokens(result) == 116)
        let retained = try blocks(result)
        #expect(retained.count == 1)
        let candidates = try #require(retained[0]["candidates"] as? [[String: Any]])
        #expect(candidates.count == 1)
        #expect(sourceTokens(candidates[0], "cli") == 110)
        let days = try #require(result["daily"] as? [[String: Any]])
        #expect(sourceTokens(days[0], "cli") == 100)
        #expect(sourceTokens(days[0], "cursor") == 9)
        let hours = try #require(days[0]["hours"] as? [[String: Any]])
        let firstSources = try #require(hours[0]["bySource"] as? [String: [String: Any]])
        #expect(firstSources["cli"]?["tokens"] as? Double == 100)
        let projects = try #require(days[0]["projects"] as? [[String: Any]])
        let chats = try #require(projects[0]["chats"] as? [[String: Any]])
        #expect(chats.filter { $0["source"] as? String == "cli" }.count == 1)
        #expect(chats.first { $0["source"] as? String == "cli" }?["tokens"] as? Double == 100)
    }

    @Test func distinctOverlappingCandidatesSurviveRetriesReturnAndLargerPartialTotals() throws {
        let original = try document([day("2026-08-02", ["cli": [row("one", 100)]])])
        var retained = original
        for value in [60, 90, 90, 100, 150] {
            let fresh = try document([
                day("2026-08-02", ["cli": [row("one", Double(value))]]),
                day("2026-09-05", ["cli": [row("one", 12)]]),
            ])
            retained = try #require(UsageHistory.mergeRefresh(fresh: fresh, previous: retained))
            #expect(UsageHistory.isValidDocument(retained))
            #expect(tokens(try object(retained)) == 112)
        }
        let block = try #require(blocks(try object(retained)).first)
        let candidates = try #require(block["candidates"] as? [[String: Any]])
        #expect(candidates.map { sourceTokens($0, "cli") }.sorted() == [60, 90, 150])
        #expect(block["state"] as? String == "partial-overlap")
        #expect(UsageHistory.retainedHistoryBlockCount(in: retained) == 1)
    }

    @Test func completeDisappearanceKeepsBaselineAndMalformedOrFullRetentionRefusesPublication()
        throws
    {
        let original = try document([day("2026-08-02", ["cli": [row("one", 100)]])])
        let fresh = try document([day("2026-09-05", ["cli": [row("one", 15)]])])
        let preserved = try #require(UsageHistory.mergeRefresh(fresh: fresh, previous: original))
        #expect(tokens(try object(preserved)) == 115)
        var full = try object(preserved)
        var malformed = try object(preserved)
        var missingBaseline = try #require(blocks(malformed).first)
        missingBaseline["baseline"] = day("2026-08-02", [:])
        malformed["historyRetention"] = ["version": 1, "blocks": [missingBaseline]]
        let invalid = try JSONSerialization.data(withJSONObject: malformed)
        #expect(!UsageHistory.isValidDocument(invalid))
        #expect(UsageHistory.mergeRefresh(fresh: fresh, previous: invalid) == nil)
        #expect(UsageHistory.merge(local: invalid, cloud: nil) == nil)
        var retained = try #require(blocks(full).first)
        let candidate = day("2026-08-02", ["cli": [row("one", 1)]])
        retained["candidates"] = Array(repeating: candidate, count: 8_193)
        full["historyRetention"] = ["version": 1, "blocks": [retained]]
        let overCapacity = try JSONSerialization.data(withJSONObject: full)
        #expect(UsageHistory.mergeRefresh(fresh: fresh, previous: overCapacity) == nil)
        full["historyRetention"] = ["version": 99, "blocks": []]
        #expect(
            UsageHistory.mergeRefresh(
                fresh: try JSONSerialization.data(withJSONObject: full), previous: nil) == nil)
    }

    @Test func cloudMergePreservesProvenanceAndProtectsTheBaselineFromLaterPartialCopies() throws {
        let original = try document([day("2026-08-02", ["cli": [row("one", 100)]])])
        let partial = try document([day("2026-08-02", ["cli": [row("one", 60)]])])
        let retained = try #require(UsageHistory.mergeRefresh(fresh: partial, previous: original))
        let later = try document([
            day("2026-08-02", ["cli": [row("one", 150)]]),
            day("2026-09-05", ["cli": [row("one", 12)]]),
        ])
        let merged = try #require(UsageHistory.merge(local: later, cloud: retained))
        #expect(UsageHistory.isValidDocument(merged))
        #expect(tokens(try object(merged)) == 112)
        let block = try #require(blocks(try object(merged)).first)
        #expect(
            (block["provenance"] as? [String: Any])?["kind"] as? String == "published-aggregate")
        let candidates = try #require(block["candidates"] as? [[String: Any]])
        #expect(candidates.map { sourceTokens($0, "cli") }.sorted() == [60, 150])
        let roundTrip = try #require(UsageHistory.merge(local: nil, cloud: merged))
        #expect(roundTrip == merged)
    }

    private func document(_ days: [[String: Any]]) throws -> Data {
        let sources = Array(Set(days.flatMap { ($0["bySource"] as? [String: Any] ?? [:]).keys }))
            .sorted()
        let raw = try JSONSerialization.data(
            withJSONObject: [
                "schemaVersion": 8, "generatedAt": "2026-09-05T12:00:00Z",
                "sources": sources, "defaultSources": sources, "sourceMeta": [:], "sessions": [],
                "daily": days,
            ] as [String: Any])
        return try #require(UsageHistory.merge(local: raw, cloud: raw))
    }

    private func day(_ period: String, _ sources: [String: [[String: Any]]]) -> [String: Any] {
        let details = sources.mapValues { rows -> [String: Any] in
            let amount = rows.reduce(0) { $0 + ($1["inputTokens"] as? Double ?? 0) }
            let models = Dictionary(
                rows.map { row in
                    let tokens = row["inputTokens"] as? Double ?? 0
                    return (
                        row["modelName"] as? String ?? "unknown",
                        ["tokens": tokens, "cost": tokens / 100]
                    )
                }, uniquingKeysWith: { _, value in value })
            return ["tokens": amount, "cost": amount / 100, "byModel": models]
        }
        let amount = details.values.reduce(0) { $0 + ($1["tokens"] as? Double ?? 0) }
        let project: [String: Any] = [
            "repositoryID": "fixture", "repositoryName": "fixture", "folderName": "fixture",
            "path": "/fixture", "tokens": amount, "cost": amount / 100, "bySource": details,
            "chats": details.keys.sorted().map { source in
                [
                    "id": source, "source": source, "tokens": details[source]?["tokens"] ?? 0,
                    "cost": details[source]?["cost"] ?? 0,
                ] as [String: Any]
            }, "worktrees": [],
        ]
        return [
            "period": period, "bySource": sources,
            "hours": (0..<24).map { hour in
                [
                    "tokens": hour == 0 ? amount : 0, "cost": hour == 0 ? amount / 100 : 0,
                    "bySource": hour == 0 ? details : [:], "byPath": [:],
                ] as [String: Any]
            }, "projects": [project],
        ]
    }

    private func row(_ model: String, _ amount: Double) -> [String: Any] {
        [
            "modelName": model, "inputTokens": amount, "outputTokens": 0,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": amount / 100,
        ]
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func blocks(_ document: [String: Any]) throws -> [[String: Any]] {
        let retention = try #require(document["historyRetention"] as? [String: Any])
        return try #require(retention["blocks"] as? [[String: Any]])
    }

    private func tokens(_ document: [String: Any]) -> Double {
        (document["totals"] as? [String: Any])?["tokens"] as? Double ?? 0
    }

    private func sourceTokens(_ day: [String: Any], _ source: String) -> Double {
        let rows = (day["bySource"] as? [String: [[String: Any]]])?[source] ?? []
        return rows.reduce(0) { $0 + ($1["inputTokens"] as? Double ?? 0) }
    }
}
