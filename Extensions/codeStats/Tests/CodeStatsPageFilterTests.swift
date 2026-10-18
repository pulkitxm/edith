@testable import CodeStatsExtension
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

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

    @Test func folderAndRefreshFailuresReachTheCallerInsteadOfTheModelAlert() async throws {
        let (model, _) = await model()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)").path
        await #expect(throws: (any Error).self) { _ = try await model.selectFolder(missing) }
        #expect(model.errorMessage == nil)
        let failing = CodeStatsModel(
            service: CodeStatsPageService(
                status: { throw CodeStatsFailure(.unavailable, "git is missing") },
                report: { _ in nil },
                start: { throw CodeStatsFailure(.unavailable, "git is missing") },
                cancel: { throw CodeStatsFailure(.unavailable, "git is missing") },
                profile: { throw CodeStatsFailure(.unavailable, "git is missing") },
                authors: { [] }, updates: { AsyncStream { $0.finish() } }),
            defaults: UserDefaults(suiteName: "test.edith.code-stats-start.\(UUID())")!)
        do {
            try await failing.startOrThrow()
            Issue.record("the refresh should have failed")
        } catch {
            #expect(error.localizedDescription.contains("git is missing"))
        }
    }

    @Test func selectionSurvivesPageRecreationAndRefresh() async {
        let (model, agent) = await model()
        let defaults = UserDefaults(suiteName: "test.edith.persisted-filters.\(UUID())")!
        let first = CodeStatsModel(service: agent.service, defaults: defaults)
        await first.select(.all)
        await first.toggleRepository("octo/app")
        await first.updateFilter { $0.includeBulk = true }
        let restored = CodeStatsModel(service: agent.service, defaults: defaults)
        #expect(restored.range == .all)
        #expect(restored.filter.repositories == ["octo/app"])
        #expect(restored.filter.includeBulk)
        await restored.refresh()
        #expect(restored.filter == first.filter)
        await restored.resetFilter()
        #expect(CodeStatsModel(service: agent.service, defaults: defaults).filter == .default)
        #expect(model.table != nil)
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
