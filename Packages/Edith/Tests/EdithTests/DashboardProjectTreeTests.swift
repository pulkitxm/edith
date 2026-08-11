import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct DashboardProjectTreeTests {
    private func model(_ json: String) throws -> DashboardModel {
        let suite = "DashboardProjectTreeTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        let parsed = try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8))
        let m = DashboardModel(preferences: preferences)
        m.ingest(parsed)
        m.range = .all
        return m
    }

    private var todayStr: String { DashboardModel.ymd.string(from: Date()) }

    private func chat(
        _ id: String, tokens: Double, cost: Double = 1, title: String? = nil,
        source: String? = nil, path: String? = nil, firstTs: Double? = nil, lastTs: Double? = nil
    ) -> String {
        var fields = ["\"id\":\"\(id)\"", "\"tokens\":\(tokens)", "\"cost\":\(cost)"]
        if let title { fields.append("\"title\":\"\(title)\"") }
        if let source { fields.append("\"source\":\"\(source)\"") }
        if let path { fields.append("\"path\":\"\(path)\"") }
        if let firstTs { fields.append("\"firstTs\":\(firstTs)") }
        if let lastTs { fields.append("\"lastTs\":\(lastTs)") }
        return "{\(fields.joined(separator: ","))}"
    }

    private func usage(daily: String) -> String {
        """
        {"schemaVersion":4,"sources":["cli","codex"],
         "sourceMeta":{"cli":{"label":"Claude Code"},"codex":{"label":"Codex"}},
         "daily":[\(daily)]}
        """
    }

    private func day(_ period: String, projects: String, bySource: String? = nil) -> String {
        var objects =
            (try? JSONSerialization.jsonObject(with: Data("[\(projects)]".utf8)))
            as? [[String: Any]] ?? []
        for index in objects.indices where objects[index]["bySource"] == nil {
            let tokens = (objects[index]["tokens"] as? NSNumber)?.doubleValue ?? 0
            let cost = (objects[index]["cost"] as? NSNumber)?.doubleValue ?? 0
            objects[index]["bySource"] = [
                "cli": [
                    "tokens": tokens,
                    "cost": cost,
                    "byModel": ["m": ["tokens": tokens, "cost": cost]],
                ]
            ]
        }
        let tokens = objects.reduce(0.0) { $0 + (($1["tokens"] as? NSNumber)?.doubleValue ?? 0) }
        let cost = objects.reduce(0.0) { $0 + (($1["cost"] as? NSNumber)?.doubleValue ?? 0) }
        let encodedProjects =
            (try? JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        let sources =
            bySource
                ?? """
                "cli":[{"modelName":"m","inputTokens":\(tokens),"outputTokens":0,
                  "cacheCreationTokens":0,"cacheReadTokens":0,"cost":\(cost)}]
                """
        return """
            {"period":"\(period)",
             "bySource":{\(sources)},
             "projects":\(encodedProjects)}
            """
    }

    @Test func chatFragmentsMergeAcrossDays() throws {
        let d1 = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":100,"cost":1,
                 "chats":[\(chat("abc", tokens: 100, title: "Fix bug", firstTs: 1000, lastTs: 5000))]}
                """)
        let d2 = day(
            "2026-06-02",
            projects: """
                {"projectName":"app","tokens":50,"cost":1,
                 "chats":[\(chat("abc", tokens: 50, firstTs: 90000, lastTs: 95000))]}
                """)
        let m = try model(usage(daily: "\(d1),\(d2)"))
        let proj = try #require(m.projectTree.first)
        #expect(proj.chats.count == 1)
        let c = proj.chats[0]
        #expect(c.tokens == 150)
        #expect(c.title == "Fix bug")
        #expect(c.days == 2)
        #expect(c.lastActive == "2026-06-02")
        #expect(c.dur == 94000)
    }

    @Test func worktreeGroupingAndNestedCount() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":300,"cost":3,
                 "chats":[\(chat("main1", tokens: 100))],
                 "worktrees":[{"name":"feat","tokens":200,"cost":2,
                   "chats":[\(chat("wt1", tokens: 150)),\(chat("wt2", tokens: 50))]}]}
                """)
        let m = try model(usage(daily: d))
        let proj = try #require(m.projectTree.first)
        #expect(proj.nestedCount == 5)
        #expect(proj.worktrees.count == 1)
        #expect(proj.worktrees[0].tokens == 200)
        #expect(proj.worktrees[0].chats.count == 2)
        #expect(proj.tokens == 300)
    }

    @Test func bareChatsFallBackToDayTotals() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"legacy","tokens":500,"cost":5,
                 "chats":[{"id":"deadbeef-1234"}]}
                """)
        let m = try model(usage(daily: d))
        let proj = try #require(m.projectTree.first)
        #expect(proj.tokens == 500)
        #expect(proj.cost == 5)
        #expect(proj.days == 1)
        #expect(proj.chats[0].title == "Chat deadbeef")
    }

    @Test func projectWithoutChatsKeptViaFallback() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"v3-era","tokens":700,"cost":7}
                """)
        let m = try model(usage(daily: d))
        let proj = try #require(m.projectTree.first)
        #expect(proj.tokens == 700)
        #expect(proj.expandable)
        #expect(proj.folders.first?.expandable == false)
    }

    @Test func emptyChatIdTitledUntitled() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":10,"cost":1,"chats":[\(chat("", tokens: 10))]}
                """)
        let m = try model(usage(daily: d))
        #expect(m.projectTree.first?.chats.first?.title == "Untitled chat")
    }

    @Test func sourceFilterHidesChatsAndRecomputesTotals() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":300,"cost":3,
                 "chats":[\(chat("a", tokens: 100, source: "cli")),
                          \(chat("b", tokens: 150, source: "codex")),
                          \(chat("c", tokens: 50))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":150,"cost":1.5}],
                "codex":[{"modelName":"m","inputTokens":150,"cost":1.5}]
                """)
        let m = try model(usage(daily: d))
        m.selectedSources = ["cli"]
        let proj = try #require(m.projectTree.first)
        #expect(proj.chats.count == 2)
        #expect(proj.tokens == 150)
        #expect(!proj.chats.contains { $0.id == "b" })
    }

    @Test func projectDroppedWhenAllChatsFiltered() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"only-codex","tokens":100,"cost":1,
                 "chats":[\(chat("x", tokens: 100, source: "codex"))]}
                """,
            bySource: """
                "codex":[{"modelName":"m","inputTokens":100,"cost":1}]
                """)
        let m = try model(usage(daily: d))
        m.selectedSources = ["cli"]
        #expect(m.projectTree.isEmpty)
    }

    @Test func worktreeDroppedWhenAllItsChatsFiltered() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":300,"cost":3,
                 "chats":[\(chat("a", tokens: 100, source: "cli"))],
                 "worktrees":[{"name":"feat","tokens":200,"cost":2,
                   "chats":[\(chat("w", tokens: 200, source: "codex"))]}]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":100,"cost":1}],
                "codex":[{"modelName":"m","inputTokens":200,"cost":2}]
                """)
        let m = try model(usage(daily: d))
        m.selectedSources = ["cli"]
        let proj = try #require(m.projectTree.first)
        #expect(proj.worktrees.isEmpty)
        #expect(proj.tokens == 100)
    }

    @Test func sharesSumToOneAcrossVisibleProjects() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"a","tokens":100,"cost":30,"chats":[\(chat("a1", tokens: 100, cost: 30))]},
                {"projectName":"b","tokens":200,"cost":70,"chats":[\(chat("b1", tokens: 200, cost: 70))]}
                """)
        let m = try model(usage(daily: d))
        let total = m.projectTree.reduce(0) { $0 + $1.share }
        #expect(abs(total - 1) < 0.0001)
        #expect(abs((m.projectTree.first { $0.name == "b" }?.share ?? 0) - 0.7) < 0.0001)
    }

    @Test func defaultSortIsCostDescending() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"cheap","tokens":900,"cost":1,"chats":[\(chat("c1", tokens: 900, cost: 1))]},
                {"projectName":"pricey","tokens":100,"cost":9,"chats":[\(chat("p1", tokens: 100, cost: 9))]}
                """)
        let m = try model(usage(daily: d))
        #expect(m.projectTree.map(\.name) == ["pricey", "cheap"])
        m.projSortKey = .tokens
        #expect(m.projectTree.map(\.name) == ["cheap", "pricey"])
        m.projSortKey = .name
        m.projSortAscending = true
        #expect(m.projectTree.map(\.name) == ["cheap", "pricey"])
    }

    @Test func chatsSortedWithinProjectBySortKey() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":300,"cost":3,
                 "chats":[\(chat("small", tokens: 10, cost: 5)),\(chat("big", tokens: 200, cost: 1))]}
                """)
        let m = try model(usage(daily: d))
        m.projSortKey = .tokens
        m.projSortAscending = false
        #expect(m.projectTree.first?.chats.map(\.id) == ["big", "small"])
        m.projSortKey = .cost
        #expect(m.projectTree.first?.chats.map(\.id) == ["small", "big"])
    }

    @Test func durationZeroWhenTimestampsMissingOrInverted() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"app","tokens":20,"cost":1,
                 "chats":[\(chat("noTs", tokens: 10)),
                          \(chat("inverted", tokens: 10, firstTs: 9000, lastTs: 1000))]}
                """)
        let m = try model(usage(daily: d))
        for c in m.projectTree.first?.chats ?? [] {
            #expect(c.dur == 0)
        }
    }

    @Test func resetClearsDrilldownState() throws {
        let m = try model(usage(daily: day("2026-06-01", projects: "")))
        m.projSortKey = .name
        m.projSortAscending = true
        m.projListOpen = true
        m.projExpanded = ["proj:x"]
        m.reset()
        #expect(m.projSortKey == .cost)
        #expect(m.projSortAscending == false)
        #expect(m.projListOpen == false)
        #expect(m.projExpanded.isEmpty)
    }

    @Test func missingHourlyDetailRemainsUnattributed() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"inflated","tokens":700,"cost":70,
                 "chats":[\(chat("x", tokens: 700, cost: 70, source: "cli"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":100,"cost":10}]
                """)
        let m = try model(usage(daily: d))
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.cost } - 10) < 0.0001)
        #expect(m.hourlyAll.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
        #expect(abs(m.hourlyUnattributedTokens - 100) < 0.0001)
        #expect(abs(m.hourlyUnattributedCost - 10) < 0.0001)
    }

    @Test func todayRangeRestrictsActivityToOnePaddedWeek() throws {
        let first = day(
            "2026-06-01",
            projects: """
                {"projectName":"old","tokens":100,"cost":1,
                 "chats":[\(chat("old", tokens: 100, source: "cli"))]}
                """)
        let latest = day(
            todayStr,
            projects: """
                {"projectName":"new","tokens":200,"cost":2,
                 "chats":[\(chat("new", tokens: 200, source: "cli"))]}
                """)
        let m = try model(usage(daily: "\(first),\(latest)"))
        m.range = .today
        #expect(Set(m.heatDetail.keys) == [todayStr])
        #expect(m.calendarDays.count == 7)
        #expect(m.projectTree.map(\.name) == ["new"])
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.tokens } - 200) < 0.0001)
        let detail = try #require(m.heatDetail[todayStr])
        #expect(abs(detail.projects.reduce(0) { $0 + $1.value } - 200) < 0.0001)
    }

    @Test func inflatedDayDoesNotShrinkOtherDaysProjects() throws {
        let noisy = day(
            "2026-06-01",
            projects: """
                {"projectName":"noisy","tokens":10000,"cost":100,
                 "chats":[\(chat("n", tokens: 10000, cost: 100, source: "codex"))]},
                {"projectName":"orbit","tokens":100,"cost":1,
                 "chats":[\(chat("o1", tokens: 100, cost: 1, source: "cli"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":50,"cost":0.5}],
                "codex":[{"modelName":"m","inputTokens":50,"cost":0.5}]
                """)
        let quiet = day(
            todayStr,
            projects: """
                {"projectName":"orbit","tokens":200,"cost":2,
                 "chats":[\(chat("o2", tokens: 200, cost: 2, source: "cli"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":200,"cost":2}]
                """)
        let m = try model(usage(daily: "\(noisy),\(quiet)"))
        let allTime = try #require(m.projectTree.first { $0.name == "orbit" }?.tokens)
        m.range = .today
        let today = try #require(m.projectTree.first { $0.name == "orbit" }?.tokens)
        #expect(abs(today - 200) < 0.0001)
        #expect(allTime >= today)
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.tokens } - 200) < 0.0001)
    }

    @Test func folderScopeCoversNestedPathsAndScopesSeries() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"orbit","path":"/drive/orbit","tokens":300,"cost":3,
                 "chats":[\(chat("o", tokens: 100, cost: 1, source: "cli", path: "/drive/orbit"))],
                 "worktrees":[{"name":"agent-1","tokens":200,"cost":2,
                   "chats":[\(chat("a", tokens: 200, cost: 2, source: "cli", path: "/drive/orbit/.claude/worktrees/agent-1"))]}]},
                {"projectName":"other","path":"/drive/other","tokens":700,"cost":7,
                 "chats":[\(chat("x", tokens: 700, cost: 7, source: "cli", path: "/drive/other"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":1000,"cost":10}]
                """)
        let m = try model(usage(daily: d))
        #expect(m.allProjectPaths.map(\.path).sorted() == ["/drive/orbit", "/drive/other"])

        m.selectedPaths = ["/drive/orbit"]
        #expect(m.projectTree.map(\.name) == ["orbit"])
        #expect(m.projectTree.first?.worktrees.map(\.name) == ["agent-1"])
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 300) < 0.0001)
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.tokens } - 300) < 0.0001)
        #expect(abs(m.modelTotals.reduce(0) { $0 + $1.cost } - 3) < 0.0001)

        m.selectedPaths = ["/drive"]
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 1000) < 0.0001)
        m.selectedPaths = ["/drive/orbit/.claude/worktrees/agent-1"]
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 200) < 0.0001)
        #expect(m.projectTree.first?.chats.isEmpty == true)
        m.selectedPaths = []
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 1000) < 0.0001)
    }

    @Test func folderScopeBackfillsPathsForOlderDays() throws {
        let legacy = day(
            "2026-06-01",
            projects: """
                {"projectName":"orbit","tokens":100,"cost":1,
                 "chats":[\(chat("old", tokens: 100, cost: 1, source: "cli"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":100,"cost":1}]
                """)
        let current = day(
            "2026-06-02",
            projects: """
                {"projectName":"orbit","path":"/drive/orbit","tokens":200,"cost":2,
                 "chats":[\(chat("new", tokens: 200, cost: 2, source: "cli", path: "/drive/orbit"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":200,"cost":2}]
                """)
        let m = try model(usage(daily: "\(legacy),\(current)"))
        m.selectedPaths = ["/drive/orbit"]
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 200) < 0.0001)
    }

    @Test func modelFilterUpdatesActivityAndUnattributedHours() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"mixed","tokens":1000,"cost":100,
                 "bySource":{"cli":{"tokens":400,"cost":40,
                   "byModel":{"a":{"tokens":100,"cost":10},
                              "b":{"tokens":300,"cost":30}}}},
                 "chats":[\(chat("x", tokens: 1000, cost: 100, source: "cli"))]}
                """,
            bySource: """
                "cli":[
                  {"modelName":"a","inputTokens":100,"cost":10},
                  {"modelName":"b","inputTokens":300,"cost":30}
                ]
                """)
        let m = try model(usage(daily: d))
        m.selectedModels = ["a"]
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
        #expect(abs(m.projectTree.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
        #expect(m.hourlyAll.allSatisfy { $0.tokens == 0 })
        #expect(abs(m.hourlyUnattributedTokens - 100) < 0.0001)
        let detail = try #require(m.heatDetail["2026-06-01"])
        #expect(abs(detail.tokens - 100) < 0.0001)
        #expect(detail.models.map(\.id) == ["a"])
        #expect(abs(detail.projects.reduce(0) { $0 + $1.value } - 100) < 0.0001)
        #expect(detail.chatCount == 0)
    }

    @Test func sameRepositoryAcrossMachinesHasSeparateFolders() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"local checkout","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","repositoryURL":"https://github.com/acme/orbit",
                 "folderName":"orbit","path":"/Users/me/orbit","machineName":"Laptop",
                 "machineID":"local","tokens":100,"cost":1},
                {"projectName":"remote checkout","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","repositoryURL":"https://github.com/acme/orbit",
                 "folderName":"orbit","path":"/home/me/orbit","machineName":"TUF",
                 "machineID":"tuf","tokens":200,"cost":2}
                """)
        let m = try model(usage(daily: d))
        let repository = try #require(m.projectTree.first)
        #expect(m.projectTree.count == 1)
        #expect(repository.name == "orbit")
        #expect(repository.repositoryURL == "https://github.com/acme/orbit")
        #expect(repository.folders.count == 2)
        #expect(Set(repository.folders.map(\.machineName)) == ["Laptop", "TUF"])
        #expect(abs(repository.folders.reduce(0) { $0 + $1.tokens } - 300) < 0.0001)
    }

    @Test func remoteFolderPathsPreserveCase() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"Edith","repositoryID":"github.com/acme/edith",
                 "repositoryName":"edith","path":"machine:tuf:/work/Edith",
                 "machineName":"TUF","machineID":"tuf","tokens":100,"cost":1},
                {"projectName":"edith","repositoryID":"github.com/acme/edith",
                 "repositoryName":"edith","path":"machine:tuf:/work/edith",
                 "machineName":"TUF","machineID":"tuf","tokens":200,"cost":2}
                """)
        let m = try model(usage(daily: d))
        let repository = try #require(m.projectTree.first)
        #expect(repository.folders.count == 2)
        #expect(
            Set(repository.folders.map(\.path)) == [
                "machine:tuf:/work/Edith", "machine:tuf:/work/edith",
            ])

        m.selectedPaths = ["machine:tuf:/work/Edith"]
        #expect(m.projectTree.count == 1)
        #expect(m.projectTree[0].folders.map(\.path) == ["machine:tuf:/work/Edith"])
        #expect(abs(m.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func repositoriesWithSameNameAndDifferentIDsStaySeparate() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"one","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","folderName":"one","path":"/one",
                 "tokens":100,"cost":1},
                {"projectName":"two","repositoryID":"github:other/orbit",
                 "repositoryName":"orbit","folderName":"two","path":"/two",
                 "tokens":200,"cost":2}
                """)
        let m = try model(usage(daily: d))
        #expect(m.projectTree.count == 2)
        #expect(m.projectTree.map(\.name) == ["orbit", "orbit"])
        #expect(Set(m.projectTree.map(\.id)).count == 2)
    }

    @Test func sourceFilterRemovesOnlyItsRepositoryFolders() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"local","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","folderName":"local","path":"/local/orbit",
                 "machineName":"Laptop","tokens":100,"cost":1,
                 "bySource":{"cli":{"tokens":100,"cost":1,
                   "byModel":{"m":{"tokens":100,"cost":1}}}},
                 "chats":[\(chat("local", tokens: 100, source: "cli"))]},
                {"projectName":"remote","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","folderName":"remote","path":"/remote/orbit",
                 "machineName":"TUF","tokens":200,"cost":2,
                 "bySource":{"codex":{"tokens":200,"cost":2,
                   "byModel":{"m":{"tokens":200,"cost":2}}}},
                 "chats":[\(chat("remote", tokens: 200, cost: 2, source: "codex"))]}
                """,
            bySource: """
                "cli":[{"modelName":"m","inputTokens":100,"cost":1}],
                "codex":[{"modelName":"m","inputTokens":200,"cost":2}]
                """)
        let m = try model(usage(daily: d))
        #expect(m.projectTree.first?.folders.count == 2)
        m.selectedSources = ["cli"]
        #expect(m.projectTree.count == 1)
        #expect(m.projectTree[0].folders.map(\.machineName) == ["Laptop"])
        #expect(abs(m.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func repositorySearchMatchesEveryHierarchyLevel() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"checkout","repositoryID":"github:acme/orbit",
                 "repositoryName":"orbit","repositoryURL":"https://github.com/acme/orbit",
                 "folderName":"backend","path":"/srv/orbit-backend","machineName":"TUF",
                 "machineID":"tuf","tokens":300,"cost":3,
                 "chats":[\(chat("main", tokens: 100, title: "Database repair"))],
                 "worktrees":[{"name":"billing-rewrite","tokens":200,"cost":2,
                   "chats":[\(chat("work", tokens: 200, title: "Invoice flow"))]}]}
                """)
        let repository = try #require(model(usage(daily: d)).projectTree.first)
        for query in ["orbit", "github.com", "backend", "/srv/orbit", "TUF", "tuf"] {
            #expect(repository.matches(query))
        }
        #expect(repository.matches("billing-rewrite"))
        #expect(repository.matches("Invoice flow"))
        #expect(repository.matches("Database repair"))
        #expect(repository.matches("main"))
        #expect(!repository.matches("frontend"))
    }

    @Test func modelAttributionDoesNotSpreadAcrossRepositories() throws {
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"alpha","repositoryID":"github:acme/alpha",
                 "repositoryName":"alpha","path":"/alpha","tokens":100,"cost":10,
                 "bySource":{"cli":{"tokens":100,"cost":10,
                   "byModel":{"a":{"tokens":100,"cost":10}}}},
                 "chats":[\(chat("a", tokens: 100, cost: 10, source: "cli"))]},
                {"projectName":"beta","repositoryID":"github:acme/beta",
                 "repositoryName":"beta","path":"/beta","tokens":300,"cost":30,
                 "bySource":{"cli":{"tokens":300,"cost":30,
                   "byModel":{"b":{"tokens":300,"cost":30}}}},
                 "chats":[\(chat("b", tokens: 300, cost: 30, source: "cli"))]}
                """,
            bySource: """
                "cli":[
                  {"modelName":"a","inputTokens":100,"cost":10},
                  {"modelName":"b","inputTokens":300,"cost":30},
                  {"modelName":"c","inputTokens":50,"cost":5}
                ]
                """)
        let m = try model(usage(daily: d))
        #expect(abs((m.projectTree.first { $0.name == "alpha" }?.tokens ?? 0) - 100) < 0.0001)
        #expect(abs((m.projectTree.first { $0.name == "beta" }?.tokens ?? 0) - 300) < 0.0001)
        #expect(
            abs((m.projectTree.first { $0.id == "repo:unattributed" }?.tokens ?? 0) - 50)
                < 0.0001)

        m.selectedModels = ["a"]
        #expect(m.projectTree.map(\.name) == ["alpha"])
        #expect(abs(m.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func legacySingleSourceProjectsRetainFolderAttribution() throws {
        let json = usage(
            daily: """
                {"period":"2026-06-01",
                 "bySource":{"cli":[{"modelName":"m","inputTokens":100,"cost":1}]},
                 "projects":[
                   {"projectName":"a","path":"/a","tokens":40,"cost":0.4},
                   {"projectName":"b","path":"/b","tokens":60,"cost":0.6}
                 ]}
                """)
        let m = try model(json)
        #expect(m.projectTree.map(\.name) == ["b", "a"])
        #expect(abs(m.projectTree[0].tokens - 60) < 0.0001)
        #expect(abs(m.projectTree[1].tokens - 40) < 0.0001)
        #expect(m.projectTree.allSatisfy { $0.id != "repo:unattributed" })
    }

    @Test func legacySourceChatsRetainProviderAttribution() throws {
        let json = usage(
            daily: """
                {"period":"2026-06-01",
                 "bySource":{
                   "cli":[{"modelName":"a","inputTokens":100,"cost":1}],
                   "codex":[{"modelName":"b","inputTokens":200,"cost":2}]},
                 "projects":[
                   {"projectName":"app","path":"/app","tokens":100,"cost":1,
                    "chats":[{"id":"a","source":"cli","tokens":100,"cost":1}]},
                   {"projectName":"remote","path":"/remote","tokens":200,"cost":2,
                    "chats":[{"id":"b","source":"codex","tokens":200,"cost":2}]}
                 ]}
                """)
        let m = try model(json)
        #expect(m.projectTree.map(\.name) == ["remote", "app"])

        m.selectedSources = ["cli"]
        #expect(m.projectTree.map(\.name) == ["app"])
        #expect(abs(m.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func filteredLegacyMultiSourceTotalsRemainUnattributed() throws {
        let json = usage(
            daily: """
                {"period":"2026-06-01",
                 "bySource":{
                   "cli":[{"modelName":"a","inputTokens":100,"cost":1}],
                   "codex":[{"modelName":"b","inputTokens":200,"cost":2}]},
                 "projects":[
                   {"projectName":"unknown","path":"/unknown","tokens":300,"cost":3}
                 ]}
                """)
        let m = try model(json)
        m.selectedSources = ["cli"]

        #expect(m.projectTree.map(\.name) == ["Unattributed"])
        #expect(abs(m.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func invalidRestoredModelAndPathFiltersAreCleared() throws {
        let suite = "DashboardProjectTreeTests.restore.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        preferences.set("removed-model", forKey: "dashModels")
        preferences.set("/removed/folder", forKey: "dashPaths")
        let d = day(
            "2026-06-01",
            projects: """
                {"projectName":"orbit","path":"/valid/orbit","tokens":100,"cost":1}
                """)
        let parsed = try JSONDecoder().decode(
            DashUsage.self, from: Data(usage(daily: d).utf8))
        let m = DashboardModel(preferences: preferences)
        m.ingest(parsed)
        m.range = .all
        #expect(m.selectedModels == ["m"])
        #expect(m.selectedPaths.isEmpty)
        #expect(abs(m.series.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
    }
}

@Suite struct DashFmtDrilldownTests {
    @Test func duration() {
        #expect(DashFmt.duration(0) == "-")
        #expect(DashFmt.duration(-5) == "-")
        #expect(DashFmt.duration(30000) == "30s")
        #expect(DashFmt.duration(59_000) == "59s")
        #expect(DashFmt.duration(90_000) == "2m")
        #expect(DashFmt.duration(3_540_000) == "59m")
        #expect(DashFmt.duration(3_600_000) == "1h")
        #expect(DashFmt.duration(3_660_000) == "1h 1m")
        #expect(DashFmt.duration(7_200_000) == "2h")
    }

    @Test func dateShort() {
        #expect(DashFmt.dateShort("2026-06-01") == "Jun 1")
        #expect(DashFmt.dateShort("2026-12-31") == "Dec 31")
        #expect(DashFmt.dateShort("") == "-")
        #expect(DashFmt.dateShort("garbage") == "-")
        #expect(DashFmt.dateShort("2026-13-01") == "-")
    }

    @Test func usdLong() {
        #expect(DashFmt.usdLong(1234.5) == "$1,234.50")
        #expect(DashFmt.usdLong(0) == "$0.00")
        #expect(DashFmt.usdLong(999_999.999) == "$1,000,000.00")
    }
}
