import Foundation
import Testing

@testable import EdithKit

@Suite struct UsageHistoryTests {
    private func usage(
        days: [(period: String, tokens: Double, cost: Double)],
        source: String = "cli",
        sessions: [[String: Any]] = []
    ) -> Data {
        let daily = days.map { d in
            [
                "period": d.period,
                "bySource": [
                    source: [
                        [
                            "modelName": "m", "inputTokens": d.tokens, "outputTokens": 0,
                            "cacheCreationTokens": 0, "cacheReadTokens": 0, "cost": d.cost,
                        ]
                    ]
                ],
                "hours": [], "projects": [],
            ] as [String: Any]
        }
        let obj: [String: Any] = [
            "schemaVersion": 4,
            "generatedAt": "2026-07-06T00:00:00Z",
            "sources": [source],
            "defaultSources": [source],
            "sourceMeta": [source: ["label": source, "tool": source]],
            "totals": ["cost": 0, "tokens": 0],
            "daily": daily,
            "sessions": sessions,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func decode(_ data: Data?) -> [String: Any] {
        try! JSONSerialization.jsonObject(with: data!) as! [String: Any]
    }

    private func periods(_ obj: [String: Any]) -> [String] {
        (obj["daily"] as! [[String: Any]]).map { $0["period"] as! String }
    }

    @Test func keepsCloudDaysMissingLocally() {
        let local = usage(days: [("2026-06-10", 100, 1)])
        let cloud = usage(days: [("2026-05-01", 500, 5), ("2026-06-10", 100, 1)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        #expect(periods(merged) == ["2026-05-01", "2026-06-10"])
    }

    @Test func maxTokensWinsPerDay() {
        let local = usage(days: [("2026-06-10", 40, 1)])
        let cloud = usage(days: [("2026-06-10", 900, 9)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let day = (merged["daily"] as! [[String: Any]]).first!
        #expect(UsageHistory.dayTokens(day) == 900)
    }

    @Test func localWinsTies() {
        let local = usage(days: [("2026-06-10", 100, 2)])
        let cloud = usage(days: [("2026-06-10", 100, 1)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let day = (merged["daily"] as! [[String: Any]]).first!
        let rows = (day["bySource"] as! [String: [[String: Any]]])["cli"]!
        #expect(rows.first!["cost"] as! Double == 2)
    }

    @Test func totalsRecomputedAcrossMergedDays() {
        let local = usage(days: [("2026-06-10", 100, 1)])
        let cloud = usage(days: [("2026-05-01", 500, 5)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["tokens"] as! Double == 600)
        #expect(totals["cost"] as! Double == 6)
        let by = totals["bySource"] as! [String: [String: Double]]
        #expect(by["cli"]?["tokens"] == 600)
    }

    @Test func sourcesAndSessionsUnion() {
        let local = usage(
            days: [("2026-06-10", 100, 1)], source: "cli",
            sessions: [["id": "a", "source": "cli"]])
        let cloud = usage(
            days: [("2026-05-01", 500, 5)], source: "codex",
            sessions: [["id": "a", "source": "cli"], ["id": "b", "source": "codex"]])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        #expect(Set(merged["sources"] as! [String]) == ["cli", "codex"])
        #expect((merged["sessions"] as! [[String: Any]]).count == 2)
    }

    @Test func missingSideReturnsOtherVerbatim() {
        let local = usage(days: [("2026-06-10", 100, 1)])
        #expect(UsageHistory.merge(local: local, cloud: nil) == local)
        #expect(UsageHistory.merge(local: nil, cloud: local) == local)
        #expect(UsageHistory.merge(local: nil, cloud: nil) == nil)
    }

    @Test func garbageSideFallsBackToValidSide() {
        let valid = usage(days: [("2026-06-10", 100, 1)])
        let garbage = Data("not json".utf8)
        #expect(UsageHistory.merge(local: garbage, cloud: valid) == valid)
        #expect(UsageHistory.merge(local: valid, cloud: garbage) == valid)
    }

    @Test func emptyDailyMergesToOtherSideDays() {
        let local = usage(days: [])
        let cloud = usage(days: [("2026-05-01", 500, 5)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        #expect(periods(merged) == ["2026-05-01"])
    }

    @Test func shrunkDayNeverRegresses() {
        let cloud = usage(days: [("2026-05-30", 374_969_194, 300)])
        let local = usage(days: [("2026-05-30", 4_759_508, 3)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let day = (merged["daily"] as! [[String: Any]]).first!
        #expect(UsageHistory.dayTokens(day) == 374_969_194)
    }

    @Test func dayWithMissingBySourceCountsZero() {
        #expect(UsageHistory.dayTokens(["period": "2026-06-10"]) == 0)
        #expect(UsageHistory.dayTokens(["period": "2026-06-10", "bySource": [:]]) == 0)
    }

    @Test func richerSessionObjectWins() {
        let lean: [[String: Any]] = [["id": "a", "source": "cli"]]
        let rich: [[String: Any]] = [
            ["id": "a", "source": "cli", "totalTokens": 5, "models": ["m"]]
        ]
        let local = usage(days: [("2026-06-10", 1, 1)], sessions: lean)
        let cloud = usage(days: [("2026-06-10", 1, 1)], sessions: rich)
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 1)
        #expect(sessions.first?["totalTokens"] as? Int == 5)
    }

    @Test func sessionsWithoutIdDropped() {
        let local = usage(days: [("2026-06-10", 1, 1)], sessions: [["source": "cli"], ["id": ""]])
        let cloud = usage(days: [("2026-06-10", 1, 1)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        #expect((merged["sessions"] as! [[String: Any]]).isEmpty)
    }

    @Test func localSourceMetaWinsPerKey() {
        var l = decode(usage(days: [("2026-06-10", 1, 1)]))
        l["sourceMeta"] = ["cli": ["label": "Local Label"]]
        var c = decode(usage(days: [("2026-06-10", 1, 1)]))
        c["sourceMeta"] = ["cli": ["label": "Cloud Label"], "codex": ["label": "Codex"]]
        let merged = decode(
            UsageHistory.merge(
                local: try! JSONSerialization.data(withJSONObject: l),
                cloud: try! JSONSerialization.data(withJSONObject: c)))
        let meta = merged["sourceMeta"] as! [String: [String: Any]]
        #expect(meta["cli"]?["label"] as? String == "Local Label")
        #expect(meta["codex"]?["label"] as? String == "Codex")
    }

    @Test func schemaVersionTakesMax() {
        var l = decode(usage(days: [("2026-06-10", 1, 1)]))
        l["schemaVersion"] = 3
        let merged = decode(
            UsageHistory.merge(
                local: try! JSONSerialization.data(withJSONObject: l),
                cloud: usage(days: [("2026-06-10", 1, 1)])))
        #expect(merged["schemaVersion"] as? Int == 4)
    }

    @Test func totalsBySourceSplitsPerSource() {
        let local = usage(days: [("2026-06-10", 100, 1)], source: "cli")
        let cloud = usage(days: [("2026-05-01", 500, 5)], source: "codex")
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let by = (merged["totals"] as! [String: Any])["bySource"] as! [String: [String: Double]]
        #expect(by["cli"]?["tokens"] == 100)
        #expect(by["codex"]?["tokens"] == 500)
        #expect(by["codex"]?["cost"] == 5)
    }

    @Test func foldsLegacyCloudSourceIntoCli() {
        var c = decode(usage(days: [("2026-06-10", 100, 1)]))
        c["sources"] = ["cli", "cc-cloud"]
        c["defaultSources"] = ["cli", "cc-cloud"]
        c["sourceMeta"] = [
            "cli": ["label": "Claude Code"], "cc-cloud": ["label": "Claude Code Cloud"],
        ]
        c["sessions"] = [["id": "a", "source": "cc-cloud"], ["id": "a", "source": "cli"]]
        var day = (c["daily"] as! [[String: Any]])[0]
        var by = day["bySource"] as! [String: Any]
        by["cc-cloud"] = [
            [
                "modelName": "m", "inputTokens": 7.0, "outputTokens": 3.0,
                "cacheCreationTokens": 0.0, "cacheReadTokens": 40.0, "cost": 2.0,
            ]
        ]
        day["bySource"] = by
        day["projects"] = [
            [
                "projectName": "p",
                "chats": [["id": "s1", "tokens": 10.0, "cost": 1.0, "source": "cc-cloud"]],
                "worktrees": [["name": "wt", "chats": [["id": "s2", "source": "cc-cloud"]]]],
            ]
        ]
        c["daily"] = [day]
        let local = usage(days: [("2026-06-11", 5, 1)])
        let merged = decode(
            UsageHistory.merge(
                local: local, cloud: try! JSONSerialization.data(withJSONObject: c)))
        #expect(Set(merged["sources"] as! [String]) == ["cli"])
        #expect(Set(merged["defaultSources"] as! [String]) == ["cli"])
        #expect((merged["sourceMeta"] as! [String: Any])["cc-cloud"] == nil)
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 1)
        #expect(sessions.first?["source"] as? String == "cli")
        let mergedDay = (merged["daily"] as! [[String: Any]]).first {
            $0["period"] as? String == "2026-06-10"
        }!
        let rows = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(rows["cc-cloud"] == nil)
        let row = rows["cli"]!.first!
        #expect(row["inputTokens"] as! Double == 107)
        #expect(row["outputTokens"] as! Double == 3)
        #expect(row["cacheReadTokens"] as! Double == 40)
        #expect(row["cost"] as! Double == 3)
        let project = (mergedDay["projects"] as! [[String: Any]]).first!
        let chat = (project["chats"] as! [[String: Any]]).first!
        #expect(chat["source"] as? String == "cli")
        let worktree = (project["worktrees"] as! [[String: Any]]).first!
        let wtChat = (worktree["chats"] as! [[String: Any]]).first!
        #expect(wtChat["source"] as? String == "cli")
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["tokens"] as! Double == 155)
        let byTotals = totals["bySource"] as! [String: [String: Double]]
        #expect(byTotals["cc-cloud"] == nil)
        #expect(byTotals["cli"]?["tokens"] == 155)
    }

    @Test func newerLocalSchemaWinsOverlappingDays() {
        var l = decode(usage(days: [("2026-06-10", 40, 1)]))
        l["schemaVersion"] = 5
        let cloud = usage(days: [("2026-05-01", 9, 1), ("2026-06-10", 900, 9)])
        let merged = decode(
            UsageHistory.merge(
                local: try! JSONSerialization.data(withJSONObject: l), cloud: cloud))
        #expect(periods(merged) == ["2026-05-01", "2026-06-10"])
        let overlap = (merged["daily"] as! [[String: Any]]).first {
            $0["period"] as? String == "2026-06-10"
        }!
        #expect(UsageHistory.dayTokens(overlap) == 40)
        #expect(merged["schemaVersion"] as? Int == 5)
    }
}
