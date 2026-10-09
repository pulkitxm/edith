import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

struct SurfaceCoreWidgetTests {
    private let now = SurfaceSampleData.date

    @Test func unreadableAndExpiredQuotasNeverLookLikeUnusedAllowance() {
        #expect(SurfaceQuotaValue(nil, now: now).text == "Unavailable")
        for percent in [Double.nan, .infinity, -1] {
            #expect(
                SurfaceQuotaValue(.init(percent: percent, resetsAt: nil), now: now).fraction == nil)
        }
        let expired = SurfaceQuotaValue(.init(percent: 0, resetsAt: now), now: now)
        #expect(expired.text == "Expired")
        #expect(expired.remaining == nil)
        #expect(SurfaceQuotaValue(.init(percent: 140, resetsAt: nil), now: now).fraction == 1)
        #expect(SurfaceQuotaValue(.init(percent: 34, resetsAt: nil), now: now).remaining == 66)
    }

    @Test func providerSelectionsKeepWindowDetailsAndAvailableSources() {
        var tile = SurfaceTile(.limits)
        let all = SurfaceSampleData.limits(tile)
        #expect(all.rows.count == 4)
        #expect(all.rows.first?.field == "session")
        #expect(all.rows.first?.details.contains { $0.field == "resets" } == true)
        #expect(all.metrics.first { $0.id == "remaining" }?.value == "37%")
        tile.sourceIDs = ["codex"]
        let selected = SurfaceSampleData.limits(tile)
        #expect(selected.rows.count == 2)
        #expect(selected.rows.allSatisfy { $0.sourceID == "codex" })
        #expect(selected.sources.count == 2)
        tile.sourceIDs = []
        let empty = SurfaceSampleData.limits(tile)
        #expect(empty.rows.isEmpty)
        #expect(empty.metrics.first { $0.id == "remaining" }?.value == "Unavailable")
    }

    @Test func missingProviderWindowsAndErrorsRemainVisible() {
        let result = SurfaceCoreProjection.limits(
            .init(
                refreshedAt: now,
                providers: [
                    .init(provider: .claude, session: nil, week: nil, error: "Sign in again")
                ], failure: nil), tile: .init(.limits), now: now)
        #expect(result.rows.count == 1)
        #expect(result.rows.first?.value == "Unavailable")
        #expect(result.rows.first?.details.contains(.init("errors", "Sign in again")) == true)
    }

    @Test func repositorySelectionsChangeTotalsAndRetainTypedFields() {
        var tile = SurfaceTile(.codeStats)
        let all = SurfaceSampleData.codeStats(tile)
        #expect(all.metrics.first { $0.id == "commits" }?.value == "24")
        tile.sourceIDs = ["sample/beacon"]
        let selected = SurfaceSampleData.codeStats(tile)
        #expect(selected.metrics.first { $0.id == "commits" }?.value == "8")
        #expect(selected.rows.count == 1)
        #expect(selected.rows.first?.field == "repositories")
        #expect(selected.rows.first?.details.contains(.init("languages", "Swift")) == true)
        #expect(selected.message?.contains("Selected repositories only") == true)
        tile.sourceIDs = []
        #expect(SurfaceSampleData.codeStats(tile).rows.isEmpty)
    }

    @Test func periodAndRepositoryQueriesUseIndependentCacheEntries() {
        var first = SurfaceTile(.codeStats)
        var second = first
        second.days = 7
        #expect(SurfaceExtensionRequestKey(first) != SurfaceExtensionRequestKey(second))
        first.sourceIDs = ["sample/atlas"]
        #expect(SurfaceExtensionRequestKey(first) != SurfaceExtensionRequestKey(second))
        second = first
        second.hiddenFields = ["lines"]
        #expect(SurfaceExtensionRequestKey(first) == SurfaceExtensionRequestKey(second))
    }

    @Test func reportClientSendsTheSelectedRepositoryFilter() async throws {
        let client = CodeStatsAgentClient { operation, payload, timeout in
            #expect(operation == CodeStatsAgentOperation.report)
            #expect(timeout == 30)
            let query = try AgentPayload.decode(CodeStatsReportQuery.self, from: payload)
            #expect(query.range == .days(7))
            #expect(query.filter.repositories == ["sample/atlas"])
            return try AgentPayload.encode(Optional<CodeStatsReport>.none)
        }
        #expect(
            try await client.report(.days(7), filter: .init(repositories: ["sample/atlas"])) == nil)
    }

    @Test func uncachedPeriodsBuildFilteredReportsFromStoredFacts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = CodeStatsStore(root: root)
        let commits = [
            CodeStatsCommit(
                sha: "one", day: "2026-10-09", hour: 9, repository: "sample/atlas",
                languages: ["Swift": .init(added: 30)]),
            CodeStatsCommit(
                sha: "two", day: "2026-10-08", hour: 9, repository: "sample/atlas",
                languages: ["Swift": .init(added: 20)]),
            CodeStatsCommit(
                sha: "other", day: "2026-10-09", hour: 9, repository: "sample/beacon",
                languages: ["Swift": .init(added: 400)]),
            CodeStatsCommit(
                sha: "old", day: "2026-09-01", hour: 9, repository: "sample/atlas",
                languages: ["Swift": .init(added: 500)]),
        ]
        try store.saveFacts(CodeStatsFactBuilder.build(commits: commits))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let environment = CodeStatsEnvironment(
            settings: { .init() }, saveIdentity: { _ in }, isEnabled: { true }, git: { nil },
            github: { nil }, store: store, calendar: calendar, now: { SurfaceSampleData.date })
        let workflow = CodeStatsWorkflow(environment: environment)
        let query = CodeStatsReportQuery(.days(7), filter: .init(repositories: ["sample/atlas"]))
        let data = try await workflow.perform(
            operation: CodeStatsAgentOperation.report, payload: AgentPayload.encode(query))
        let report = try #require(try AgentPayload.decode(CodeStatsReport?.self, from: data))
        #expect(report.totals.commits == 2)
        #expect(report.totals.authored == 50)
        #expect(report.totals.currentStreak == 2)
        #expect(report.repositories.map(\.repository) == ["sample/atlas"])
        #expect(report.range == .days(7))
    }
}
