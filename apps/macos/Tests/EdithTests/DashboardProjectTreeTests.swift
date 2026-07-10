import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct DashboardProjectTreeTests {
    private func model(_ json: String) throws -> DashboardModel {
        for key in ["projSort", "projSortAsc", "dashSort", "dashSortAsc"] {
            SharedDefaults.store.removeObject(forKey: key)
        }
        let parsed = try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8))
        let m = DashboardModel()
        m.ingest(parsed)
        m.range = .all
        return m
    }

    private func chat(
        _ id: String, tokens: Double, cost: Double = 1, title: String? = nil,
        source: String? = nil, firstTs: Double? = nil, lastTs: Double? = nil
    ) -> String {
        var fields = ["\"id\":\"\(id)\"", "\"tokens\":\(tokens)", "\"cost\":\(cost)"]
        if let title { fields.append("\"title\":\"\(title)\"") }
        if let source { fields.append("\"source\":\"\(source)\"") }
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

    private func day(_ period: String, projects: String) -> String {
        """
        {"period":"\(period)",
         "bySource":{"cli":[{"modelName":"m","inputTokens":10,"outputTokens":0,
           "cacheCreationTokens":0,"cacheReadTokens":0,"cost":1}]},
         "projects":[\(projects)]}
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
        #expect(proj.nestedCount == 4)
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
        #expect(proj.expandable == false)
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
