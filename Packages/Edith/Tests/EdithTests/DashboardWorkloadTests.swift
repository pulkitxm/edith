import Foundation
import Testing

@testable import Edith

@Suite struct DashboardWorkloadTests {
    private func usage(projects: Int = 0, chats: Int = 0, days: Int = 1) throws -> DashUsage {
        let sessions = (0..<chats).map {
            "{\"id\":\"session-\($0)\",\"source\":\"fixture\",\"tokens\":1}"
        }.joined(separator: ",")
        let rows = (0..<projects).map {
            """
            {"projectName":"project-\($0)","tokens":1,"chats":[\(sessions)]}
            """
        }.joined(separator: ",")
        let daily = (0..<days).map { _ in
            """
            {"period":"2026-09-01","bySource":{"fixture":[{"modelName":"sample","inputTokens":1}]},"projects":[\(rows)]}
            """
        }.joined(separator: ",")
        return try JSONDecoder().decode(
            DashUsage.self,
            from: Data("{\"sources\":[\"fixture\"],\"daily\":[\(daily)]}".utf8))
    }

    @Test func denseSingleDayUsesBackgroundComputation() throws {
        #expect(DashboardComputation.allowsInlineComputation(try usage(projects: 2, chats: 3)))
        #expect(!DashboardComputation.allowsInlineComputation(try usage(projects: 10_000)))
        #expect(
            !DashboardComputation.allowsInlineComputation(try usage(projects: 1, chats: 10_000)))
        #expect(!DashboardComputation.allowsInlineComputation(try usage(days: 33)))
    }

    @Test func cancelledSnapshotStopsBeforeProducingOutput() async throws {
        let data = try usage()
        let request = DashboardComputeRequest(
            data: data, sortedPeriods: ["2026-09-01"],
            allSources: [], allModels: [], calendarDays: [], range: .all,
            selectedSources: ["fixture"], selectedModels: ["sample"], selectedPaths: [],
            sortColumn: .cost, sortAscending: false, projSortKey: .cost,
            projSortAscending: false, calendar: Calendar(identifier: .gregorian))
        let result = await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return DashboardComputation.snapshot(request)
        }.value
        #expect(result == nil)
    }

    @MainActor
    @Test func denseInputPublishesOnlyTheLatestFilter() async throws {
        let suite = "test.dashboard-workload.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        model.ingest(try usage(projects: 1, chats: 1_000))
        #expect(model.series.isEmpty)
        model.selectedSources = []
        await model.awaitPendingComputation()
        #expect(!model.series.isEmpty)
        #expect(model.series.allSatisfy { $0.tokens == 0 })
        #expect(model.modelTotals.isEmpty)
    }
}
