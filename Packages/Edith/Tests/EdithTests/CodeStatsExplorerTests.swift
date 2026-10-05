import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor @Suite struct CodeStatsExplorerTests {
    private static func commit(
        _ sha: String, _ day: String, _ repository: String, lines: Int, hour: Int = 10
    ) -> CodeStatsCommit {
        CodeStatsCommit(
            sha: sha, day: day, hour: hour, repository: repository,
            languages: ["Swift": .init(added: lines)])
    }

    private static var commits: [CodeStatsCommit] {
        [
            commit("a1", "2025-03-04", "me/big", lines: 900),
            commit("a2", "2026-03-10", "me/big", lines: 900),
            commit("a3", "2026-04-02", "me/big", lines: 900),
            commit("b1", "2026-03-11", "org/small", lines: 40),
            commit("c1", "2026-04-20", "me/tiny", lines: 10, hour: 23),
        ]
    }

    private func explorer(_ filter: CodeStatsFilter = .default) -> CodeStatsExplorer {
        let table = CodeStatsFactBuilder.build(commits: Self.commits)
        return CodeStatsExplorer(
            table: table, filter: filter, startDay: "2026-01-01", endDay: "2026-06-30",
            calendar: CodeStatsPageFixture.calendar)
    }

    @Test func detectsADominantRepositoryAndDropsItWhenExcluded() {
        #expect(explorer().dominant?.repository == "me/big")
        let excluded = explorer(CodeStatsFilter(excludedRepositories: ["me/big"]))
        #expect(excluded.dominant?.repository != "me/big")
        #expect(!excluded.stripRepositories.contains("me/big"))
    }

    @Test func stripRowsAreScaledToTheirOwnPeak() {
        let strip = explorer().strip
        #expect(strip.filter { $0.repository == "org/small" }.map(\.level) == [1])
        #expect(strip.filter { $0.repository == "me/tiny" }.map(\.level) == [1])
        #expect(strip.allSatisfy { $0.level > 0 && $0.level <= 1 })
    }

    @Test func yearOverYearHoursOwnersAndNewRepositories() {
        let explorer = explorer()
        #expect(explorer.yearNames == ["2025", "2026"])
        #expect(explorer.years.first { $0.year == "2025" && $0.month == 3 }?.commits == 1)
        #expect(explorer.hours[23].commits == 1)
        #expect(Set(explorer.owners.map(\.name)) == ["me", "org"])
        #expect(explorer.newRepositories.flatMap(\.names).sorted() == ["me/tiny", "org/small"])
    }

    @Test func slicesFoldTheTailIntoOther() {
        let values = (0..<10).map { ("r\($0)", 1, 10 - $0) }
        let slices = CodeStatsExplorer.slices(values, total: 55)
        #expect(slices.count == CodeStatsExplorer.sliceCount + 1)
        #expect(slices.last?.isOther == true)
        #expect(slices.last?.lines == 6)
    }

    @Test func customRangeParsesReportsAndRoundTrips() throws {
        let range = try #require(CodeStatsRange(argument: "2026-04-30..2026-03-01"))
        #expect(range == .between("2026-03-01", "2026-04-30"))
        #expect(range.argument == "2026-03-01..2026-04-30")
        let decoded = try JSONDecoder().decode(
            CodeStatsRange.self, from: JSONEncoder().encode(range))
        #expect(decoded == range)
        let report = CodeStatsReportBuilder.build(
            table: CodeStatsFactBuilder.build(commits: Self.commits), filter: .default,
            range: range, today: CodeStatsPageFixture.date("2026-10-05"),
            calendar: CodeStatsPageFixture.calendar)
        #expect(report.startDay == "2026-03-01")
        #expect(report.endDay == "2026-04-30")
        #expect(report.totals.commits == 4)
    }

    @Test func excludedRepositoriesLeaveReportAndAudit() {
        let table = CodeStatsFactBuilder.build(commits: Self.commits)
        let filter = CodeStatsFilter(excludedRepositories: ["me/big"])
        let report = CodeStatsReportBuilder.build(
            table: table, filter: filter, range: .all,
            today: CodeStatsPageFixture.date("2026-10-05"), calendar: CodeStatsPageFixture.calendar)
        #expect(report.totals.commits == 2)
        #expect(CodeStatsAuditBuilder.build(table: table, filter: filter).raw.commits == 2)
        let decoded = try? JSONDecoder().decode(
            CodeStatsFilter.self, from: Data(#"{"includeBulk":true}"#.utf8))
        #expect(decoded?.includeBulk == true)
        #expect(decoded?.excludedRepositories.isEmpty == true)
    }

    @Test func zoomSetsACustomRangeAndClearingRestoresThePreset() async {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: CodeStatsPageFixture.date("2026-10-01"))
        )
        agent.facts = CodeStatsFactBuilder.build(commits: Self.commits)
        let model = CodeStatsModel(
            service: agent.service,
            defaults: UserDefaults(suiteName: "test.edith.code-stats-explorer.\(UUID())")!,
            calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        await model.select(.year)
        await model.zoom(
            from: CodeStatsPageFixture.date("2026-03-01"),
            to: CodeStatsPageFixture.date("2026-03-31"))
        #expect(model.isCustomRange)
        #expect(model.report?.totals.commits == 2)
        await model.clearCustomRange()
        #expect(model.range == .year)
        await model.toggleExcludedRepository("me/big")
        #expect(model.filter.excludedRepositories == ["me/big"])
        #expect(model.explorer.dominant?.repository != "me/big")
    }

    @Test func dayDetailsBreakDownEachDayByRepositoryAndLanguage() {
        let days = explorer().days
        #expect(days["2026-03-10"]?.commits == 1)
        #expect(days["2026-03-10"]?.repositories.map(\.name) == ["me/big"])
        #expect(days["2026-03-10"]?.languages.map(\.name) == ["Swift"])
        #expect(days["2025-03-04"] == nil)
    }
}
