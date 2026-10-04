import EdithKit
import Foundation
import Testing

@testable import Edith

@MainActor @Suite struct CodeStatsPageModelTests {
    private let defaultsName = "test.edith.code-stats-page.\(UUID().uuidString)"

    private func model(_ agent: CodeStatsFakeAgent) -> CodeStatsModel {
        CodeStatsModel(
            service: agent.service, defaults: UserDefaults(suiteName: defaultsName)!,
            calendar: CodeStatsPageFixture.calendar)
    }

    @Test func showsSkeletonUntilTheStatusArrives() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        let model = model(agent)
        #expect(model.phase == .loading)
        #expect(model.banners.isEmpty)
        await model.refresh()
        #expect(model.phase == .setup)
    }

    @Test func keepsTheSkeletonWhileACachedReportLoads() {
        let status = CodeStatsPageFixture.status(reportedAt: Date())
        #expect(
            CodeStatsPagePhase.resolve(status: status, hasReport: false, reportLoaded: false)
                == .loading)
        #expect(
            CodeStatsPagePhase.resolve(status: status, hasReport: true, reportLoaded: true)
                == .content)
    }

    @Test func emptyMirrorShowsTheSetupChecklist() async {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(storage: .notConfigured))
        let model = model(agent)
        await model.refresh()
        #expect(model.phase == .setup)
        #expect(!model.canStart)
        #expect(model.banners.isEmpty)
        await model.loadProfile()
        #expect(model.seededIdentity?.substrings == ["octo"])
        #expect(model.seededIdentity?.emails == ["octo@example.com"])
        model.useSeededIdentity()
        #expect(model.identity.labels == ["octo@example.com", "*octo*"])
        #expect(model.seededIdentity == nil)
    }

    @Test func firstRunShowsProgressBeforeAnyReport() async {
        var progress = CodeStatsRunProgress(startedAt: Date())
        progress.phase = .syncing
        progress.completed = 34
        progress.total = 212
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                active: CodeStatsActiveRun(trigger: .manual, startedAt: Date()),
                progress: progress))
        let model = model(agent)
        await model.refresh()
        #expect(model.phase == .firstRun)
        #expect(model.isRunning)
        #expect(
            model.progress.flatMap(CodeStatsProgressMath.repositories)
                == "34 of 212 repositories")
        #expect(!model.canStart)
    }

    @Test func disconnectedDriveKeepsTheCachedReportBehindABanner() async throws {
        let reportedAt = CodeStatsPageFixture.date("2026-10-01")
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                storage: .volumeDisconnected(volumeName: "Archive"), reportedAt: reportedAt,
                waitingFor: "Archive"),
            reports: [.days(90): CodeStatsPageFixture.report()])
        let model = model(agent)
        await model.refresh()
        #expect(model.phase == .content)
        #expect(model.report?.totals.commits == 4)
        let banner = try #require(model.banners.first)
        #expect(banner.title == "Archive is disconnected")
        #expect(banner.message.hasPrefix("Archive is disconnected. Showing results from "))
        #expect(banner.message.hasSuffix("Reconnect it or choose another folder."))
        #expect(banner.choosesFolder)
        #expect(!model.canStart)
    }

    @Test func remountRunsTheBlockedScheduleCheck() async {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(
                storage: .volumeDisconnected(volumeName: "Archive"), reportedAt: Date(),
                waitingFor: "Archive"))
        let model = model(agent)
        await model.loadStatus()
        agent.status = CodeStatsPageFixture.status(reportedAt: Date(), waitingFor: "Archive")
        await model.volumesChanged()
        #expect(model.status?.storage.isReady == true)
        #expect(agent.recorded.contains("checkSchedule"))
    }

    @Test func remountWithoutAWaitingRunOnlyRefreshesStatus() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status(reportedAt: Date()))
        let model = model(agent)
        await model.volumesChanged()
        #expect(agent.recorded == ["status"])
    }

    @Test func anOlderStatusNeverReplacesANewerOne() async {
        let active = CodeStatsActiveRun(trigger: .manual, startedAt: Date())
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(active: active, revision: 5))
        let model = model(agent)
        await model.apply(
            CodeStatsPageFixture.status(
                storage: .volumeDisconnected(volumeName: "Archive"), revision: 9))
        await model.loadStatus()
        #expect(model.status?.revision == 9)
        #expect(!model.isRunning)
        #expect(model.status?.storage == .volumeDisconnected(volumeName: "Archive"))
        agent.status = CodeStatsPageFixture.status(revision: 12)
        await model.loadStatus()
        #expect(model.status?.storage.isReady == true)
    }

    @Test func finishingARunReloadsTheReport() async {
        let active = CodeStatsActiveRun(trigger: .scheduled, startedAt: Date())
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status(active: active))
        let model = model(agent)
        await model.refresh()
        #expect(model.phase == .firstRun)
        agent.setReport(CodeStatsPageFixture.report(), for: .days(90))
        await model.apply(CodeStatsPageFixture.status(reportedAt: Date()))
        #expect(model.phase == .content)
        #expect(model.projection.repositoryBars.first?.repository == "octo/app")
    }

    @Test func liveUpdatesFlowThroughTheTopic() async throws {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        let model = model(agent)
        let observing = Task { await model.observe() }
        defer { observing.cancel() }
        var progress = CodeStatsRunProgress(startedAt: Date())
        progress.phase = .analyzing
        agent.updatesContinuation.yield(
            CodeStatsPageFixture.status(
                active: CodeStatsActiveRun(trigger: .scheduled, startedAt: Date()),
                progress: progress))
        for _ in 0..<200 where model.progress?.phase != .analyzing {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.progress?.phase == .analyzing)
    }

    @Test func selectingARangeLoadsThatReport() async {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: Date()),
            reports: [
                .days(90): CodeStatsPageFixture.report(),
                .days(30): CodeStatsPageFixture.report(.days(30)),
            ])
        let model = model(agent)
        await model.refresh()
        await model.select(.days(30))
        #expect(model.range == .days(30))
        #expect(model.report?.range == .days(30))
        #expect(model.report?.totals.commits == 3)
        #expect(agent.recorded.contains("report 30d"))
    }

    @Test func startAndCancelGoThroughTheAgent() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        let model = model(agent)
        await model.refresh()
        #expect(model.canStart)
        await model.start()
        await model.cancel()
        #expect(agent.recorded.contains("start"))
        #expect(agent.recorded.contains("cancel"))
    }

    @Test func discoveredAuthorsFollowIdentityEdits() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        let model = model(agent)
        await model.discoverAuthors()
        #expect(model.authors.first?.countedAsYou == false)
        model.addIdentity("octo@example.com")
        #expect(model.authors.first?.countedAsYou == true)
        model.removeIdentity("octo@example.com")
        #expect(model.authors.first?.countedAsYou == false)
    }

    @Test func toolingBannersCarryTheirCommands() {
        let signedOut = CodeStatsBanner.banners(
            for: CodeStatsPageFixture.status(gitAvailable: false, github: .signedOut))
        #expect(signedOut.map(\.id) == ["git", "github"])
        #expect(signedOut.map(\.command) == ["ed tools install git", "gh auth login"])
        let missing = CodeStatsBanner.banners(
            for: CodeStatsPageFixture.status(githubAvailable: false))
        #expect(missing.map(\.command) == ["ed tools install gh"])
        #expect(
            CodeStatsBanner.banners(for: CodeStatsPageFixture.status(storage: .notConfigured))
                .map(\.id) == ["storage"])
        #expect(
            CodeStatsBanner.banners(for: CodeStatsPageFixture.status(storage: .notWritable))
                .first?.tone == .danger)
    }
}
