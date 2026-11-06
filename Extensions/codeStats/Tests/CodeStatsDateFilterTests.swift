@testable import CodeStatsExtension
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

@MainActor @Suite struct CodeStatsDateFilterTests {
    private static let calendar = CodeStatsPageFixture.calendar
    private static let now = CodeStatsPageFixture.date("2026-10-05")

    private static func day(_ string: String) -> DateFilterDay {
        DateFilterDay(string)!
    }

    private static var dailyCommits: [CodeStatsCommit] {
        var commits: [CodeStatsCommit] = []
        var cursor = day("2025-01-01")
        var index = 1
        while cursor <= day("2026-10-05") {
            commits.append(
                CodeStatsCommit(
                    sha: "s\(index)", day: cursor.string, hour: 9 + index % 8,
                    repository: index % 2 == 0 ? "octo/app" : "octo/site",
                    languages: [index % 3 == 0 ? "Swift" : "Python": .init(added: index)]))
            cursor = cursor.advanced(by: 1)
            index += 1
        }
        return commits
    }

    private static func lines(_ first: String, _ last: String) -> (commits: Int, authored: Int) {
        var commits = 0
        var authored = 0
        for (offset, commit) in dailyCommits.enumerated()
        where commit.day >= first && commit.day <= last {
            commits += 1
            authored += offset + 1
        }
        return (commits, authored)
    }

    private func report(_ selection: DateFilterSelection) -> CodeStatsReport {
        CodeStatsReportBuilder.build(
            commits: Self.dailyCommits,
            range: CodeStatsRange(selection, now: Self.now, calendar: Self.calendar),
            today: Self.now, calendar: Self.calendar)
    }

    @Test(arguments: [
        (DateFilterPreset.today, "2026-10-05", "2026-10-05"),
        (.yesterday, "2026-10-04", "2026-10-04"),
        (.thisWeek, "2026-10-05", "2026-10-05"),
        (.lastWeek, "2026-09-28", "2026-10-04"),
        (.last7, "2026-09-29", "2026-10-05"),
        (.last14, "2026-09-22", "2026-10-05"),
        (.thisMonth, "2026-10-01", "2026-10-05"),
        (.lastMonth, "2026-09-01", "2026-09-30"),
        (.last30, "2026-09-06", "2026-10-05"),
        (.last90, "2026-07-08", "2026-10-05"),
        (.thisYear, "2026-01-01", "2026-10-05"),
        (.lastYear, "2025-01-01", "2025-12-31"),
        (.last12Months, "2025-10-06", "2026-10-05"),
        (.allTime, "2025-01-01", "2026-10-05"),
    ])
    func presetTotalsEqualAManualSum(preset: DateFilterPreset, first: String, last: String) {
        let report = report(.preset(preset))
        let expected = Self.lines(first, last)
        #expect(report.startDay == first)
        #expect(report.endDay == last)
        #expect(report.totals.commits == expected.commits)
        #expect(report.totals.authored == expected.authored)
        #expect(report.daily.reduce(0) { $0 + $1.commits } == expected.commits)
        #expect(report.daily.reduce(0) { $0 + $1.counts.authored } == expected.authored)
    }

    @Test func monthAndCustomTotalsEqualAManualSum() {
        let august = report(.month(DateFilterMonth("2026-08")!))
        #expect(august.totals.authored == Self.lines("2026-08-01", "2026-08-31").authored)
        let custom = report(
            .custom(DateFilterRange(Self.day("2025-12-28"), Self.day("2026-01-03"))))
        #expect(custom.totals.authored == Self.lines("2025-12-28", "2026-01-03").authored)
    }

    @Test func standardPresetsReuseCachedRangesWhereTheyMatch() {
        func range(_ preset: DateFilterPreset) -> CodeStatsRange {
            CodeStatsRange(.preset(preset), now: Self.now, calendar: Self.calendar)
        }
        #expect(range(.last30) == .days(30))
        #expect(range(.last90) == .days(90))
        #expect(range(.last12Months) == .year)
        #expect(range(.allTime) == .all)
        #expect(range(.today) == .days(1))
        #expect(range(.thisMonth) == .between("2026-10-01", "2026-10-05"))
    }

    @Test func momentumComparesTheSameNumberOfDays() throws {
        let week = report(.preset(.last7))
        let momentum = try #require(week.momentum)
        #expect(momentum.commits == 7)
        #expect(momentum.previousCommits == 7)
        #expect(momentum.previousLines == Self.lines("2026-09-22", "2026-09-28").authored)
    }

    @Test func oneDayChartsUseHoursAndDropTheSingleBarStacks() {
        let commits = [
            CodeStatsCommit(
                sha: "a", day: "2026-10-05", hour: 9, repository: "octo/app",
                languages: ["Swift": .init(added: 10)]),
            CodeStatsCommit(
                sha: "b", day: "2026-10-05", hour: 14, repository: "octo/site",
                languages: ["Python": .init(added: 5)]),
        ]
        let report = CodeStatsReportBuilder.build(
            commits: commits, range: .days(1), today: Self.now, calendar: Self.calendar)
        let projection = CodeStatsProjection(report: report, calendar: Self.calendar)
        #expect(projection.trendGranularity == .hourly)
        #expect(projection.trend.count == 24)
        #expect(projection.trend[9].lines == 10)
        #expect(projection.trend[14].lines == 5)
        #expect(projection.trend.last?.totalLines == 15)
        #expect(!projection.showsStackedTrend)
    }

    @Test func everyRangeKeepsItsContributionWeeks() {
        let day = CodeStatsProjection(report: report(.preset(.today)), calendar: Self.calendar)
        #expect(day.isSingleDay)
        #expect(day.heatWeeks.count == 1)
        let week = CodeStatsProjection(report: report(.preset(.last7)), calendar: Self.calendar)
        #expect(!week.isSingleDay)
        #expect((1...2).contains(week.heatWeeks.count))
        let quarter = CodeStatsProjection(
            report: report(.preset(.last90)), calendar: Self.calendar)
        #expect(quarter.heatWeeks.count >= 13)
    }

    @Test func oneWeekChartsUseDays() {
        let projection = CodeStatsProjection(
            report: report(.preset(.last7)), calendar: Self.calendar)
        #expect(projection.trendGranularity == .daily)
        #expect(projection.trend.count == 7)
        #expect(projection.stackGranularity == .daily)
        #expect(projection.showsStackedTrend)
        #expect(Set(projection.repositoryMonthly.map(\.date)).count == 7)
        #expect(Set(projection.languageMonthly.map(\.date)).count == 7)
    }

    @Test func dailyStacksSumToTheRangeTotals() {
        let week = report(.preset(.last7))
        let commits = week.repositoryMonthly.flatMap(\.values).reduce(0) { $0 + $1.value }
        #expect(Int(commits) == week.totals.commits)
    }

    @Test func longRangesKeepTheirExistingBuckets() {
        let quarter = CodeStatsProjection(
            report: report(.preset(.last90)), calendar: Self.calendar)
        #expect(quarter.trendGranularity == .weekly)
        #expect(quarter.stackGranularity == .monthly)
    }

    @Test func cachedReportsWithoutHoursStillDecode() throws {
        let data = try JSONEncoder().encode(report(.preset(.last90)))
        var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["hourly"] = nil
        let trimmed = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(CodeStatsReport.self, from: trimmed)
        #expect(decoded.hourly == nil)
    }

    @Test func exportLabelsSayTheRealRange() {
        #expect(CodeStatsExportSnapshot(report: report(.preset(.today))).rangeLabel == "Today")
        #expect(
            CodeStatsExportSnapshot(report: report(.preset(.last12Months))).rangeLabel
                == "Last 12 months")
        let label = CodeStatsExportSnapshot.label(
            for: .between("2026-10-03", "2026-10-12"), calendar: Self.calendar)
        #expect(label == "3 Oct to 12 Oct 2026")
        #expect(
            CodeStatsExportSnapshot.label(
                for: .between("2026-09-01", "2026-09-30"), calendar: Self.calendar)
                == "September 2026")
        let named = CodeStatsExportSnapshot(
            report: report(.preset(.thisMonth)), rangeLabel: "This month")
        #expect(named.rangeLabel == "This month")
        #expect(named.periodLine == "This month  ·  2026-10-01 to 2026-10-05")
    }

    private func model(
        _ agent: CodeStatsFakeAgent, defaults: UserDefaults? = nil
    ) async -> CodeStatsModel {
        let model = CodeStatsModel(
            service: agent.service,
            defaults: defaults ?? UserDefaults(suiteName: "test.edith.date-filter.\(UUID())")!,
            calendar: Self.calendar, today: { Self.now })
        await model.refresh()
        return model
    }

    private func agent() -> CodeStatsFakeAgent {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: CodeStatsPageFixture.date("2026-10-01"))
        )
        agent.facts = CodeStatsFactBuilder.build(commits: Self.dailyCommits)
        return agent
    }

    @Test func pageNumbersFollowTheSelection() async {
        let model = await model(agent())
        await model.select(.preset(.thisMonth))
        #expect(model.report?.startDay == "2026-10-01")
        #expect(model.report?.totals.authored == Self.lines("2026-10-01", "2026-10-05").authored)
        #expect(!model.canReturnToNamedRange)
        #expect(!model.showsPreviousRange)
    }

    @Test func chartZoomCanReturnToTheLastNamedRange() async {
        let model = await model(agent())
        await model.select(.preset(.lastMonth))
        await model.zoom(
            from: CodeStatsPageFixture.date("2026-09-03"),
            to: CodeStatsPageFixture.date("2026-09-09"))
        #expect(model.canReturnToNamedRange)
        #expect(model.lastNamedSelection == .preset(.lastMonth))
        await model.returnToNamedRange()
        #expect(model.selection == .preset(.lastMonth))
        #expect(!model.canReturnToNamedRange)
    }

    @Test func chartZoomOntoAWholeMonthCanStillReturn() async {
        let model = await model(agent())
        await model.zoom(
            from: CodeStatsPageFixture.date("2026-03-01"),
            to: CodeStatsPageFixture.date("2026-03-31"))
        #expect(model.selection == .month(DateFilterMonth("2026-03")!))
        #expect(model.canReturnToNamedRange)
        #expect(model.lastNamedSelection == .preset(.last90))
    }

    @Test func aPickedCustomRangeKeepsTheWayBack() async {
        let model = await model(agent())
        await model.select(
            .custom(DateFilterRange(Self.day("2026-09-03"), Self.day("2026-09-09"))))
        #expect(model.canReturnToNamedRange)
        #expect(model.lastNamedSelection == .preset(.last90))
    }

    @Test func chartZoomLandingOnAPresetNamesIt() async {
        let model = await model(agent())
        await model.zoom(
            from: CodeStatsPageFixture.date("2026-09-29"),
            to: CodeStatsPageFixture.date("2026-10-05"))
        #expect(model.selection == .preset(.last7))
        #expect(model.lastNamedSelection == .preset(.last90))
    }

    @Test func filterOffersMonthsAndTheEarliestDayFromTheFacts() async {
        let model = await model(agent())
        #expect(model.facets.earliestDay == Self.day("2025-01-01"))
        #expect(model.facets.months.first == DateFilterMonth("2026-10"))
        #expect(model.facets.months.last == DateFilterMonth("2025-01"))
    }

    @Test func selectionPersistsAcrossModels() async throws {
        let suite = "test.edith.date-filter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let first = await model(agent(), defaults: defaults)
        await first.select(.preset(.lastMonth))
        await first.zoom(
            from: CodeStatsPageFixture.date("2026-09-03"),
            to: CodeStatsPageFixture.date("2026-09-09"))
        let restored = await model(agent(), defaults: defaults)
        #expect(restored.selection == first.selection)
        #expect(restored.lastNamedSelection == .preset(.lastMonth))
    }

    @Test func nonCachedRangeShowsLoadingUntilItsReportArrives() async throws {
        let suite = "test.edith.date-filter.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let seed = await model(agent(), defaults: defaults)
        await seed.select(.preset(.thisMonth))
        let agent = agent()
        var service = agent.service
        let facts = service.facts
        let gate = CodeStatsFactsGate()
        service.facts = {
            await gate.wait()
            return try await facts()
        }
        let model = CodeStatsModel(
            service: service, defaults: defaults, calendar: Self.calendar, today: { Self.now })
        let refresh = Task { await model.refresh() }
        await gate.reached()
        #expect(model.report == nil)
        #expect(model.loadingState == .loading)
        await gate.open()
        await refresh.value
        #expect(model.loadingState == .content)
        #expect(model.report?.startDay == "2026-10-01")
    }
}

private actor CodeStatsFactsGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var arrivals: [CheckedContinuation<Void, Never>] = []
    private var arrived = false

    func wait() async {
        arrived = true
        arrivals.forEach { $0.resume() }
        arrivals = []
        guard !isOpen else { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func reached() async {
        guard !arrived else { return }
        await withCheckedContinuation { arrivals.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting = []
    }
}
