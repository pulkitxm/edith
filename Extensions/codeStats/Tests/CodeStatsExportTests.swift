import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import Testing

@testable import CodeStatsExtension

@Suite struct CodeStatsExportTests {
    private let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

    private func snapshot(
        _ range: CodeStatsRange = .days(90)
    ) -> CodeStatsExportSnapshot {
        CodeStatsExportSnapshot(report: CodeStatsPageFixture.report(range))
    }

    @Test func theSnapshotCarriesTheAggregateMetricsOfTheReport() {
        let report = CodeStatsPageFixture.report(.days(90))
        let snapshot = CodeStatsExportSnapshot(report: report)
        #expect(snapshot.commits == report.totals.commits)
        #expect(snapshot.linesAuthored == report.totals.authored)
        #expect(snapshot.linesAdded == report.totals.added)
        #expect(snapshot.linesDeleted == report.totals.deleted)
        #expect(snapshot.netLines == report.totals.net)
        #expect(snapshot.activeDays == report.totals.activeDays)
        #expect(snapshot.longestStreak == report.totals.longestStreak)
        #expect(snapshot.currentStreak == report.totals.currentStreak)
        #expect(snapshot.hasActivity)
        #expect(
            snapshot.linesPerActiveDay == report.totals.authored / max(1, report.totals.activeDays))
        #expect(snapshot.startDay == report.startDay)
        #expect(snapshot.endDay == report.endDay)
    }

    @Test func languagesAreRankedAndCapped() {
        var report = CodeStatsPageFixture.report(.days(90))
        report.languages = (0..<9).map { index in
            CodeStatsLanguageTotal(
                language: "Language \(index)", counts: .init(added: 1_000 - index * 100),
                share: Double(9 - index) / 45)
        }
        let snapshot = CodeStatsExportSnapshot(report: report)
        #expect(snapshot.languages.count == CodeStatsExportSnapshot.languageLimit)
        #expect(snapshot.languageCount == 9)
        #expect(snapshot.languages.first?.name == "Language 0")
        #expect(snapshot.languages.first?.lines == 1_000)
    }

    @Test func rhythmComesFromThePunchcardAndTheTopDays() {
        var report = CodeStatsPageFixture.report(.days(90))
        var grid = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let monday = CodeStatsDay(year: 2026, month: 10, day: 5).weekdayIndex
        grid[monday][14] = 9
        grid[(monday + 2) % 7][9] = 4
        report.punchcard = grid
        let snapshot = CodeStatsExportSnapshot(report: report)
        #expect(snapshot.busiestWeekday == "Monday")
        #expect(snapshot.busiestWeekdayCommits == 9)
        #expect(snapshot.peakHour == 14)
        #expect(snapshot.peakHourCommits == 9)
        #expect(snapshot.bestDay == report.topDays.first?.day)
        #expect(snapshot.bestDayLines == report.topDays.first?.counts.authored)
    }

    @Test func anEmptyPunchcardHasNoRhythm() {
        var report = CodeStatsPageFixture.report(.days(90))
        report.punchcard = Array(repeating: Array(repeating: 0, count: 24), count: 7)
        let snapshot = CodeStatsExportSnapshot(report: report)
        #expect(snapshot.busiestWeekday == nil)
        #expect(snapshot.peakHour == nil)
    }

    @Test func rangesReadAsPlainLabels() {
        #expect(snapshot(.days(30)).rangeLabel == "Last 30 days")
        #expect(snapshot(.days(90)).rangeLabel == "Last 90 days")
        #expect(snapshot(.year).rangeLabel == "Last year")
        #expect(snapshot(.all).rangeLabel == "All time")
    }

    @Test func nothingThatNamesARepositoryAnAuthorOrACommitLeavesTheSnapshot() throws {
        let report = CodeStatsPageFixture.report(.all)
        #expect(!report.repositories.isEmpty)
        let data = try JSONEncoder().encode(CodeStatsExportSnapshot(report: report))
        let text = String(decoding: data, as: UTF8.self).lowercased()
        for summary in report.repositories {
            #expect(!text.contains(summary.repository.lowercased()))
        }
        #expect(!text.contains("octo"))
        #expect(!text.contains("repositor"))
        #expect(!text.contains("@"))
        #expect(!text.contains("email"))
        #expect(!text.contains("subject"))
    }

    @Test(arguments: CodeStatsExportCard.allCases)
    @MainActor func everyCardRendersAPNG(card: CodeStatsExportCard) throws {
        let data = try CodeStatsExportRenderer.pngData(
            snapshot: snapshot(.all), card: card, scale: 1)
        #expect(data.prefix(8) == pngSignature)
        #expect(data.count > 10_000)
    }

}
