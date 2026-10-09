import EdithExtensionSupport
import EdithExtensionUI
@testable import UsageExtension
import Foundation
import Testing

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

    @MainActor
    @Test func longRangeDailyChartStaysWithinMarkBudget() async throws {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let start = try #require(calendar.date(byAdding: .day, value: -729, to: today))
        let rows: [[String: Any]] = (0..<730).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
            let period = DashboardModel.ymd.string(from: date)
            return [
                "period": period,
                "bySource": [
                    "fixture": [["modelName": "sample", "inputTokens": 1, "cost": 1]]
                ],
                "projects": [Any](),
                "hours": [Any](),
            ]
        }
        let payload = try JSONSerialization.data(
            withJSONObject: ["sources": ["fixture"], "daily": rows])
        let suite = "test.dashboard-chart-budget.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        model.ingest(try JSONDecoder().decode(DashUsage.self, from: payload))
        #expect(model.series.isEmpty)
        #expect(model.homeUsage.calendarDays.count >= 730)
        await model.awaitPendingComputation()
        #expect(model.series.count >= 730)
        #expect(model.chartData.daily.count <= DashboardComputation.chartMarkBudget)
        #expect(model.chartData.daily.count < model.series.count)
        #expect(Set(model.chartData.daily.map(\.label)).count == model.chartData.daily.count)
        #expect(
            Set(model.chartData.tokenMix.map(\.x)).count <= DashboardComputation.chartMarkBudget)
        #expect(
            Set(model.chartData.modelTime.map(\.x)).count
                <= DashboardComputation.chartMarkBudget)
        #expect(model.chartData.daily.reduce(0) { $0 + $1.tokens } == 730)
        #expect(model.series.reduce(0) { $0 + $1.tokens } == 730)
    }

    @MainActor
    @Test func filteredPublishedTotalsAndChartsComeFromTheSameComputation() async throws {
        let suite = "usage-published-snapshot.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        model.ingest(try usage())
        model.range = .all
        await model.awaitPendingComputation()
        #expect(model.series.reduce(0) { $0 + $1.tokens } == 1)
        let previous = model.revision
        #expect(
            model.series.reduce(0) { $0 + $1.tokens }
                == model.chartData.daily.reduce(0) { $0 + $1.tokens })
        model.selectedSources = []
        await model.awaitPendingComputation()
        #expect(model.revision > previous)
        #expect(model.series.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
        #expect(model.chartData.daily.allSatisfy { $0.tokens == 0 && $0.cost == 0 })
    }

    @MainActor
    @Test func cachedHomeUsageShowsBeforeRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "edith-home-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = HomeUsageSnapshotStore(
            file: directory.appendingPathComponent("home-usage.json"))
        var cachedDetail = HeatDay(date: Date(timeIntervalSince1970: 1_767_225_600))
        cachedDetail.tokens = 9
        cachedDetail.cost = 2
        cachedDetail.models = [NamedValue(id: "cached", name: "Cached", value: 9)]
        let cachedDay = DayPoint(
            id: "2026-01-01", date: cachedDetail.date, cost: cachedDetail.cost,
            tokens: cachedDetail.tokens)
        let cached = HomeUsageSnapshot(
            calendarDays: [cachedDay],
            heatDetail: ["2026-01-01": cachedDetail],
            heatScale: UsageCalendarScale(days: [cachedDay]))
        await store.store(cached)
        let roundTrip = try #require(await store.load())
        #expect(roundTrip == cached)
        #expect(roundTrip.heatScale.level(for: cachedDay) > 0)

        let suite = "test.dashboard-home-cache.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences, homeUsageStore: store)
        await model.restoreCachedHomeUsage()
        #expect(!model.loaded)
        #expect(model.homeUsage.calendarDays.map(\.id) == ["2026-01-01"])
        #expect(model.homeUsage.heatDetail["2026-01-01"]?.tokens == 9)

        model.ingest(try usage())
        #expect(model.loaded)
        #expect(model.homeUsage.calendarDays.contains { $0.id == "2026-09-01" })
        #expect(!model.homeUsage.calendarDays.contains { $0.id == "2026-01-01" })
        let shown = model.homeUsage.calendarDays.map(\.id)
        model.selectedSources = []
        await model.awaitPendingComputation()
        #expect(model.series.allSatisfy { $0.tokens == 0 })
        #expect(model.homeUsage.calendarDays.map(\.id) == shown)
    }
}
