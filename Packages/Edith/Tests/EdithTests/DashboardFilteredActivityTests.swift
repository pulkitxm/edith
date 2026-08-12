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
        #expect(abs(detail.tokens - 300) < 0.0001)
        #expect(detail.sources.map(\.id) == ["tuf-codex", "cli"])
        #expect(detail.projects.map(\.name) == ["remote", "local"])
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
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == 0)
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

    @Test func costOnlyUnknownIsAccountingInsteadOfTopModel() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{"codex":[
              {"modelName":"gpt-small","inputTokens":100,"cost":0},
              {"modelName":"gpt-large","cacheReadTokens":300,"cost":0},
              {"modelName":"unattributed-cost","cost":8},
              {"modelName":"unknown","cost":4},
              {"modelName":"gpt-accounting","cost":2}]},
             "projects":[],"hours":[]}
            """
        let dashboard = try model(daily, sources: "\"codex\"")

        #expect(dashboard.allModels == ["gpt-large", "gpt-small"])
        #expect(dashboard.selectedModels == ["gpt-large", "gpt-small"])
        #expect(Set(dashboard.tokenBearingModelTotals.map(\.model)) == ["gpt-large", "gpt-small"])
        let accounting = try #require(
            dashboard.modelTotals.first { $0.model == DashboardModel.unattributedCostModel })
        #expect(dashboard.modelTotals.count == 3)
        #expect(accounting.tokens == 0)
        #expect(accounting.cost == 14)
        #expect(dashboard.modelLabel(accounting.model) == "Unattributed cost")
        let top = try #require(dashboard.kpis.first { $0.label == "Top model" })
        #expect(top.value == "gpt-large")
        #expect(top.sub.contains("300"))
        #expect(top.sub.contains("75.0% of tokens"))
        #expect(abs(dashboard.series.reduce(0) { $0 + $1.cost } - 14) < 0.0001)
    }

    @Test func genuineUnknownTokenModelRemainsSelectable() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{"opencode":[
              {"modelName":"unknown","inputTokens":80,"cost":8}]},
             "projects":[],"hours":[]}
            """
        let dashboard = try model(daily, sources: "\"opencode\"")

        #expect(dashboard.allModels == ["unknown"])
        #expect(dashboard.selectedModels == ["unknown"])
        #expect(dashboard.tokenBearingModelTotals.map(\.model) == ["unknown"])
        #expect(dashboard.modelLabel("unknown") == "unknown")
    }

    @Test func genuineUnknownPathFilterDoesNotBorrowNamedModelShare() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{"opencode":[
              {"modelName":"unknown","inputTokens":100,"cost":10},
              {"modelName":"qwen","inputTokens":900,"cost":90}]},
             "projects":[
              {"projectName":"named","path":"/work/named","tokens":900,"cost":90,
               "bySource":{"opencode":{"tokens":900,"cost":90,
                 "byModel":{"qwen":{"tokens":900,"cost":90}}}}},
              {"projectName":"unknown","path":"/work/unknown","tokens":100,"cost":10,
               "bySource":{"opencode":{"tokens":100,"cost":10,
                 "byModel":{"unknown":{"tokens":100,"cost":10}}}}}],
             "hours":[]}
            """
        let dashboard = try model(daily, sources: "\"opencode\"")
        dashboard.selectedModels = ["unknown"]

        dashboard.selectedPaths = ["/work/named"]
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 0)
        #expect(dashboard.series.reduce(0) { $0 + $1.cost } == 0)
        #expect(dashboard.modelTotals.isEmpty)

        dashboard.selectedPaths = ["/work/unknown"]
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 100)
        #expect(dashboard.series.reduce(0) { $0 + $1.cost } == 10)
        #expect(dashboard.modelTotals.map(\.model) == ["unknown"])
    }

    @Test func partialModelFilterExcludesSharedProviderCost() throws {
        let daily = """
            {"period":"2026-06-01","bySource":{
              "codex":[
                {"modelName":"a","inputTokens":100,"cost":0},
                {"modelName":"b","cacheReadTokens":300,"cost":0},
                {"modelName":"unattributed-cost","cost":12}],
              "cli":[{"modelName":"c","inputTokens":50,"cost":5}]},
             "projects":[],"hours":[]}
            """
        let dashboard = try model(daily, sources: "\"codex\",\"cli\"")

        dashboard.selectedModels = ["a"]
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 100)
        #expect(dashboard.series.reduce(0) { $0 + $1.cost } == 0)
        #expect(dashboard.modelUnfilterableCost == 12)
        #expect(
            !dashboard.modelTotals.contains {
                $0.model == DashboardModel.unattributedCostModel
            })

        dashboard.selectedModels = ["c"]
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 50)
        #expect(dashboard.series.reduce(0) { $0 + $1.cost } == 5)
        #expect(dashboard.modelUnfilterableCost == 0)
        #expect(dashboard.modelTotals.map(\.model) == ["c"])
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
        #expect(abs(detail.tokens - 400) < 0.0001)
        #expect(detail.models.map(\.id) == ["b", "a"])
        #expect(detail.peakHour == 1)
    }

    @Test func everyFilterLeavesAllTimeActivityUnchanged() throws {
        let old = """
            {"period":"2026-06-01",
             "bySource":{"cli":[{"modelName":"a","inputTokens":50,"cost":5}]},
             "projects":[
              {"projectName":"old","repositoryID":"github:acme/old",
               "repositoryName":"old","path":"/work/old","tokens":50,"cost":5,
               "bySource":{"cli":{"tokens":50,"cost":5,
                 "byModel":{"a":{"tokens":50,"cost":5}}}}}],
             "hours":[{"tokens":50,"cost":5}]}
            """
        let current = """
            {"period":"\(today)","bySource":{
              "cli":[{"modelName":"a","inputTokens":100,"cost":10}],
              "tuf-codex":[{"modelName":"b","inputTokens":300,"cost":30}]},
             "projects":[
              {"projectName":"checkout","repositoryID":"github:acme/orbit",
               "repositoryName":"orbit","path":"/work/orbit","tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"a":{"tokens":100,"cost":10}}}}},
              {"projectName":"checkout","repositoryID":"github:acme/other",
               "repositoryName":"other","path":"/work/other","tokens":300,"cost":30,
               "bySource":{"tuf-codex":{"tokens":300,"cost":30,
                 "byModel":{"b":{"tokens":300,"cost":30}}}}}],
             "hours":[
              {"tokens":300,"cost":30,
               "bySource":{"tuf-codex":{"tokens":300,"cost":30,
                 "byModel":{"b":{"tokens":300,"cost":30}}}},
               "byPath":{"/work/other":{"tokens":300,"cost":30,
                 "bySource":{"tuf-codex":{"tokens":300,"cost":30,
                   "byModel":{"b":{"tokens":300,"cost":30}}}}}}},
              {"tokens":100,"cost":10,
               "bySource":{"cli":{"tokens":100,"cost":10,
                 "byModel":{"a":{"tokens":100,"cost":10}}}},
               "byPath":{"/work/orbit":{"tokens":100,"cost":10,
                 "bySource":{"cli":{"tokens":100,"cost":10,
                   "byModel":{"a":{"tokens":100,"cost":10}}}}}}}]}
            """
        let dashboard = try model(
            "\(old),\(current)", sources: "\"cli\",\"tuf-codex\"",
            sourceMeta: """
                "cli":{"label":"Claude Code","machineID":"local"},
                "tuf-codex":{"label":"Codex","machine":"TUF","machineID":"tuf"}
                """)
        let activityDays = dashboard.calendarDays.map(\.id)

        func expectActivityUnchanged() throws {
            #expect(dashboard.calendarDays.map(\.id) == activityDays)
            #expect(Set(dashboard.heatDetail.keys) == ["2026-06-01", today])
            #expect(dashboard.heatDetail["2026-06-01"]?.tokens == 50)
            let detail = try #require(dashboard.heatDetail[today])
            #expect(detail.tokens == 400)
            #expect(detail.models.map(\.id) == ["b", "a"])
            #expect(detail.sources.map(\.id) == ["tuf-codex", "cli"])
            #expect(detail.projects.map(\.name) == ["other", "orbit"])
            #expect(detail.peakHour == 0)
        }

        dashboard.range = .today
        try expectActivityUnchanged()
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 400)

        dashboard.selectedSources = ["cli"]
        try expectActivityUnchanged()
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 100)

        dashboard.selectedSources = Set(dashboard.allSources.map(\.id))
        dashboard.selectedModels = ["a"]
        try expectActivityUnchanged()
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 100)

        dashboard.selectedModels = Set(dashboard.allModels)
        dashboard.selectedPaths = ["/work/orbit"]
        try expectActivityUnchanged()
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 100)

        dashboard.selectedPaths = []
        let remote = try #require(dashboard.machineGroups.first { $0.id == "tuf" })
        dashboard.showOnlyMachine(remote)
        try expectActivityUnchanged()
        #expect(dashboard.series.reduce(0) { $0 + $1.tokens } == 300)
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
        let activity = try #require(dashboard.heatDetail["2026-06-01"])
        #expect(activity.projects.map(\.name) == ["Unattributed", "alpha"])
        #expect(activity.projects.map(\.value) == [200, 100])
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
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == 0)
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
        #expect(dashboard.heatDetail["2026-06-01"]?.peakHour == 1)
    }
}
