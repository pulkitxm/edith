@testable import EdithKit
import Foundation
import Testing

@Suite struct CodeStatsReportBuilderTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }

    private func date(_ day: String) -> Date {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        return calendar.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 15))!
    }

    private func commit(
        _ sha: String, _ day: String, hour: Int = 10, repository: String = "octo/a",
        _ languages: [String: CodeStatsLanguageCounts]
    ) -> CodeStatsCommit {
        CodeStatsCommit(
            sha: sha, day: day, hour: hour, repository: repository, languages: languages)
    }

    private func build(
        _ commits: [CodeStatsCommit], _ range: CodeStatsRange, today: String
    ) -> CodeStatsReport {
        CodeStatsReportBuilder.build(
            commits: commits, range: range, today: date(today), calendar: calendar)
    }

    private var repositoryA: [CodeStatsCommit] {
        [
            commit("s1", "2026-06-01", ["TypeScript": .init(added: 10, updated: 2, deleted: 1)]),
            commit("s2", "2026-06-02", ["Python": .init(added: 5)]),
        ]
    }

    private var repositoryB: [CodeStatsCommit] {
        [
            commit(
                "s1", "2026-06-01", repository: "octo/b",
                ["TypeScript": .init(added: 10, updated: 2, deleted: 1)]),
            commit("s3", "2026-06-01", repository: "octo/b", ["TypeScript": .init(added: 3)]),
        ]
    }

    @Test func identicalShasAcrossRepositoriesCountOnce() {
        let report = build(repositoryA + repositoryB, .days(7), today: "2026-06-03")
        #expect(report.totals.commits == 3)
        let first = report.daily.first { $0.day == "2026-06-01" }
        #expect(first?.counts == CodeStatsLanguageCounts(added: 13, updated: 2, deleted: 1))
        #expect(first?.commits == 2)
        #expect(report.daily.first { $0.day == "2026-06-02" }?.counts.added == 5)
        #expect(report.repositories.map(\.repository) == ["octo/a", "octo/b"])
        #expect(report.repositories.map(\.commits) == [2, 1])
    }

    @Test func authoredIsAddedPlusUpdatedAndNetIsAddedMinusDeleted() {
        let counts = CodeStatsLanguageCounts(added: 10, updated: 2, deleted: 1)
        #expect(counts.authored == 12)
        #expect(counts.net == 9)
        let report = build(repositoryA, .all, today: "2026-06-02")
        #expect(report.totals.authored == 17)
        #expect(report.totals.net == 14)
        #expect(report.totals.averagePerActiveDay == 8.5)
    }

    @Test func theDailySeriesCoversEveryDayIncludingEmptyOnes() {
        let report = build(repositoryA, .days(3), today: "2026-06-03")
        #expect(report.daily.map(\.day) == ["2026-06-01", "2026-06-02", "2026-06-03"])
        #expect(report.daily[2].counts.added == 0)
        #expect(report.daily[0].counts.added == 10)
        #expect(report.startDay == "2026-06-01")
        #expect(report.endDay == "2026-06-03")
    }

    @Test func thePunchcardBucketsByWeekdayAndHour() {
        let commits = [
            commit("p1", "2026-06-01", hour: 9, ["Go": .init(added: 1)]),
            commit("p2", "2026-06-01", hour: 9, ["Go": .init(added: 1)]),
            commit("p3", "2026-06-02", hour: 23, ["Go": .init(added: 1)]),
        ]
        let report = build(commits, .days(7), today: "2026-06-03")
        #expect(report.punchcard.count == 7)
        #expect(report.punchcard[1][9] == 2)
        #expect(report.punchcard[2][23] == 1)
        #expect(report.punchcard.flatMap { $0 }.reduce(0, +) == 3)
    }

    @Test func languagesAreSortedByAuthoredLinesWithShares() {
        let report = build(repositoryA, .all, today: "2026-06-02")
        #expect(report.languages.map(\.language) == ["TypeScript", "Python"])
        #expect(abs(report.languages[0].share - 12.0 / 17.0) < 0.0001)
    }

    @Test func topDaysRankTheHighestAuthoredDaysFirst() {
        let report = build(repositoryA + repositoryB, .all, today: "2026-06-03")
        #expect(report.topDays.first?.day == "2026-06-01")
        #expect(report.topDays.first?.counts.authored == 15)
        #expect(report.topDays.count == 2)
    }

    @Test func aOneDayRangeBreaksThatDayDownByLanguage() {
        let report = build(repositoryA + repositoryB, .days(1), today: "2026-06-01")
        #expect(report.languages.map(\.language) == ["TypeScript"])
        #expect(report.languages[0].counts.added == 13)
    }

    @Test func monthlyLanguageSharesFollowTheTopLanguages() {
        let commits = repositoryA + [commit("s9", "2026-07-04", ["Python": .init(added: 4)])]
        let report = build(commits, .all, today: "2026-07-10")
        let python = report.languageMonthly.first { $0.name == "Python" }
        #expect(python?.values.map(\.start) == ["2026-06-01", "2026-07-01"])
        #expect(abs((python?.values[0].value ?? 0) - 5.0 / 17.0) < 0.0001)
        #expect(python?.values[1].value == 1)
    }

    @Test func streaksCountConsecutiveActiveDays() {
        let days = ["2026-05-01", "2026-05-02", "2026-05-03", "2026-05-05", "2026-05-06"]
        let commits = days.enumerated().map { index, day in
            commit("k\(index)", day, ["Go": .init(added: 1)])
        }
        let today = build(commits, .all, today: "2026-05-06").totals
        #expect(today.currentStreak == 2)
        #expect(today.longestStreak == 3)
        #expect(build(commits, .all, today: "2026-05-07").totals.currentStreak == 2)
        #expect(build(commits, .all, today: "2026-05-08").totals.currentStreak == 0)
        let narrow = build(commits, .days(2), today: "2026-05-06").totals
        #expect(narrow.longestStreak == 2)
        #expect(narrow.currentStreak == 2)
    }

    @Test func theLongestStreakIsNeverShorterThanTheCurrentOne() {
        let today = date("2026-06-30")
        let recent = (0..<45).map { offset in
            let day = CodeStatsDay(date: today, calendar: calendar).advanced(by: -offset).string
            return commit("r\(offset)", day, ["Go": .init(added: 1)])
        }
        let old = (0..<60).map { offset in
            commit("o\(offset)", CodeStatsDay(year: 2025, month: 1, day: 1).advanced(by: offset)
                .string, ["Go": .init(added: 1)])
        }
        let month = build(recent + old, .days(30), today: "2026-06-30").totals
        #expect(month.currentStreak == 45)
        #expect(month.longestStreak == 45)
        #expect(build(recent + old, .all, today: "2026-06-30").totals.longestStreak == 60)
        let pair = [
            commit("p1", "2026-05-05", ["Go": .init(added: 1)]),
            commit("p2", "2026-05-06", ["Go": .init(added: 1)]),
        ]
        let single = build(pair, .days(1), today: "2026-05-06").totals
        #expect(single.currentStreak == 2)
        #expect(single.longestStreak == 2)
        let afterwards = build(pair, .days(1), today: "2026-05-07").totals
        #expect(afterwards.currentStreak == 2)
        #expect(afterwards.longestStreak >= afterwards.currentStreak)
    }

    @Test func momentumComparesWithThePreviousPeriodOfEqualLength() {
        let previous = (1...2).map { commit("p\($0)", "2026-06-0\($0)", ["Go": .init(added: 10)]) }
        let current = (1...3).map { commit("c\($0)", "2026-06-1\($0)", ["Go": .init(added: 10)]) }
        let report = build(previous + current, .days(7), today: "2026-06-14")
        let momentum = report.momentum
        #expect(momentum?.commits == 3)
        #expect(momentum?.previousCommits == 2)
        #expect(momentum?.lines == 30)
        #expect(momentum?.previousLines == 20)
        #expect(momentum?.commitChange == 50)
        #expect(build(current, .days(7), today: "2026-06-14").momentum?.commitChange == nil)
        #expect(build(current, .all, today: "2026-06-14").momentum == nil)
    }

    @Test func rangesSelectTheirWindow() {
        let commits = [
            commit("old", "2024-01-15", ["Go": .init(added: 1)]),
            commit("mid", "2026-03-01", ["Go": .init(added: 1)]),
            commit("new", "2026-06-10", ["Go": .init(added: 1)]),
        ]
        let thirty = build(commits, .days(30), today: "2026-06-14")
        #expect(thirty.totals.commits == 1)
        #expect(thirty.daily.count == 30)
        let year = build(commits, .year, today: "2026-06-14")
        #expect(year.totals.commits == 2)
        #expect(year.daily.count == 365)
        let all = build(commits, .all, today: "2026-06-14")
        #expect(all.totals.commits == 3)
        #expect(all.startDay == "2024-01-15")
        #expect(build([], .all, today: "2026-06-14").daily.count == 1)
    }

    @Test func weeklyAndMonthlySeriesCarryARollingAverage() {
        let commits = [
            commit("w1", "2026-06-01", ["Go": .init(added: 4)]),
            commit("w2", "2026-06-09", ["Go": .init(added: 8)]),
            commit("w3", "2026-06-10", ["Go": .init(added: 4)]),
            commit("w4", "2026-07-02", ["Go": .init(added: 12)]),
        ]
        let report = build(commits, .days(35), today: "2026-07-03")
        #expect(report.weekly.first?.start == "2026-05-25")
        let starts = report.weekly.map(\.start)
        #expect(starts.contains("2026-06-01") && starts.contains("2026-06-29"))
        let june8 = report.weekly.first { $0.start == "2026-06-08" }
        #expect(june8?.commits == 2)
        #expect(june8?.lines == 12)
        #expect(june8?.rollingLines == (0 + 4 + 12) / 3.0)
        let last = report.weekly.last
        #expect(last?.rollingLines == (12 + 0 + 0 + 12) / 4.0)
        #expect(report.monthly.map(\.start) == ["2026-05-01", "2026-06-01", "2026-07-01"])
        #expect(report.monthly[1].commits == 3)
        #expect(report.monthly[2].rollingCommits == (0 + 3 + 1) / 3.0)
    }

    @Test func repositorySummariesTrackActivityAndTopLanguage() {
        let commits = [
            commit("r1", "2026-05-03", repository: "octo/x", ["Swift": .init(added: 9)]),
            commit("r2", "2026-06-05", repository: "octo/x", ["Go": .init(added: 2)]),
            commit("r3", "2026-06-05", repository: "octo/x", ["Swift": .init(updated: 1)]),
            commit("r4", "2026-06-06", repository: "octo/y", ["Go": .init(added: 1)]),
        ]
        let report = build(commits, .all, today: "2026-06-06")
        let x = report.repositories[0]
        #expect(x.repository == "octo/x")
        #expect(x.firstDay == "2026-05-03")
        #expect(x.lastDay == "2026-06-05")
        #expect(x.activeDays == 2)
        #expect(x.topLanguage == "Swift")
        #expect(x.counts.authored == 12)
        #expect(report.totals.repositories == 2)
        #expect(report.repositoryMonthly.map(\.name) == ["octo/x", "octo/y"])
        #expect(report.repositoryMonthly[0].values.map(\.value) == [1, 2])
    }

    @Test func rangesRoundTripThroughTheirArguments() throws {
        for range in CodeStatsRange.presets {
            #expect(CodeStatsRange(argument: range.argument) == range)
            let data = try JSONEncoder().encode(range)
            #expect(try JSONDecoder().decode(CodeStatsRange.self, from: data) == range)
        }
        #expect(CodeStatsRange(argument: "30d") == .days(30))
        #expect(CodeStatsRange(argument: "0d") == nil)
        #expect(CodeStatsRange(argument: "soon") == nil)
    }

    @Test func dayMathRoundTripsAndKnowsWeekdays() {
        #expect(CodeStatsDay("1970-01-01")?.ordinal == 0)
        #expect(CodeStatsDay("2026-06-01")?.weekdayIndex == 1)
        #expect(CodeStatsDay("2024-02-29")?.advanced(by: 1).string == "2024-03-01")
        #expect(CodeStatsDay("2026-12-15")?.nextMonthStart.string == "2027-01-01")
        #expect(CodeStatsDay("2026-06-04")?.weekStart(firstWeekday: 1).string == "2026-05-31")
        #expect(CodeStatsDay("1969-12-31")?.string == "1969-12-31")
    }
}
