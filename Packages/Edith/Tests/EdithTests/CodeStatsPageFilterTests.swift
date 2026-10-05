import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor @Suite struct CodeStatsPageFilterTests {
    private func model() async -> (CodeStatsModel, CodeStatsFakeAgent) {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: CodeStatsPageFixture.date("2026-10-01"))
        )
        agent.facts = CodeStatsFactBuilder.build(commits: CodeStatsPageFixture.commits)
        let model = CodeStatsModel(
            service: agent.service,
            defaults: UserDefaults(suiteName: "test.edith.code-stats-filter.\(UUID())")!,
            calendar: CodeStatsPageFixture.calendar,
            today: { CodeStatsPageFixture.date("2026-10-05") })
        await model.refresh()
        return (model, agent)
    }

    @Test func factTableDrivesTheReportWithoutPresetReports() async {
        let (model, agent) = await model()
        #expect(model.table != nil)
        #expect(model.phase == .content)
        #expect(agent.recorded.contains("facts"))
        #expect(!agent.recorded.contains { $0.hasPrefix("report") })
        await model.select(.all)
        #expect(model.report?.totals.commits == 4)
        #expect(model.report?.range == .all)
    }

    @Test func repositoryLanguageAndResetFiltersRecompute() async {
        let (model, _) = await model()
        await model.select(.all)
        await model.toggleRepository("octo/app")
        #expect(model.report?.totals.commits == 2)
        #expect(model.hasActiveFilter)
        await model.toggleRepository("octo/app")
        await model.toggleLanguage("Python")
        #expect(model.report?.totals.commits == 1)
        await model.toggleOwner("someone-else")
        #expect(model.report?.totals.commits == 0)
        await model.resetFilter()
        #expect(model.report?.totals.commits == 4)
        #expect(!model.hasActiveFilter)
    }

    @Test func facetsAreSortedByActivityAndAuditFollowsTheFilter() async {
        let (model, _) = await model()
        #expect(model.facets.repositories.first?.name == "octo/app")
        #expect(model.facets.owners.map(\.name) == ["octo"])
        #expect(Set(model.facets.languages.map(\.name)) == ["Swift", "TypeScript", "Python"])
        await model.select(.all)
        let before = model.audit?.counted.commits
        await model.toggleRepository("octo/site")
        #expect(model.audit?.counted.commits != before)
    }

    @Test func addingASuggestedIdentityAsksForARecount() async {
        let (model, _) = await model()
        #expect(!model.identityPendingRecount)
        model.addIdentity("me@old-laptop.local")
        #expect(model.identityPendingRecount)
        #expect(model.identity.emails.contains("me@old-laptop.local"))
    }
}
