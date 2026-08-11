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

    private func model(
        _ name: String = "m", input: Double, output: Double = 0,
        cacheCreation: Double = 0, cacheRead: Double = 0, cost: Double
    ) -> [String: Any] {
        [
            "modelName": name,
            "inputTokens": input,
            "outputTokens": output,
            "cacheCreationTokens": cacheCreation,
            "cacheReadTokens": cacheRead,
            "cost": cost,
        ]
    }

    private func day(
        _ period: String, bySource: [String: [[String: Any]]],
        hours: [[String: Any]]? = nil, projects: [[String: Any]]? = nil
    ) -> [String: Any] {
        var day: [String: Any] = ["period": period, "bySource": bySource]
        if let hours { day["hours"] = hours }
        if let projects { day["projects"] = projects }
        return day
    }

    private func document(
        days: [[String: Any]], sources: [String], sessions: [[String: Any]] = [],
        schemaVersion: Int = 6
    ) -> Data {
        let sourceMeta = Dictionary(
            uniqueKeysWithValues: sources.map { ($0, ["label": $0, "tool": $0]) })
        let obj: [String: Any] = [
            "schemaVersion": schemaVersion,
            "generatedAt": "2026-07-06T00:00:00Z",
            "sources": sources,
            "defaultSources": sources,
            "sourceMeta": sourceMeta,
            "totals": ["cost": 0, "tokens": 0],
            "daily": days,
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

    @Test func localSourceCorrectionMayDecreaseTokens() {
        let local = usage(days: [("2026-06-10", 40, 1)])
        let cloud = usage(days: [("2026-06-10", 900, 9)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let day = (merged["daily"] as! [[String: Any]]).first!
        #expect(UsageHistory.dayTokens(day) == 40)
    }

    @Test func overlappingDayMergesProvidersIndependently() {
        let local = document(
            days: [
                day(
                    "2026-06-10", bySource: ["cli": [model(input: 40, cost: 1)]],
                    hours: [["tokens": 40.0, "cost": 1.0]],
                    projects: [["projectName": "local", "tokens": 40.0, "cost": 1.0]])
            ], sources: ["cli"], schemaVersion: 7)
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [model(input: 900, cost: 9)],
                        "codex": [model("gpt", input: 500, cost: 5)],
                    ],
                    hours: [["tokens": 1_400.0, "cost": 14.0]],
                    projects: [["projectName": "cloud", "tokens": 1_400.0, "cost": 14.0]])
            ], sources: ["cli", "codex"], schemaVersion: 7)
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let bySource = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(bySource["cli"]?.first?["inputTokens"] as? Double == 40)
        #expect(bySource["codex"]?.first?["inputTokens"] as? Double == 500)
        #expect(UsageHistory.dayTokens(mergedDay) == 540)
        let hours = mergedDay["hours"] as! [[String: Any]]
        #expect(hours.first?["tokens"] as? Double == 40)
        let projects = mergedDay["projects"] as! [[String: Any]]
        #expect(projects.first?["projectName"] as? String == "local")
    }

    @Test func cloudAuxiliaryDetailsSurviveWhenLocalDayOmitsThem() {
        let local = document(
            days: [day("2026-06-10", bySource: ["cli": [model(input: 40, cost: 1)]])],
            sources: ["cli"])
        let cloud = document(
            days: [
                day(
                    "2026-06-10", bySource: ["codex": [model(input: 10, cost: 2)]],
                    hours: [["tokens": 10.0, "cost": 2.0]],
                    projects: [["projectName": "kept", "tokens": 10.0, "cost": 2.0]])
            ], sources: ["codex"])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let hours = mergedDay["hours"] as! [[String: Any]]
        let projects = mergedDay["projects"] as! [[String: Any]]
        #expect(hours.first?["tokens"] as? Double == 10)
        #expect(projects.first?["projectName"] as? String == "kept")
    }

    @Test func schemaSevenMergesSourceAwareHoursAndProjects() {
        let localSource: [String: Any] = [
            "tokens": 10.0,
            "cost": 1.0,
            "byModel": ["opus": ["tokens": 10.0, "cost": 1.0]],
        ]
        let staleLocalSource: [String: Any] = [
            "tokens": 100.0,
            "cost": 10.0,
            "byModel": ["opus": ["tokens": 100.0, "cost": 10.0]],
        ]
        let tufSource: [String: Any] = [
            "tokens": 20.0,
            "cost": 2.0,
            "byModel": ["gpt": ["tokens": 20.0, "cost": 2.0]],
        ]
        let localProject: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "path": "/local/edith", "machineName": "Laptop", "machineID": "laptop",
            "tokens": 999.0, "cost": 99.0, "bySource": ["cli": localSource],
        ]
        let staleLocalProject: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "path": "/local/edith", "machineName": "Laptop", "machineID": "laptop",
            "tokens": 100.0, "cost": 10.0, "bySource": ["cli": staleLocalSource],
        ]
        let tufProject: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "path": "tuf:/home/me/edith", "machineName": "TUF", "machineID": "tuf",
            "tokens": 20.0, "cost": 2.0, "bySource": ["tuf:codex": tufSource],
        ]
        let local = document(
            days: [
                day(
                    "2026-06-10", bySource: ["cli": [model(input: 10, cost: 1)]],
                    hours: [
                        [
                            "tokens": 999.0, "cost": 99.0, "bySource": ["cli": localSource],
                            "byPath": [
                                "/local/edith": [
                                    "tokens": 10.0, "cost": 1.0,
                                    "bySource": ["cli": localSource],
                                ]
                            ],
                        ]
                    ], projects: [localProject])
            ], sources: ["cli"], schemaVersion: 7)
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [model(input: 100, cost: 10)],
                        "tuf:codex": [model("gpt", input: 20, cost: 2)],
                    ],
                    hours: [
                        [
                            "tokens": 120.0, "cost": 12.0,
                            "bySource": ["cli": staleLocalSource, "tuf:codex": tufSource],
                            "byPath": [
                                "/local/edith": [
                                    "tokens": 100.0, "cost": 10.0,
                                    "bySource": ["cli": staleLocalSource],
                                ],
                                "tuf:/home/me/edith": [
                                    "tokens": 20.0, "cost": 2.0,
                                    "bySource": ["tuf:codex": tufSource],
                                ],
                            ],
                        ]
                    ], projects: [staleLocalProject, tufProject])
            ], sources: ["cli", "tuf:codex"], schemaVersion: 7)

        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let hour = (mergedDay["hours"] as! [[String: Any]]).first!
        let hourSources = hour["bySource"] as! [String: [String: Any]]
        #expect(Set(hourSources.keys) == ["cli", "tuf:codex"])
        #expect((hourSources["cli"]?["tokens"] as? Double) == 10)
        #expect((hourSources["tuf:codex"]?["tokens"] as? Double) == 20)
        #expect(hour["tokens"] as? Double == 30)
        #expect(hour["cost"] as? Double == 3)
        let paths = hour["byPath"] as! [String: [String: Any]]
        #expect(Set(paths.keys) == ["/local/edith", "tuf:/home/me/edith"])
        #expect(paths["/local/edith"]?["tokens"] as? Double == 10)
        #expect(paths["tuf:/home/me/edith"]?["tokens"] as? Double == 20)
        let projects = mergedDay["projects"] as! [[String: Any]]
        #expect(projects.count == 2)
        #expect(projects.reduce(0) { $0 + ($1["tokens"] as? Double ?? 0) } == 30)
        let mergedTUF = projects.first { $0["machineID"] as? String == "tuf" }
        #expect(mergedTUF?["tokens"] as? Double == 20)
        #expect(mergedTUF?["cost"] as? Double == 2)
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

    @Test func machineQualifiedSourcesMergeIndependently() {
        let local = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "tof:cli": [model(input: 8, cost: 1)],
                        "laptop:cli": [model(input: 5, cost: 0.5)],
                    ])
            ], sources: ["tof:cli", "laptop:cli"])
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "tof:cli": [model(input: 80, cost: 8)],
                        "tof:codex": [model("gpt", input: 20, cost: 2)],
                    ])
            ], sources: ["tof:cli", "tof:codex"])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let bySource = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(Set(bySource.keys) == ["tof:cli", "tof:codex", "laptop:cli"])
        #expect(bySource["tof:cli"]?.first?["inputTokens"] as? Double == 8)
        #expect(bySource["tof:codex"]?.first?["inputTokens"] as? Double == 20)
        let totalsBySource =
            (merged["totals"] as! [String: Any])["bySource"] as! [String: [String: Double]]
        #expect(totalsBySource["tof:cli"]?["tokens"] == 8)
        #expect(totalsBySource["tof:codex"]?["tokens"] == 20)
        #expect(totalsBySource["laptop:cli"]?["tokens"] == 5)
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

    @Test func correctedHistoricalDayReplacesStaleHighVolumeSource() {
        let cloud = usage(days: [("2026-05-30", 374_969_194, 300)])
        let local = usage(days: [("2026-05-30", 4_759_508, 3)])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let day = (merged["daily"] as! [[String: Any]]).first!
        #expect(UsageHistory.dayTokens(day) == 4_759_508)
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

    @Test func equallyRichLocalSessionCorrectsCloudValue() {
        let localSessions: [[String: Any]] = [
            ["id": "a", "source": "tof:cli", "totalTokens": 3]
        ]
        let cloudSessions: [[String: Any]] = [
            ["id": "a", "source": "tof:cli", "totalTokens": 99],
            ["id": "a", "source": "tuf:cli", "totalTokens": 50],
        ]
        let local = document(days: [], sources: ["tof:cli"], sessions: localSessions)
        let cloud = document(days: [], sources: ["tof:cli", "tuf:cli"], sessions: cloudSessions)
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 2)
        let tof = sessions.first { $0["source"] as? String == "tof:cli" }
        let tuf = sessions.first { $0["source"] as? String == "tuf:cli" }
        #expect(tof?["totalTokens"] as? Int == 3)
        #expect(tuf?["totalTokens"] as? Int == 50)
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

    @Test func totalsRecomputeEveryBucketAfterSourceCorrections() {
        let local = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [
                            model(
                                input: 4, output: 3, cacheCreation: 2, cacheRead: 1,
                                cost: 1)
                        ]
                    ])
            ], sources: ["cli"])
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [
                            model(
                                input: 100, output: 50, cacheCreation: 20, cacheRead: 30,
                                cost: 10)
                        ],
                        "codex": [
                            model(
                                "gpt", input: 7, output: 6, cacheCreation: 5, cacheRead: 4,
                                cost: 2)
                        ],
                    ])
            ], sources: ["cli", "codex"])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["inputTokens"] as? Double == 11)
        #expect(totals["outputTokens"] as? Double == 9)
        #expect(totals["cacheCreationTokens"] as? Double == 7)
        #expect(totals["cacheReadTokens"] as? Double == 5)
        #expect(totals["tokens"] as? Double == 32)
        #expect(totals["cost"] as? Double == 3)
        let bySource = totals["bySource"] as! [String: [String: Double]]
        #expect(bySource["cli"]?["tokens"] == 10)
        #expect(bySource["cli"]?["cost"] == 1)
        #expect(bySource["codex"]?["tokens"] == 22)
        #expect(bySource["codex"]?["cost"] == 2)
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
