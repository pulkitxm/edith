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
        #expect(banner.message.hasPrefix("Showing results from "))
        #expect(banner.message.hasSuffix("Reconnect it or choose another folder."))
        #expect(banner.choosesFolder)
        #expect(!model.canStart)
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
                progress: progress, revision: 1))
        for _ in 0..<1_000 where model.progress?.phase != .analyzing {
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

    @Test func aSignedOutProfileIsCheckedAgainUntilItLoads() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        agent.profileLookup = CodeStatsProfileLookup(issue: .signedOut)
        let model = model(agent)
        await model.loadProfileIfNeeded()
        #expect(model.profileLookup?.issue == .signedOut)
        #expect(model.seededIdentity == nil)
        agent.profileLookup = CodeStatsProfileLookup(
            profile: CodeStatsProfile(id: 7, login: "octo"), emails: ["octo@example.com"])
        await model.loadProfileIfNeeded()
        #expect(model.profileLookup?.profile?.login == "octo")
        #expect(model.seededIdentity?.substrings == ["octo"])
        await model.loadProfileIfNeeded()
        #expect(agent.recorded.filter { $0 == "profile" }.count == 2)
        #expect(!model.profileLoading)
    }

    @Test func authorsSharingAnEmailKeepDistinctIdentities() async {
        let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
        agent.authors = [
            CodeStatsDiscoveredAuthor(
                name: "Pulkit", email: "a@x.com", commits: 9, countedAsYou: false),
            CodeStatsDiscoveredAuthor(
                name: "pulkitxm", email: "a@x.com", commits: 4, countedAsYou: false),
        ]
        let model = model(agent)
        await model.discoverAuthors()
        #expect(Set(model.authors.map(\.id)).count == 2)
        model.addIdentity("a@x.com")
        #expect(model.authors.allSatisfy { $0.countedAsYou })
    }

    @Test func aFailedRefreshIsExplainedUntilANewerReportLands() async throws {
        let failed = CodeStatsRunResult(
            outcome: .failed(message: "Saving the report failed."),
            startedAt: CodeStatsPageFixture.date("2026-10-03"),
            finishedAt: CodeStatsPageFixture.date("2026-10-03"),
            errors: ["octo/app: disk full"])
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(lastRun: failed),
            reports: [.days(90): CodeStatsPageFixture.report()])
        let model = model(agent)
        await model.loadStatus()
        #expect(model.phase == .setup)
        let banner = try #require(model.banners.first)
        #expect(banner.id == "lastRun")
        #expect(banner.tone == .danger)
        #expect(banner.message == "Saving the report failed. octo/app: disk full")
        let older = CodeStatsPageFixture.status(
            reportedAt: CodeStatsPageFixture.date("2026-10-04"), lastRun: failed)
        #expect(CodeStatsBanner.lastRun(older) == nil)
        let interrupted = CodeStatsRunResult(
            outcome: .interrupted, startedAt: CodeStatsPageFixture.date("2026-10-05"),
            finishedAt: CodeStatsPageFixture.date("2026-10-05"))
        let banners = CodeStatsBanner.banners(
            for: CodeStatsPageFixture.status(
                reportedAt: CodeStatsPageFixture.date("2026-10-04"), lastRun: interrupted))
        #expect(banners.map(\.title) == ["The last refresh stopped early"])
    }

    @Test func aFailedReportLoadOffersRetryInsteadOfSetup() async throws {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: Date()),
            reports: [.days(90): CodeStatsPageFixture.report()])
        agent.failingReports = [.days(90)]
        let model = model(agent)
        await model.refresh()
        #expect(model.phase == .unavailable)
        #expect(model.errorMessage == nil)
        let banner = try #require(model.banners.first)
        #expect(banner.id == "report")
        #expect(banner.retriesReport)
        agent.failingReports = []
        await model.loadReport()
        #expect(model.phase == .content)
        #expect(model.banners.isEmpty)
    }

    @Test func aFailedRangeSwitchKeepsThePreviousRangeMarkedAsLoading() async {
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: Date()),
            reports: [.days(90): CodeStatsPageFixture.report()])
        agent.failingReports = [.all]
        let model = model(agent)
        await model.refresh()
        #expect(!model.showsPreviousRange)
        await model.select(.all)
        #expect(model.phase == .content)
        #expect(model.showsPreviousRange)
        #expect(model.banners.map(\.id) == ["report"])
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

    @Test func nextRunLabelReflectsRunsDrivesAndDueSchedules() {
        let now = CodeStatsPageFixture.date("2026-10-05", hour: 12)
        func status(
            _ schedule: CodeStatsSchedule, next: Date?, waitingFor: String? = nil,
            active: CodeStatsActiveRun? = nil
        ) -> CodeStatsStatus {
            CodeStatsStatus(
                settings: CodeStatsSettings(folder: "/Volumes/Archive/GitHub", schedule: schedule),
                storage: .ready(freeBytes: 1), gitAvailable: true, githubAvailable: true,
                state: CodeStatsState(active: active, waitingFor: waitingFor), nextRunAt: next,
                progress: nil)
        }
        let daily = CodeStatsSchedule.daily(hour: 9)
        #expect(status(.manual, next: nil).nextRunLabel(now: now) == "Manual")
        #expect(status(daily, next: nil).nextRunLabel(now: now) == "After first sync")
        #expect(
            status(daily, next: now, waitingFor: "Archive").nextRunLabel(now: now)
                == "When Archive is back")
        #expect(
            status(daily, next: now.addingTimeInterval(-60)).nextRunLabel(now: now) == "Due now")
        #expect(
            status(
                daily, next: nil, active: CodeStatsActiveRun(trigger: .scheduled, startedAt: now)
            ).nextRunLabel(now: now) == "Running now")
        #expect(
            status(daily, next: now.addingTimeInterval(3600)).nextRunLabel(now: now)
                != "Due now")
    }
}
