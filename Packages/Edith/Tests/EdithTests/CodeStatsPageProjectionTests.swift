import EdithKit
import Foundation
import Testing

@testable import Edith

@Suite struct CodeStatsPageProjectionTests {
    private let calendar = CodeStatsPageFixture.calendar

    @Test func heatmapStartsOnTheCalendarsFirstWeekday() throws {
        let projection = CodeStatsProjection(
            report: CodeStatsPageFixture.report(), calendar: calendar)
        #expect(projection.heatWeeks.count == 14)
        let first = try #require(projection.heatWeeks.first)
        #expect(first.cells.prefix(2).allSatisfy { $0.level == -1 && $0.date == nil })
        #expect(first.cells[2].id == "2026-07-08")
        #expect(first.monthLabel == "Jul")
        let active = projection.heatWeeks.flatMap(\.cells).first { $0.id == "2026-09-30" }
        #expect(active?.commits == 1)
        #expect(active?.lines == 150)
        #expect(active?.level == 1)
        #expect(projection.heatWeeks.dropFirst().contains { $0.monthLabel == "Aug" })
    }

    @Test func levelsSplitPositiveValuesIntoQuartiles() {
        let level = CodeStatsProjection.levels(Array(0...8))
        #expect([0, 1, 3, 5, 8].map(level) == [0, 1, 2, 3, 4])
        #expect(CodeStatsProjection.levels([0, 0])(5) == 0)
    }

    @Test func repositoriesSortByEachColumn() {
        let projection = CodeStatsProjection(
            report: CodeStatsPageFixture.report(), calendar: calendar)
        #expect(
            projection.repositoryRows[.commits]?.map(\.repository)
                == ["octo/app", "octo/site", "octo/tools"])
        #expect(
            projection.repositoryRows[.lines]?.map(\.repository)
                == ["octo/site", "octo/app", "octo/tools"])
        #expect(
            projection.repositoryRows[.lastActive]?.map(\.repository)
                == ["octo/site", "octo/app", "octo/tools"])
        #expect(projection.repositorySeries.count == 3)
        #expect(projection.repositoryMonthly.count == 3 * 4)
    }

    @Test func punchcardRowsFollowTheFirstWeekday() throws {
        let projection = CodeStatsProjection(
            report: CodeStatsPageFixture.report(), calendar: calendar)
        #expect(projection.punchcardRows.first == "Mon")
        #expect(projection.punchcardRows.last == "Sun")
        #expect(projection.punchcard.count == 7 * 24)
        let monday = try #require(projection.punchcard.first { $0.row == 0 && $0.hour == 9 })
        #expect(monday.commits == 1)
        #expect(monday.level > 0)
        #expect(projection.topDays.first?.day == "2026-09-30")
    }

    @Test func smallLanguagesFoldIntoOther() {
        let commits = (0..<10).map { index in
            CodeStatsCommit(
                sha: "l\(index)", day: "2026-10-0\(index % 5 + 1)", hour: 10,
                repository: "octo/app", languages: ["L\(index)": .init(added: 100 - index)])
        }
        let report = CodeStatsReportBuilder.build(
            commits: commits, range: .days(30), today: CodeStatsPageFixture.date("2026-10-05"),
            calendar: calendar)
        let shares = CodeStatsProjection(report: report, calendar: calendar).languageShares
        #expect(shares.count == 9)
        #expect(shares.first?.name == "L0")
        #expect(shares.last?.name == "Other (2)")
        #expect(shares.last?.lines == 91 + 92)
    }

    @Test func longHistoriesTrendByMonth() {
        let commits =
            CodeStatsPageFixture.commits + [
                CodeStatsCommit(
                    sha: "old", day: "2022-01-03", hour: 8, repository: "octo/app",
                    languages: ["Swift": .init(added: 1)])
            ]
        let report = CodeStatsReportBuilder.build(
            commits: commits, range: .all, today: CodeStatsPageFixture.date("2026-10-05"),
            calendar: calendar)
        let projection = CodeStatsProjection(report: report, calendar: calendar)
        #expect(projection.trendGranularity == .monthly)
        #expect(projection.trend.count == report.monthly.count)
        let recent = CodeStatsProjection(
            report: CodeStatsPageFixture.report(), calendar: calendar)
        #expect(recent.trendGranularity == .weekly)
        #expect(recent.trend.count == CodeStatsPageFixture.report().weekly.count)
    }

    @Test func progressEstimatesRemainingTime() {
        var progress = CodeStatsRunProgress(startedAt: Date(timeIntervalSince1970: 0))
        progress.overallFraction = 0.25
        let now = Date(timeIntervalSince1970: 60)
        #expect(CodeStatsProgressMath.elapsed(progress, now: now) == 60)
        #expect(CodeStatsProgressMath.remaining(progress, now: now) == 180)
        progress.overallFraction = 0.01
        #expect(CodeStatsProgressMath.remaining(progress, now: now) == nil)
        #expect(CodeStatsProgressMath.repositories(progress) == nil)
        #expect(CodeStatsProgressMath.step(.analyzing) == 3)
        #expect(CodeStatsProgressMath.duration(42) == "42s")
        #expect(CodeStatsProgressMath.duration(185) == "3m 5s")
        #expect(CodeStatsProgressMath.duration(7_380) == "2h 3m")
    }
}
