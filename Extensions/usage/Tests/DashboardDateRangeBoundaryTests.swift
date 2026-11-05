import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@Suite struct DashboardDateRangeBoundaryTests {
    private struct Fixture {
        let periods: [String]
        let tokens: [String: Double]
        let usage: DashUsage
    }

    private static func calendar(firstWeekday: Int = 2) -> Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private static func now(_ calendar: Calendar) throws -> Date {
        try #require(
            calendar.date(from: DateComponents(year: 2026, month: 11, day: 5, hour: 12)))
    }

    private func fixture() throws -> Fixture {
        var day = try #require(DateFilterDay("2024-10-01"))
        let last = try #require(DateFilterDay("2026-11-05"))
        var periods: [String] = []
        var tokens: [String: Double] = [:]
        var rows: [String] = []
        var index = 1
        while day <= last {
            periods.append(day.string)
            tokens[day.string] = Double(index)
            rows.append(
                """
                {"period":"\(day.string)","bySource":{"cli":[{"modelName":"sample",\
                "inputTokens":\(index),"outputTokens":0,"cacheReadTokens":0,"cost":0}]}}
                """)
            day = day.advanced(by: 1)
            index += 1
        }
        let json = """
            {"schemaVersion":7,"sources":["cli"],"daily":[\(rows.joined(separator: ","))]}
            """
        return Fixture(
            periods: periods, tokens: tokens,
            usage: try JSONDecoder().decode(DashUsage.self, from: Data(json.utf8)))
    }

    private func pageTokens(
        _ selection: DateFilterSelection, fixture: Fixture, calendar: Calendar
    ) throws -> Double {
        let request = DashboardComputeRequest(
            data: fixture.usage, sortedPeriods: fixture.periods, allSources: [],
            allModels: ["sample"], calendarDays: [], range: selection,
            selectedSources: ["cli"], selectedModels: ["sample"], selectedPaths: [],
            sortColumn: .cost, sortAscending: false, projSortKey: .cost,
            projSortAscending: false, calendar: calendar, now: try Self.now(calendar))
        let snapshot = try #require(DashboardComputation.snapshot(request))
        return snapshot.modelTotals.reduce(0) { $0 + $1.tokens }
    }

    private func manualSum(_ fixture: Fixture, _ first: String, _ last: String) -> Double {
        fixture.tokens.reduce(0) { sum, entry in
            entry.key >= first && entry.key <= last ? sum + entry.value : sum
        }
    }

    @Test(arguments: [
        (DateFilterPreset.today, "2026-11-05", "2026-11-05"),
        (.yesterday, "2026-11-04", "2026-11-04"),
        (.thisWeek, "2026-11-02", "2026-11-05"),
        (.lastWeek, "2026-10-26", "2026-11-01"),
        (.last7, "2026-10-30", "2026-11-05"),
        (.last14, "2026-10-23", "2026-11-05"),
        (.thisMonth, "2026-11-01", "2026-11-05"),
        (.lastMonth, "2026-10-01", "2026-10-31"),
        (.last30, "2026-10-07", "2026-11-05"),
        (.last90, "2026-08-08", "2026-11-05"),
        (.thisYear, "2026-01-01", "2026-11-05"),
        (.lastYear, "2025-01-01", "2025-12-31"),
        (.last12Months, "2025-11-06", "2026-11-05"),
        (.allTime, "2024-10-01", "2026-11-05"),
    ])
    func presetTotalsEqualAManualSum(preset: DateFilterPreset, first: String, last: String) throws {
        let fixture = try fixture()
        let tokens = try pageTokens(
            .preset(preset), fixture: fixture, calendar: Self.calendar())
        #expect(tokens == manualSum(fixture, first, last))
    }

    @Test func thisWeekFollowsTheUsersFirstWeekday() throws {
        let fixture = try fixture()
        #expect(
            try pageTokens(.preset(.thisWeek), fixture: fixture, calendar: Self.calendar())
                == manualSum(fixture, "2026-11-02", "2026-11-05"))
        #expect(
            try pageTokens(
                .preset(.thisWeek), fixture: fixture, calendar: Self.calendar(firstWeekday: 1))
                == manualSum(fixture, "2026-11-01", "2026-11-05"))
        #expect(
            try pageTokens(
                .preset(.lastWeek), fixture: fixture, calendar: Self.calendar(firstWeekday: 7))
                == manualSum(fixture, "2026-10-24", "2026-10-30"))
    }

    @Test func monthAndCustomTotalsEqualAManualSum() throws {
        let fixture = try fixture()
        let calendar = Self.calendar()
        let august = try #require(DateFilterMonth("2026-08"))
        #expect(
            try pageTokens(.month(august), fixture: fixture, calendar: calendar)
                == manualSum(fixture, "2026-08-01", "2026-08-31"))
        let february = try #require(DateFilterMonth("2026-02"))
        #expect(
            try pageTokens(.month(february), fixture: fixture, calendar: calendar)
                == manualSum(fixture, "2026-02-01", "2026-02-28"))
        let first = try #require(DateFilterDay("2025-12-28"))
        let last = try #require(DateFilterDay("2026-01-03"))
        #expect(
            try pageTokens(
                .custom(DateFilterRange(first, last)), fixture: fixture, calendar: calendar)
                == manualSum(fixture, "2025-12-28", "2026-01-03"))
    }

    @MainActor
    @Test func storedRangesParseUnchanged() throws {
        for (stored, expected) in [
            ("all", DateFilterSelection.preset(.allTime)), ("thisWeek", .preset(.thisWeek)),
            ("month:2026-08", .month(try #require(DateFilterMonth("2026-08")))),
        ] {
            let suite = "DashboardDateRangeBoundaryTests.\(UUID().uuidString)"
            let preferences = try #require(UserDefaults(suiteName: suite))
            defer { preferences.removePersistentDomain(forName: suite) }
            preferences.set(stored, forKey: "dashRange")
            let model = DashboardModel(preferences: preferences)
            model.ingest(try fixture().usage)
            #expect(model.range == expected)
        }
    }

    @MainActor
    @Test func modelOffersMonthsAndTheEarliestDayFromItsData() throws {
        let suite = "DashboardDateRangeBoundaryTests.\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let model = DashboardModel(preferences: preferences)
        model.ingest(try fixture().usage)
        #expect(model.earliestDay == DateFilterDay("2024-10-01"))
        #expect(model.dateFilterMonths.first == DateFilterMonth("2026-11"))
        #expect(model.dateFilterMonths.last == DateFilterMonth("2024-10"))
    }
}
