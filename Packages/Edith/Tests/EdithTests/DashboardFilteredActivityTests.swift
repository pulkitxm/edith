import Foundation
import Testing

@testable import Edith

@MainActor
@Suite struct DashboardFilteredActivityTests {
    private func model(_ daily: String, sources: String, sourceMeta: String = "") throws
        -> DashboardModel
    {
        let suite = "DashboardFilteredActivityTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        preferences.removePersistentDomain(forName: suite)
        let meta = sourceMeta.isEmpty ? "" : ",\"sourceMeta\":{\(sourceMeta)}"
        let json = "{\"schemaVersion\":7,\"sources\":[\(sources)]\(meta),\"daily\":[\(daily)]}"
        let parsed = try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8))
        let dashboard = DashboardModel(preferences: preferences)
        dashboard.ingest(parsed)
        dashboard.range = .all
        return dashboard
    }

    private var today: String { DashboardModel.ymd.string(from: Date()) }

    @Test func sourceSpecificHoursAndMachineActivityStayAligned() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{
              "cli":[{"modelName":"a","inputTokens":100,"cost":10}],
              "tuf-codex":[{"modelName":"b","inputTokens":200,"cost":20}]},
             "projects":[
              {"projectName":"local","repositoryID":"github:acme/local",
               "repositoryName":"local","tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"a":{"tokens":100,"cost":10}}}}},
              {"projectName":"remote","repositoryID":"github:acme/remote",
               "repositoryName":"remote","tokens":200,"cost":20,
               "bySource":{"tuf-codex":{"tokens":200,"cost":20,
                 "byModel":{"b":{"tokens":200,"cost":20}}}}}],
             "hours":[
              {"tokens":100,"cost":10,"bySource":{"cli":{"tokens":100,"cost":10,
                "byModel":{"a":{"tokens":100,"cost":10}}}}},
              {"tokens":200,"cost":20,"bySource":{"tuf-codex":{"tokens":200,"cost":20,
                "byModel":{"b":{"tokens":200,"cost":20}}}}}]}
            """
        let dashboard = try model(
            daily, sources: "\"cli\",\"tuf-codex\"",
            sourceMeta: """
                "cli":{"label":"Claude Code","machineID":"local"},
                "tuf-codex":{"label":"Codex","machine":"TUF","machineID":"tuf"}
                """)
        dashboard.selectedSources = ["tuf-codex"]

        #expect(abs(dashboard.hourlyAll[0].tokens) < 0.0001)
        #expect(abs(dashboard.hourlyAll[1].tokens - 200) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedTokens) < 0.0001)
        let detail = try #require(dashboard.heatDetail["2026-06-01"])
        #expect(abs(detail.tokens - 200) < 0.0001)
        #expect(detail.sources.map(\.id) == ["tuf-codex"])
        #expect(detail.projects.map(\.name) == ["remote"])
        #expect(detail.peakHour == 1)
    }

    @Test func unsupportedProviderHoursRemainUnattributed() throws {
        let daily = """
            {"period":"2026-06-01",
             "bySource":{"opencode":[{"modelName":"qwen","inputTokens":80,"cost":8}]},
             "projects":[],
             "hours":[{"tokens":80,"cost":8,
               "bySource":{"cli":{"tokens":80,"cost":8,
                 "byModel":{"qwen":{"tokens":80,"cost":8}}}}}]}
            """
        let dashboard = try model(daily, sources: "\"opencode\"")

        #expect(dashboard.hourlyAll.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
        #expect(abs(dashboard.hourlyUnattributedTokens - 80) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedCost - 8) < 0.0001)
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == nil)
    }

    @Test func aggregateUnknownModelUsesNamedDetailTotals() throws {
        let daily = """
            {"period":"2026-06-01",
             "bySource":{"opencode":[{"modelName":"unknown","inputTokens":80,"cost":8}]},
             "projects":[
              {"projectName":"orbit","repositoryID":"github:acme/orbit",
               "repositoryName":"orbit","tokens":80,"cost":8,
               "bySource":{"opencode":{"tokens":80,"cost":8,
                 "byModel":{"qwen":{"tokens":80,"cost":8}}}}}],
             "hours":[{}, {},
              {"tokens":80,"cost":8,
               "bySource":{"opencode":{"tokens":80,"cost":8,
                 "byModel":{"qwen":{"tokens":80,"cost":8}}}}}]}
            """
        let dashboard = try model(daily, sources: "\"opencode\"")

        #expect(dashboard.projectTree.map(\.name) == ["orbit"])
        #expect(abs(dashboard.projectTree[0].tokens - 80) < 0.0001)
        #expect(abs(dashboard.hourlyAll[2].tokens - 80) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedTokens) < 0.0001)
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == 2)
    }

    @Test func modelFilterUsesOnlyMatchingHourlyModel() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{"cli":[
              {"modelName":"a","inputTokens":100,"cost":10},
              {"modelName":"b","inputTokens":300,"cost":30}]},
             "projects":[],
             "hours":[
              {"tokens":100,"cost":10,"bySource":{"cli":{"tokens":100,"cost":10,
                "byModel":{"a":{"tokens":100,"cost":10}}}}},
              {"tokens":300,"cost":30,"bySource":{"cli":{"tokens":300,"cost":30,
                "byModel":{"b":{"tokens":300,"cost":30}}}}}]}
            """
        let dashboard = try model(daily, sources: "\"cli\"")
        dashboard.selectedModels = ["a"]

        #expect(abs(dashboard.hourlyAll[0].tokens - 100) < 0.0001)
        #expect(abs(dashboard.hourlyAll[1].tokens) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedTokens) < 0.0001)
        let detail = try #require(dashboard.heatDetail["2026-06-01"])
        #expect(abs(detail.tokens - 100) < 0.0001)
        #expect(detail.models.map(\.id) == ["a"])
        #expect(detail.peakHour == 0)
    }

    @Test func pathAndRangeFiltersUpdateActivity() throws {
        let old = """
            {"period":"2026-06-01",
             "bySource":{"cli":[{"modelName":"m","inputTokens":50,"cost":5}]},
             "projects":[],"hours":[]}
            """
        let current = """
            {"period":"\(today)",
             "bySource":{"cli":[{"modelName":"m","inputTokens":400,"cost":40}]},
             "projects":[
              {"projectName":"checkout","repositoryID":"github:acme/orbit",
               "repositoryName":"orbit","path":"/work/orbit","tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"m":{"tokens":100,"cost":10}}}}},
              {"projectName":"checkout","repositoryID":"github:acme/other",
               "repositoryName":"other","path":"/work/other","tokens":300,"cost":30,
               "bySource":{"cli":{"tokens":300,"cost":30,
                 "byModel":{"m":{"tokens":300,"cost":30}}}}}],
             "hours":[
              {"tokens":300,"cost":30,
               "bySource":{"cli":{"tokens":300,"cost":30,
                 "byModel":{"m":{"tokens":300,"cost":30}}}},
               "byPath":{"/work/other":{"tokens":300,"cost":30,
                 "bySource":{"cli":{"tokens":300,"cost":30,
                   "byModel":{"m":{"tokens":300,"cost":30}}}}}}},
              {"tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"m":{"tokens":100,"cost":10}}}},
               "byPath":{"/work/orbit":{"tokens":100,"cost":10,
                 "bySource":{"cli":{"tokens":100,"cost":10,
                   "byModel":{"m":{"tokens":100,"cost":10}}}}}}}]}
            """
        let dashboard = try model("\(old),\(current)", sources: "\"cli\"")
        dashboard.range = .today
        dashboard.selectedPaths = ["/work/orbit"]

        #expect(Set(dashboard.heatDetail.keys) == [today])
        #expect(dashboard.calendarDays.count == 7)
        #expect(Calendar.current.component(.weekday, from: dashboard.calendarDays[0].date) == 2)
        #expect(Calendar.current.component(.weekday, from: dashboard.calendarDays[6].date) == 1)
        let detail = try #require(dashboard.heatDetail[today])
        #expect(abs(detail.tokens - 100) < 0.0001)
        #expect(detail.projects.map(\.name) == ["orbit"])
        #expect(abs(dashboard.hourlyAll[0].tokens) < 0.0001)
        #expect(abs(dashboard.hourlyAll[1].tokens - 100) < 0.0001)
        #expect(detail.peakHour == 1)
        #expect(abs(dashboard.hourlyUnattributedTokens) < 0.0001)
    }

    @Test func pathFilterUsesProviderSpecificProjectShare() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{
              "cli":[{"modelName":"a","inputTokens":100,"cost":10}],
              "codex":[{"modelName":"b","inputTokens":100,"cost":20}]},
             "projects":[
              {"projectName":"alpha","repositoryID":"github:acme/alpha",
               "repositoryName":"alpha","path":"/work/alpha","tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"a":{"tokens":100,"cost":10}}}}},
              {"projectName":"beta","repositoryID":"github:acme/beta",
               "repositoryName":"beta","path":"/work/beta","tokens":100,"cost":20,
               "bySource":{"codex":{"tokens":100,"cost":20,
                 "byModel":{"b":{"tokens":100,"cost":20}}}}}],
             "hours":[]}
            """
        let dashboard = try model(daily, sources: "\"cli\",\"codex\"")
        dashboard.selectedPaths = ["/work/alpha"]

        #expect(abs(dashboard.series.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
        #expect(abs(dashboard.series.reduce(0) { $0 + $1.cost } - 10) < 0.0001)
        #expect(dashboard.series[0].bySource == ["cli": 100])
        #expect(dashboard.projectTree.map(\.name) == ["alpha"])
        #expect(abs(dashboard.projectTree[0].tokens - 100) < 0.0001)
    }

    @Test func pathFilterPublishesUnavailableProviderDetail() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{
              "cli":[{"modelName":"a","inputTokens":100,"cost":10}],
              "codex":[{"modelName":"b","inputTokens":200,"cost":20}]},
             "projects":[
              {"projectName":"alpha","repositoryID":"github:acme/alpha",
               "repositoryName":"alpha","path":"/work/alpha","tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"a":{"tokens":100,"cost":10}}}}}],
             "hours":[]}
            """
        let dashboard = try model(daily, sources: "\"cli\",\"codex\"")
        dashboard.selectedPaths = ["/work/alpha"]

        #expect(abs(dashboard.series.reduce(0) { $0 + $1.tokens } - 100) < 0.0001)
        #expect(abs(dashboard.pathUnattributedTokens - 200) < 0.0001)
        #expect(abs(dashboard.pathUnattributedCost - 20) < 0.0001)
        #expect(dashboard.projectTree.map(\.name) == ["alpha"])
    }

    @Test func pathFilterWithoutPathDetailRemainsUnattributed() throws {
        let daily = """
            {"period":"2026-06-01",
             "bySource":{"cli":[{"modelName":"m","inputTokens":100,"cost":10}]},
             "projects":[{"projectName":"orbit","path":"/work/orbit",
               "tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"m":{"tokens":100,"cost":10}}}}}],
             "hours":[{"tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"m":{"tokens":100,"cost":10}}}}}]}
            """
        let dashboard = try model(daily, sources: "\"cli\"")
        dashboard.selectedPaths = ["/work/orbit"]

        #expect(dashboard.hourlyAll.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
        #expect(abs(dashboard.hourlyUnattributedTokens - 100) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedCost - 10) < 0.0001)
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == nil)
    }

    @Test func legacyHoursApplyOnlyWithoutFilters() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{"cli":[
              {"modelName":"a","inputTokens":25,"cost":2.5},
              {"modelName":"b","inputTokens":75,"cost":7.5}]},
             "projects":[],
             "hours":[{"tokens":25,"cost":2.5},{"tokens":75,"cost":7.5}]}
            """
        let dashboard = try model(daily, sources: "\"cli\"")

        #expect(abs(dashboard.hourlyAll[0].tokens - 25) < 0.0001)
        #expect(abs(dashboard.hourlyAll[1].tokens - 75) < 0.0001)
        #expect(abs(dashboard.hourlyUnattributedTokens) < 0.0001)

        dashboard.selectedModels = ["a"]
        #expect(dashboard.hourlyAll.allSatisfy { $0.tokens == 0 })
        #expect(abs(dashboard.hourlyUnattributedTokens - 25) < 0.0001)
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == nil)
    }
}
