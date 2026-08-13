import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@Suite struct UsageHistoryTests {
    private struct MachineAliasEntry {
        let source: String
        let period: String
        let tokens: Double
        let cost: Double
        let path: String
        let sessionID: String
        let sourceMappedProject: Bool
    }

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

    private func machineDocument(
        source: String, machineID: String, machineName: String, tokens: Double, cost: Double
    ) -> Data {
        let detail: [String: Any] = [
            "tokens": tokens, "cost": cost,
            "byModel": ["gpt": ["tokens": tokens, "cost": cost]],
        ]
        let slug = source.split(separator: ":").first.map(String.init) ?? "machine"
        let tool = source.split(separator: ":").last.map(String.init) ?? source
        let project: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "repositoryName": "edith", "repositoryURL": "https://github.com/pulkitxm/edith",
            "folderName": "edith", "path": "/work/edith", "machineName": machineName,
            "machineID": machineID, "tokens": tokens, "cost": cost,
            "bySource": [source: detail],
            "chats": [
                [
                    "id": "\(slug)-main", "path": "/work/edith", "source": source,
                    "tokens": tokens / 2, "cost": cost / 2,
                ]
            ],
            "worktrees": [
                [
                    "name": "feature", "path": "/work/edith/feature", "tokens": tokens / 2,
                    "cost": cost / 2,
                    "chats": [
                        [
                            "id": "\(slug)-worktree", "path": "/work/edith/feature",
                            "source": source, "tokens": tokens / 2, "cost": cost / 2,
                        ]
                    ],
                ]
            ],
        ]
        let obj: [String: Any] = [
            "schemaVersion": 7,
            "generatedAt": "2026-07-06T00:00:00Z",
            "sources": [source],
            "defaultSources": [source],
            "sourceMeta": [
                source: [
                    "label": "\(tool) · \(machineName)", "tool": tool,
                    "machine": machineName, "machineID": machineID,
                ]
            ],
            "totals": ["cost": cost, "tokens": tokens],
            "daily": [
                day(
                    "2026-06-10", bySource: [source: [model("gpt", input: tokens, cost: cost)]],
                    hours: [
                        [
                            "tokens": tokens, "cost": cost, "bySource": [source: detail],
                            "byPath": [
                                "\(slug):/work/edith": [
                                    "tokens": tokens, "cost": cost,
                                    "bySource": [source: detail],
                                ]
                            ],
                        ]
                    ], projects: [project])
            ],
            "sessions": [
                [
                    "id": "shared-session", "source": source, "totalTokens": tokens,
                    "cost": cost,
                ]
            ],
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func replacementDocument(
        machineID: String, machineName: String, host: String,
        tokensByTool: [String: Double], sessionsByTool: [String: [String]]
    ) -> Data {
        let prefix = "machine:\(machineID.lowercased()):"
        let sources = tokensByTool.keys.sorted().map { prefix + $0 }
        let sourceMeta = Dictionary(
            uniqueKeysWithValues: sources.map { source in
                let tool = String(source.split(separator: ":").last ?? "")
                return (
                    source,
                    [
                        "label": "\(tool) · \(machineName)", "tool": tool,
                        "machine": machineName, "machineID": machineID,
                        "machineHost": host,
                    ] as [String: Any]
                )
            })
        let bySource = Dictionary(
            uniqueKeysWithValues: tokensByTool.map { tool, tokens in
                (prefix + tool, [model(tool, input: tokens, cost: tokens / 10)])
            })
        let detailBySource = Dictionary(
            uniqueKeysWithValues: tokensByTool.map { tool, tokens in
                (
                    prefix + tool,
                    [
                        "tokens": tokens, "cost": tokens / 10,
                        "byModel": [tool: ["tokens": tokens, "cost": tokens / 10]],
                    ] as [String: Any]
                )
            })
        let sessions = sessionsByTool.flatMap { tool, ids in
            ids.map { ["id": $0, "source": prefix + tool] }
        }
        let chats = sessions.map { session in
            [
                "id": session["id"] ?? "", "source": session["source"] ?? "",
                "path": "/work", "tokens": 1, "cost": 0.1,
            ] as [String: Any]
        }
        let totalTokens = tokensByTool.values.reduce(0, +)
        let totalCost = totalTokens / 10
        let project: [String: Any] = [
            "projectName": "project", "repositoryID": "github.com/example/project",
            "repositoryName": "project", "folderName": "project", "path": "/work",
            "machineName": machineName, "machineID": machineID,
            "tokens": totalTokens, "cost": totalCost, "bySource": detailBySource,
            "chats": chats, "worktrees": [],
        ]
        let obj: [String: Any] = [
            "schemaVersion": 7,
            "generatedAt": "2026-08-12T00:00:00Z",
            "sources": sources,
            "defaultSources": sources,
            "sourceMeta": sourceMeta,
            "machines": [
                [
                    "id": machineID, "name": machineName, "slug": machineName.lowercased(),
                    "host": host, "sources": sources,
                ]
            ],
            "totals": ["cost": totalCost, "tokens": totalTokens],
            "daily": [
                day(
                    "2026-08-12", bySource: bySource,
                    hours: [
                        [
                            "tokens": totalTokens, "cost": totalCost,
                            "bySource": detailBySource,
                            "byPath": [
                                "/work": [
                                    "tokens": totalTokens, "cost": totalCost,
                                    "bySource": detailBySource,
                                ]
                            ],
                        ]
                    ], projects: [project])
            ],
            "sessions": sessions,
        ]
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    private func machineAliasDocument(
        machineID: String, currentSlug: String, entries: [MachineAliasEntry]
    ) -> Data {
        let sources = Array(Set(entries.map(\.source))).sorted()
        let sourceMeta = Dictionary(
            uniqueKeysWithValues: sources.map { source in
                (
                    source,
                    [
                        "label": source, "tool": "cli", "machine": currentSlug,
                        "machineID": machineID,
                    ] as [String: Any]
                )
            })
        let grouped = Dictionary(grouping: entries, by: \.period)
        let days = grouped.keys.sorted().map { period -> [String: Any] in
            let periodEntries = grouped[period] ?? []
            var bySource: [String: [[String: Any]]] = [:]
            var hourBySource: [String: Any] = [:]
            var byPath: [String: Any] = [:]
            var projects: [[String: Any]] = []
            for entry in periodEntries {
                bySource[entry.source] = [
                    model("m", input: entry.tokens, cost: entry.cost)
                ]
                let detail: [String: Any] = [
                    "tokens": entry.tokens, "cost": entry.cost,
                    "byModel": ["m": ["tokens": entry.tokens, "cost": entry.cost]],
                ]
                hourBySource[entry.source] = detail
                byPath[entry.path] = [
                    "tokens": entry.tokens, "cost": entry.cost,
                    "bySource": [entry.source: detail],
                ]
                var project: [String: Any] = [
                    "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
                    "repositoryName": "edith", "folderName": "edith", "path": entry.path,
                    "machineName": currentSlug, "machineID": machineID,
                    "tokens": entry.tokens, "cost": entry.cost,
                    "chats": [
                        [
                            "id": "\(entry.sessionID)-main", "path": entry.path,
                            "source": entry.source, "tokens": entry.tokens / 2,
                            "cost": entry.cost / 2,
                        ]
                    ],
                    "worktrees": [
                        [
                            "name": "feature", "path": "\(entry.path)/feature",
                            "tokens": entry.tokens / 2, "cost": entry.cost / 2,
                            "chats": [
                                [
                                    "id": "\(entry.sessionID)-worktree",
                                    "path": "\(entry.path)/feature", "source": entry.source,
                                    "tokens": entry.tokens / 2, "cost": entry.cost / 2,
                                ]
                            ],
                        ]
                    ],
                ]
                if entry.sourceMappedProject {
                    project["bySource"] = [entry.source: detail]
                }
                projects.append(project)
            }
            let tokens = periodEntries.reduce(0) { $0 + $1.tokens }
            let cost = periodEntries.reduce(0) { $0 + $1.cost }
            return day(
                period, bySource: bySource,
                hours: [
                    [
                        "tokens": tokens, "cost": cost, "bySource": hourBySource,
                        "byPath": byPath,
                    ]
                ], projects: projects)
        }
        let totalTokens = entries.reduce(0) { $0 + $1.tokens }
        let totalCost = entries.reduce(0) { $0 + $1.cost }
        let obj: [String: Any] = [
            "schemaVersion": 7,
            "generatedAt": "2026-08-11T00:00:00Z",
            "sources": sources,
            "defaultSources": sources,
            "sourceMeta": sourceMeta,
            "machines": [
                ["id": machineID, "name": currentSlug, "slug": currentSlug]
            ],
            "totals": ["cost": totalCost, "tokens": totalTokens],
            "daily": days,
            "sessions": entries.map {
                [
                    "id": $0.sessionID, "source": $0.source,
                    "totalTokens": $0.tokens, "cost": $0.cost,
                ]
            },
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
                    "2026-06-10", bySource: ["commandcode": [model(input: 10, cost: 2)]],
                    hours: [["tokens": 10.0, "cost": 2.0]],
                    projects: [["projectName": "kept", "tokens": 10.0, "cost": 2.0]])
            ], sources: ["commandcode"])
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
            "tokens": 20.0, "cost": 2.0, "bySource": ["tuf:commandcode": tufSource],
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
                        "tuf:commandcode": [model("gpt", input: 20, cost: 2)],
                    ],
                    hours: [
                        [
                            "tokens": 120.0, "cost": 12.0,
                            "bySource": ["cli": staleLocalSource, "tuf:commandcode": tufSource],
                            "byPath": [
                                "/local/edith": [
                                    "tokens": 100.0, "cost": 10.0,
                                    "bySource": ["cli": staleLocalSource],
                                ],
                                "tuf:/home/me/edith": [
                                    "tokens": 20.0, "cost": 2.0,
                                    "bySource": ["tuf:commandcode": tufSource],
                                ],
                            ],
                        ]
                    ], projects: [staleLocalProject, tufProject])
            ], sources: ["cli", "tuf:commandcode"], schemaVersion: 7)

        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let hour = (mergedDay["hours"] as! [[String: Any]]).first!
        let hourSources = hour["bySource"] as! [String: [String: Any]]
        #expect(Set(hourSources.keys) == ["cli", "tuf:commandcode"])
        #expect((hourSources["cli"]?["tokens"] as? Double) == 10)
        #expect((hourSources["tuf:commandcode"]?["tokens"] as? Double) == 20)
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

    @MainActor
    @Test func schemaSevenPreservesCloudOnlyChatsInMatchingProject() throws {
        let cliSource: [String: Any] = [
            "tokens": 10.0, "cost": 1.0,
            "byModel": ["opus": ["tokens": 10.0, "cost": 1.0]],
        ]
        let staleCLI: [String: Any] = [
            "tokens": 100.0, "cost": 10.0,
            "byModel": ["opus": ["tokens": 100.0, "cost": 10.0]],
        ]
        let remoteSource: [String: Any] = [
            "tokens": 20.0, "cost": 2.0,
            "byModel": ["gpt": ["tokens": 20.0, "cost": 2.0]],
        ]
        let identity: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "repositoryName": "edith", "path": "/work/edith", "machineName": "Laptop",
            "machineID": "laptop",
        ]
        var localProject = identity
        localProject["tokens"] = 10.0
        localProject["cost"] = 1.0
        localProject["bySource"] = ["cli": cliSource]
        localProject["chats"] = [
            [
                "id": "local-main", "path": "/work/edith", "source": "cli",
                "tokens": 5.0, "cost": 0.5,
            ]
        ]
        localProject["worktrees"] = [
            [
                "name": "feature", "tokens": 5.0, "cost": 0.5,
                "chats": [
                    [
                        "id": "local-worktree", "path": "/work/edith/feature", "source": "cli",
                        "tokens": 5.0, "cost": 0.5,
                    ]
                ],
            ]
        ]
        var cloudProject = identity
        cloudProject["tokens"] = 120.0
        cloudProject["cost"] = 12.0
        cloudProject["bySource"] = ["cli": staleCLI, "commandcode": remoteSource]
        cloudProject["chats"] = [
            [
                "id": "stale-main", "path": "/work/edith", "source": "cli",
                "tokens": 60.0, "cost": 6.0,
            ],
            [
                "id": "remote-main", "path": "/work/edith", "source": "commandcode",
                "tokens": 8.0, "cost": 0.8,
            ],
        ]
        cloudProject["worktrees"] = [
            [
                "name": "feature", "tokens": 52.0, "cost": 5.2,
                "chats": [
                    [
                        "id": "stale-worktree", "path": "/work/edith/feature",
                        "source": "cli", "tokens": 40.0, "cost": 4.0,
                    ],
                    [
                        "id": "remote-worktree", "path": "/work/edith/feature",
                        "source": "commandcode", "tokens": 12.0, "cost": 1.2,
                    ],
                ],
            ]
        ]
        let local = document(
            days: [
                day(
                    "2026-06-10", bySource: ["cli": [model("opus", input: 10, cost: 1)]],
                    hours: [], projects: [localProject])
            ], sources: ["cli"], schemaVersion: 7)
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [model("opus", input: 100, cost: 10)],
                        "commandcode": [model("gpt", input: 20, cost: 2)],
                    ], hours: [], projects: [cloudProject])
            ], sources: ["cli", "commandcode"], schemaVersion: 7)

        let mergedData = try #require(UsageHistory.merge(local: local, cloud: cloud))
        let merged = decode(mergedData)
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let project = (mergedDay["projects"] as! [[String: Any]]).first!
        let directChats = project["chats"] as! [[String: Any]]
        #expect(
            Set(directChats.compactMap { $0["source"] as? String }) == ["cli", "commandcode"])
        #expect(!directChats.contains { $0["id"] as? String == "stale-main" })
        let worktree = (project["worktrees"] as! [[String: Any]]).first!
        let worktreeChats = worktree["chats"] as! [[String: Any]]
        #expect(
            Set(worktreeChats.compactMap { $0["source"] as? String })
                == ["cli", "commandcode"])
        #expect(!worktreeChats.contains { $0["id"] as? String == "stale-worktree" })
        #expect(worktree["tokens"] as? Double == 17)
        #expect(worktree["cost"] as? Double == 1.7)
        #expect(project["tokens"] as? Double == 30)
        #expect(project["cost"] as? Double == 3)
        let nestedTokens =
            directChats.reduce(0) { $0 + ($1["tokens"] as? Double ?? 0) }
            + worktreeChats.reduce(0) { $0 + ($1["tokens"] as? Double ?? 0) }
        #expect(nestedTokens == 30)

        let dashboardUsage = try JSONDecoder().decode(DashUsage.self, from: mergedData)
        let suite = "UsageHistoryTests.dashboard.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        let dashboard = DashboardModel(preferences: preferences)
        dashboard.ingest(dashboardUsage)
        dashboard.range = .all
        #expect(dashboard.projectTree.count == 1)
        #expect(dashboard.projectTree.first?.id != "repo:unattributed")
        #expect(dashboard.projectTree.first?.tokens == 30)
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

    @Test func replacedMachineHistoryIsNotCountedTwice() throws {
        let oldID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let currentID = "7F2B9AB7-3A0A-4289-9743-6BD57F4D4011"
        let local = replacementDocument(
            machineID: currentID, machineName: "TUF Wired", host: "pulkit-tuf",
            tokensByTool: ["cli": 1, "codex": 2, "opencode": 3, "pi": 4, "future": 5],
            sessionsByTool: [
                "cli": ["cli-1", "cli-2", "cli-3", "cli-4", "cli-5"],
                "codex": ["codex-1"],
                "opencode": ["opencode-1", "opencode-2", "opencode-3", "opencode-4"],
                "pi": ["pi-1"], "future": ["future-1"],
            ])
        let cloud = replacementDocument(
            machineID: oldID, machineName: "TUF", host: "",
            tokensByTool: ["cli": 100, "codex": 200, "opencode": 300],
            sessionsByTool: [
                "cli": ["cli-1", "cli-2", "cli-3", "cli-4", "cli-5"],
                "codex": ["codex-1", "retired-only"],
                "opencode": ["opencode-1", "opencode-2", "opencode-3", "opencode-4"],
            ])

        let mergedData = try #require(UsageHistory.merge(local: local, cloud: cloud))
        let merged = decode(mergedData)
        let currentPrefix = "machine:\(currentID.lowercased()):"
        let expectedSources = Set(
            ["cli", "codex", "opencode", "pi", "future"].map {
                currentPrefix + $0
            })

        #expect(Set(merged["sources"] as? [String] ?? []) == expectedSources)
        #expect(Set(merged["defaultSources"] as? [String] ?? []) == expectedSources)
        let totals = merged["totals"] as? [String: Any]
        #expect(totals?["tokens"] as? Double == 15)
        let bySource = totals?["bySource"] as? [String: [String: Double]]
        #expect(Set(bySource?.keys.map { $0 } ?? []) == expectedSources)
        #expect(bySource?[currentPrefix + "pi"]?["tokens"] == 4)
        #expect(bySource?[currentPrefix + "future"]?["tokens"] == 5)
        let encoded = String(decoding: mergedData, as: UTF8.self).lowercased()
        #expect(!encoded.contains(oldID.lowercased()))
    }

    @Test func differentMachineHistoryRemainsIndependent() {
        let local = replacementDocument(
            machineID: "11111111-1111-1111-1111-111111111111", machineName: "TUF",
            host: "tuf", tokensByTool: ["cli": 10], sessionsByTool: ["cli": ["a", "b"]])
        let cloud = replacementDocument(
            machineID: "22222222-2222-2222-2222-222222222222", machineName: "Pi",
            host: "pi", tokensByTool: ["cli": 20], sessionsByTool: ["cli": ["c", "d"]])
        let merged = decode(UsageHistory.merge(local: local, cloud: cloud))
        let totals = merged["totals"] as? [String: Any]

        #expect(totals?["tokens"] as? Double == 30)
        #expect((merged["sources"] as? [String])?.count == 2)
    }

    @MainActor
    @Test func renamedMachineSourceUsesStableIdentityWithoutDoubleCounting() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let local = machineDocument(
            source: "gaming:cli", machineID: machineID, machineName: "Gaming", tokens: 40,
            cost: 4)
        let cloud = machineDocument(
            source: "tuf:cli", machineID: machineID, machineName: "TUF", tokens: 900,
            cost: 90)
        let mergedData = try #require(UsageHistory.merge(local: local, cloud: cloud))
        let merged = decode(mergedData)
        let stable = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))

        #expect(merged["sources"] as? [String] == [stable])
        #expect(merged["defaultSources"] as? [String] == [stable])
        let sourceMeta = merged["sourceMeta"] as! [String: [String: Any]]
        #expect(Set(sourceMeta.keys) == [stable])
        #expect(sourceMeta[stable]?["machine"] as? String == "Gaming")

        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let bySource = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(Set(bySource.keys) == [stable])
        #expect(bySource[stable]?.first?["inputTokens"] as? Double == 40)
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["tokens"] as? Double == 40)
        #expect(totals["cost"] as? Double == 4)
        let totalsBySource = totals["bySource"] as! [String: [String: Double]]
        #expect(totalsBySource[stable]?["tokens"] == 40)

        let hour = (mergedDay["hours"] as! [[String: Any]]).first!
        let hourSources = hour["bySource"] as! [String: [String: Any]]
        #expect(Set(hourSources.keys) == [stable])
        #expect(hour["tokens"] as? Double == 40)
        let paths = hour["byPath"] as! [String: [String: Any]]
        #expect(Set(paths.keys) == ["gaming:/work/edith"])
        let pathSources = paths["gaming:/work/edith"]?["bySource"] as! [String: [String: Any]]
        #expect(Set(pathSources.keys) == [stable])

        let project = (mergedDay["projects"] as! [[String: Any]]).first!
        let projectSources = project["bySource"] as! [String: [String: Any]]
        #expect(Set(projectSources.keys) == [stable])
        #expect(project["tokens"] as? Double == 40)
        #expect(project["cost"] as? Double == 4)
        let chats = project["chats"] as! [[String: Any]]
        #expect(chats.map { $0["source"] as? String } == [stable])
        #expect(chats.map { $0["id"] as? String } == ["gaming-main"])
        let worktree = (project["worktrees"] as! [[String: Any]]).first!
        let worktreeChats = worktree["chats"] as! [[String: Any]]
        #expect(worktreeChats.map { $0["source"] as? String } == [stable])
        #expect(worktreeChats.map { $0["id"] as? String } == ["gaming-worktree"])

        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 1)
        #expect(sessions.first?["source"] as? String == stable)
        #expect(sessions.first?["totalTokens"] as? Double == 40)

        let dashboardUsage = try JSONDecoder().decode(DashUsage.self, from: mergedData)
        let suite = "UsageHistoryTests.machineRename.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        let dashboard = DashboardModel(preferences: preferences)
        dashboard.ingest(dashboardUsage)
        dashboard.range = .all
        #expect(dashboard.projectTree.count == 1)
        #expect(dashboard.projectTree.first?.id != "repo:unattributed")
        #expect(dashboard.projectTree.first?.tokens == 40)
    }

    @Test func oneSidedMachineAliasCollisionKeepsCurrentDetail() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let document = machineAliasDocument(
            machineID: machineID, currentSlug: "gaming",
            entries: [
                MachineAliasEntry(
                    source: "tuf:cli", period: "2026-08-11", tokens: 900, cost: 90,
                    path: "tuf:/work/edith", sessionID: "shared", sourceMappedProject: false),
                MachineAliasEntry(
                    source: "gaming:cli", period: "2026-08-11", tokens: 40, cost: 4,
                    path: "gaming:/work/edith", sessionID: "shared",
                    sourceMappedProject: true),
            ])
        let merged = decode(UsageHistory.merge(local: nil, cloud: document))
        let stable = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))

        #expect(merged["sources"] as? [String] == [stable])
        #expect(merged["defaultSources"] as? [String] == [stable])
        let sourceMeta = merged["sourceMeta"] as! [String: [String: Any]]
        #expect(Set(sourceMeta.keys) == [stable])

        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let canonical = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(canonical[stable]?.first?["inputTokens"] as? Double == 40)
        let hour = (mergedDay["hours"] as! [[String: Any]]).first!
        #expect(hour["tokens"] as? Double == 40)
        let paths = hour["byPath"] as! [String: [String: Any]]
        #expect(Set(paths.keys) == ["gaming:/work/edith"])

        let projects = mergedDay["projects"] as! [[String: Any]]
        #expect(projects.count == 1)
        #expect(projects.first?["path"] as? String == "gaming:/work/edith")
        #expect(projects.first?["tokens"] as? Double == 40)
        let chats = projects.first?["chats"] as! [[String: Any]]
        #expect(chats.map { $0["source"] as? String } == [stable])
        let worktrees = projects.first?["worktrees"] as! [[String: Any]]
        #expect(worktrees.count == 1)
        let worktreeChats = worktrees.first?["chats"] as! [[String: Any]]
        #expect(worktreeChats.map { $0["source"] as? String } == [stable])

        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 1)
        #expect(sessions.first?["source"] as? String == stable)
        #expect(sessions.first?["totalTokens"] as? Double == 40)
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["tokens"] as? Double == 40)
        #expect(totals["cost"] as? Double == 4)
    }

    @Test func historicalMachineAliasesSurviveOnSeparateDays() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let document = machineAliasDocument(
            machineID: machineID, currentSlug: "gaming",
            entries: [
                MachineAliasEntry(
                    source: "tuf:cli", period: "2026-05-01", tokens: 900, cost: 90,
                    path: "tuf:/work/edith", sessionID: "old", sourceMappedProject: false),
                MachineAliasEntry(
                    source: "gaming:cli", period: "2026-08-11", tokens: 40, cost: 4,
                    path: "gaming:/work/edith", sessionID: "current",
                    sourceMappedProject: false),
            ])
        let merged = decode(UsageHistory.merge(local: nil, cloud: document))
        let stable = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))
        let days = merged["daily"] as! [[String: Any]]

        #expect(days.count == 2)
        #expect(days.map { UsageHistory.dayTokens($0) } == [900, 40])
        for day in days {
            let canonical = day["bySource"] as! [String: [[String: Any]]]
            #expect(Set(canonical.keys) == [stable])
            let projects = day["projects"] as! [[String: Any]]
            #expect(projects.count == 1)
            let chats = projects.first?["chats"] as! [[String: Any]]
            #expect(chats.map { $0["source"] as? String } == [stable])
            let worktrees = projects.first?["worktrees"] as! [[String: Any]]
            #expect(worktrees.count == 1)
        }
        let firstPaths =
            (days[0]["hours"] as! [[String: Any]])[0]["byPath"]
            as! [String: Any]
        let secondPaths =
            (days[1]["hours"] as! [[String: Any]])[0]["byPath"]
            as! [String: Any]
        #expect(Set(firstPaths.keys) == ["tuf:/work/edith"])
        #expect(Set(secondPaths.keys) == ["gaming:/work/edith"])
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 2)
        #expect(Set(sessions.compactMap { $0["source"] as? String }) == [stable])
        let totals = merged["totals"] as! [String: Any]
        #expect(totals["tokens"] as? Double == 940)
        #expect(totals["cost"] as? Double == 94)
    }

    @Test func canonicalMachineSourceWinsAliasCollisions() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let stable = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))
        let document = machineAliasDocument(
            machineID: machineID, currentSlug: "gaming",
            entries: [
                MachineAliasEntry(
                    source: "tuf:cli", period: "2026-08-11", tokens: 900, cost: 90,
                    path: "tuf:/work/edith", sessionID: "shared", sourceMappedProject: true),
                MachineAliasEntry(
                    source: "gaming:cli", period: "2026-08-11", tokens: 40, cost: 4,
                    path: "gaming:/work/edith", sessionID: "shared",
                    sourceMappedProject: true),
                MachineAliasEntry(
                    source: stable, period: "2026-08-11", tokens: 12, cost: 1.2,
                    path: "stable:/work/edith", sessionID: "shared",
                    sourceMappedProject: true),
            ])
        let merged = decode(UsageHistory.merge(local: nil, cloud: document))
        let day = (merged["daily"] as! [[String: Any]]).first!
        let canonical = day["bySource"] as! [String: [[String: Any]]]

        #expect(canonical[stable]?.first?["inputTokens"] as? Double == 12)
        let paths = ((day["hours"] as! [[String: Any]])[0]["byPath"] as! [String: Any])
        #expect(Set(paths.keys) == ["stable:/work/edith"])
        let projects = day["projects"] as! [[String: Any]]
        #expect(projects.map { $0["path"] as? String } == ["stable:/work/edith"])
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(sessions.count == 1)
        #expect(sessions.first?["totalTokens"] as? Double == 12)
        #expect((merged["totals"] as! [String: Any])["tokens"] as? Double == 12)
    }

    @Test func oneSidedHistoryRemovesUnsafeCodexDetail() {
        let cliDetail: [String: Any] = [
            "tokens": 10.0, "cost": 1.0,
            "byModel": ["opus": ["tokens": 10.0, "cost": 1.0]],
        ]
        let codexDetail: [String: Any] = [
            "tokens": 20.0, "cost": 2.0,
            "byModel": ["gpt": ["tokens": 20.0, "cost": 2.0]],
        ]
        let sharedProject: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "path": "/work/edith", "tokens": 30.0, "cost": 3.0,
            "bySource": ["cli": cliDetail, "codex": codexDetail],
            "chats": [
                ["id": "cli", "source": "cli", "tokens": 10.0, "cost": 1.0],
                ["id": "codex", "source": "codex", "tokens": 20.0, "cost": 2.0],
            ],
            "worktrees": [
                [
                    "name": "replay", "tokens": 20.0, "cost": 2.0,
                    "chats": [
                        [
                            "id": "codex-worktree", "source": "codex", "tokens": 20.0,
                            "cost": 2.0,
                        ]
                    ],
                ]
            ],
        ]
        let codexProject: [String: Any] = [
            "projectName": "codex-only", "path": "/work/codex", "tokens": 20.0,
            "cost": 2.0, "bySource": ["codex": codexDetail],
            "chats": [
                ["id": "codex-only", "source": "codex", "tokens": 20.0, "cost": 2.0]
            ],
        ]
        let cloud = document(
            days: [
                day(
                    "2026-06-10",
                    bySource: [
                        "cli": [model("opus", input: 10, cost: 1)],
                        "codex": [model("gpt", input: 20, cost: 2)],
                    ],
                    hours: [
                        [
                            "tokens": 30.0, "cost": 3.0,
                            "bySource": ["cli": cliDetail, "codex": codexDetail],
                            "byPath": [
                                "/work/edith": [
                                    "tokens": 30.0, "cost": 3.0,
                                    "bySource": ["cli": cliDetail, "codex": codexDetail],
                                ],
                                "/work/codex": [
                                    "tokens": 20.0, "cost": 2.0,
                                    "bySource": ["codex": codexDetail],
                                ],
                            ],
                        ],
                        ["tokens": 30.0, "cost": 3.0],
                    ], projects: [sharedProject, codexProject])
            ], sources: ["cli", "codex"], schemaVersion: 7)

        let merged = decode(UsageHistory.merge(local: nil, cloud: cloud))
        let mergedDay = (merged["daily"] as! [[String: Any]]).first!
        let canonical = mergedDay["bySource"] as! [String: [[String: Any]]]
        #expect(canonical["codex"]?.first?["inputTokens"] as? Double == 20)
        #expect((merged["totals"] as! [String: Any])["tokens"] as? Double == 30)

        let hours = mergedDay["hours"] as! [[String: Any]]
        let firstHourSources = hours[0]["bySource"] as! [String: [String: Any]]
        #expect(Set(firstHourSources.keys) == ["cli"])
        #expect(hours[0]["tokens"] as? Double == 10)
        let paths = hours[0]["byPath"] as! [String: [String: Any]]
        #expect(Set(paths.keys) == ["/work/edith"])
        #expect(hours[1]["tokens"] as? Double == 0)

        let projects = mergedDay["projects"] as! [[String: Any]]
        #expect(projects.count == 1)
        #expect(projects[0]["tokens"] as? Double == 10)
        let projectSources = projects[0]["bySource"] as! [String: [String: Any]]
        #expect(Set(projectSources.keys) == ["cli"])
        let chats = projects[0]["chats"] as! [[String: Any]]
        #expect(chats.map { $0["source"] as? String } == ["cli"])
        #expect((projects[0]["worktrees"] as! [[String: Any]]).isEmpty)
    }

    @Test func reconciledDetailSurvivesCloudSyncAcrossSources() throws {
        let opencode = "machine:4303dcf1-52d8-4075-ae9b-c2fd86d3821a:opencode"
        let pi = "machine:4303dcf1-52d8-4075-ae9b-c2fd86d3821a:pi"
        let codexDetail: [String: Any] = [
            "tokens": 20.0, "cost": 2.0,
            "byModel": ["gpt": ["tokens": 20.0, "cost": 2.0]],
        ]
        let opencodeDetail: [String: Any] = [
            "tokens": 30.0, "cost": 3.0,
            "byModel": ["gpt": ["tokens": 30.0, "cost": 3.0]],
        ]
        let piDetail: [String: Any] = [
            "tokens": 4.0, "cost": 0.4,
            "byModel": ["gpt": ["tokens": 4.0, "cost": 0.4]],
        ]
        let sourceDetails = ["codex": codexDetail, opencode: opencodeDetail, pi: piDetail]
        let project: [String: Any] = [
            "projectName": "edith", "repositoryID": "github.com/pulkitxm/edith",
            "repositoryName": "edith", "folderName": "edith", "path": "/work/edith",
            "tokens": 54.0, "cost": 5.4, "bySource": sourceDetails,
            "chats": [
                [
                    "id": "codex-session", "path": "/work/edith", "source": "codex",
                    "tokens": 20.0, "cost": 2.0,
                ],
                [
                    "id": "opencode-session", "path": "/work/edith", "source": opencode,
                    "tokens": 30.0, "cost": 3.0,
                ],
                [
                    "id": "pi-session", "path": "/work/edith", "source": pi,
                    "tokens": 4.0, "cost": 0.4,
                ],
            ],
            "worktrees": [],
        ]
        let usageDay = day(
            "2026-08-12",
            bySource: [
                "codex": [model("gpt", input: 20, cost: 2)],
                opencode: [model("gpt", input: 30, cost: 3)],
                pi: [model("gpt", input: 4, cost: 0.4)],
            ],
            hours: [
                [
                    "tokens": 54.0, "cost": 5.4, "bySource": sourceDetails,
                    "byPath": [
                        "/work/edith": [
                            "tokens": 54.0, "cost": 5.4, "bySource": sourceDetails,
                        ]
                    ],
                ]
            ], projects: [project])
        let sources = ["codex", opencode, pi]
        let reconciled = document(
            days: [usageDay], sources: sources, schemaVersion: 8)
        let legacy = document(days: [usageDay], sources: sources, schemaVersion: 7)
        let outputs = [
            try #require(UsageHistory.merge(local: reconciled, cloud: nil)),
            try #require(UsageHistory.merge(local: nil, cloud: reconciled)),
            try #require(UsageHistory.merge(local: reconciled, cloud: legacy)),
        ]

        for output in outputs {
            let merged = decode(output)
            #expect(merged["schemaVersion"] as? Int == 8)
            let mergedDay = try #require((merged["daily"] as? [[String: Any]])?.first)
            let hour = try #require((mergedDay["hours"] as? [[String: Any]])?.first)
            let hourSources = try #require(hour["bySource"] as? [String: [String: Any]])
            #expect(hourSources["codex"]?["tokens"] as? Double == 20)
            #expect(hourSources[opencode]?["tokens"] as? Double == 30)
            #expect(hourSources[pi]?["tokens"] as? Double == 4)
            let projects = try #require(mergedDay["projects"] as? [[String: Any]])
            #expect(projects.count == 1)
            let projectSources = try #require(
                projects.first?["bySource"] as? [String: [String: Any]])
            #expect(projectSources["codex"]?["tokens"] as? Double == 20)
            #expect(projectSources[opencode]?["tokens"] as? Double == 30)
            #expect(projectSources[pi]?["tokens"] as? Double == 4)
            let chats = try #require(projects.first?["chats"] as? [[String: Any]])
            #expect(Set(chats.compactMap { $0["source"] as? String }) == Set(sources))
        }
    }

    @Test func missingSideReturnsOtherVerbatim() {
        let local = usage(days: [("2026-06-10", 100, 1)])
        #expect(UsageHistory.merge(local: local, cloud: nil) == local)
        #expect(UsageHistory.merge(local: nil, cloud: local) == local)
        #expect(UsageHistory.merge(local: nil, cloud: nil) == nil)
    }

    @Test func oneSidedHistoryPrunesUnusedMachineSources() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        var obj = decode(
            machineAliasDocument(
                machineID: machineID, currentSlug: "gaming",
                entries: [
                    MachineAliasEntry(
                        source: "gaming:cli", period: "2026-06-10", tokens: 10, cost: 1,
                        path: "gaming:/work/edith", sessionID: "kept",
                        sourceMappedProject: true)
                ]))
        let stableCLI = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))
        let stableCodex = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "codex"))
        obj["sources"] = ["gaming:cli", stableCodex, "cowork"]
        obj["defaultSources"] = ["gaming:cli", stableCodex, "cowork"]
        var sourceMeta = obj["sourceMeta"] as! [String: Any]
        sourceMeta[stableCodex] = ["tool": "Codex", "machineID": machineID]
        sourceMeta["cowork"] = ["tool": "Claude Code"]
        obj["sourceMeta"] = sourceMeta
        var sessions = obj["sessions"] as! [[String: Any]]
        sessions.append(["id": "stale", "source": stableCodex])
        sessions.append(["id": "generic", "source": "cowork"])
        obj["sessions"] = sessions
        let encoded = try JSONSerialization.data(withJSONObject: obj)
        let merged = decode(UsageHistory.merge(local: nil, cloud: encoded))

        #expect(merged["sources"] as? [String] == [stableCLI, "cowork"])
        #expect(merged["defaultSources"] as? [String] == [stableCLI, "cowork"])
        let mergedSourceMeta = merged["sourceMeta"] as! [String: Any]
        #expect(Set(mergedSourceMeta.keys) == [stableCLI, "cowork"])
        let mergedSessions = merged["sessions"] as! [[String: Any]]
        #expect(
            mergedSessions.map { $0["id"] as? String } == ["kept", "stale", "generic"])
    }

    @Test func twoSidedMergeRetainsSessionOnlyMachineHistory() throws {
        let machineID = "4303DCF1-52D8-4075-AE9B-C2FD86D3821A"
        let local = machineAliasDocument(
            machineID: machineID, currentSlug: "gaming",
            entries: [
                MachineAliasEntry(
                    source: "gaming:cli", period: "2026-06-10", tokens: 10, cost: 1,
                    path: "gaming:/work/edith", sessionID: "current",
                    sourceMappedProject: true)
            ])
        var cloud = decode(
            machineAliasDocument(
                machineID: machineID, currentSlug: "gaming",
                entries: [
                    MachineAliasEntry(
                        source: "tuf:cli", period: "2026-05-01", tokens: 8, cost: 0.8,
                        path: "tuf:/work/edith", sessionID: "historical",
                        sourceMappedProject: true)
                ]))
        cloud["daily"] = []
        cloud["totals"] = ["tokens": 0, "cost": 0]
        let cloudData = try JSONSerialization.data(withJSONObject: cloud)
        let merged = decode(UsageHistory.merge(local: local, cloud: cloudData))
        let stable = try #require(
            MachineUsageSourceIdentity.canonical(machineID: machineID, source: "cli"))

        #expect(merged["sources"] as? [String] == [stable])
        let sessions = merged["sessions"] as! [[String: Any]]
        #expect(Set(sessions.compactMap { $0["id"] as? String }) == ["current", "historical"])
        #expect(Set(sessions.compactMap { $0["source"] as? String }) == [stable])
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
