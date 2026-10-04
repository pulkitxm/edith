import AppKit
import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

struct CodeStatsWorkflowGitHub: CodeStatsGitHubClient {
    var listing: [CodeStatsRemoteRepository] = []
    var failure: CodeStatsGitHubError?
    var onProfile: @Sendable () -> Void = {}

    func profile() async throws -> CodeStatsProfile {
        onProfile()
        if let failure { throw failure }
        return CodeStatsProfile(id: 7, login: "octocat", name: "Octo")
    }

    func emails(for profile: CodeStatsProfile) async -> [String] { [profile.noreplyEmail] }

    func repositories() async throws -> [CodeStatsRemoteRepository] {
        if let failure { throw failure }
        return listing
    }
}

struct CodeStatsWorkflowHarness {
    let fixture: CodeStatsGitFixture
    let mirror: URL
    let settings: CodeStatsLocked<CodeStatsSettings>
    let published: CodeStatsLocked<[CodeStatsStatus]>
    let store: CodeStatsStore
    let tasks: AgentTaskService
    let runtime: AgentRuntime
    let resolutions = CodeStatsLocked(0)
    let engineGits = CodeStatsLocked([CodeStatsGit]())

    init(limits: AgentTaskLimits = AgentTaskLimits()) throws {
        fixture = try CodeStatsGitFixture()
        mirror = fixture.root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        settings = CodeStatsLocked(
            CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me))
        published = CodeStatsLocked([])
        store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        tasks = try AgentTaskService(directory: nil, limits: limits)
        runtime = AgentRuntime(build: "test", store: nil)
    }

    func workflow(
        github: CodeStatsWorkflowGitHub? = CodeStatsWorkflowGitHub(), git: CodeStatsGit? = nil,
        resolveGit: (@Sendable () -> CodeStatsGit?)? = nil, probe: CodeStatsFileProbe = .live,
        enabled: Bool = true, constrained: Bool = false
    ) async -> CodeStatsWorkflow {
        let settings = settings
        let published = published
        let resolutions = resolutions
        let engineGits = engineGits
        let tool = git ?? fixture.tool
        let resolve = resolveGit ?? { tool }
        let environment = CodeStatsEnvironment(
            settings: { settings.update { $0 } },
            saveIdentity: { identity in settings.update { $0.identity = identity } },
            isEnabled: { enabled },
            git: {
                resolutions.update { $0 += 1 }
                return resolve()
            }, github: { github }, probe: probe, store: store,
            isThermallyConstrained: { constrained },
            makeEngine: { github, git, store, probe in
                engineGits.update { $0.append(git) }
                return CodeStatsEngine(
                    github: github, git: git, store: store, probe: probe, progressInterval: 0)
            })
        let workflow = CodeStatsWorkflow(environment: environment) { status in
            published.update { $0.append(status) }
        }
        await workflow.register(on: tasks, runtime: runtime)
        return workflow
    }

    func remote(_ name: String) async throws -> URL {
        let work = try await fixture.makeRepository("work/\(name)")
        try await fixture.commit(
            ["\(name).swift": "let a = 1\n"], in: work, author: ("Octocat", "you@example.com"),
            date: "2024-05-01T10:00:00+00:00")
        let remote = fixture.root.appendingPathComponent("remote/\(name).git")
        try await fixture.git(["clone", "--bare", "-q", work.path, remote.path])
        return remote
    }

    func finished(_ id: UUID) async throws -> AgentTaskState {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            let state = try await tasks.status(id).snapshot.state
            if state.isTerminal { return state }
            try await Task.sleep(for: .milliseconds(50))
        }
        return try await tasks.status(id).snapshot.state
    }

    func block() async throws -> (id: UUID, release: @Sendable () -> Void) {
        let (gate, release) = AsyncStream<Void>.makeStream()
        await tasks.register(operation: "test.block") { _, _ in
            for await _ in gate {}
            return Data()
        }
        let id = UUID()
        _ = try await tasks.submit(
            AgentTaskSubmission(id: id, operation: "test.block", title: "Block", payload: Data()))
        return (id, { release.finish() })
    }

    func status(_ workflow: CodeStatsWorkflow) async throws -> CodeStatsStatus {
        try AgentPayload.decode(
            CodeStatsStatus.self,
            from: await runtime.perform(operation: CodeStatsAgentOperation.status, payload: Data()))
    }
}

@Suite struct CodeStatsWorkflowTests {
    @Test func aSubmittedRunPublishesProgressAndKeepsOneFlight() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let remote = try await harness.remote("demo")
        let workflow = await harness.workflow(
            github: CodeStatsWorkflowGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/demo", cloneURL: remote.path)
            ]))
        let run = try await workflow.start(.manual)
        let again = try AgentPayload.decode(
            CodeStatsActiveRun.self,
            from: await harness.runtime.perform(
                operation: CodeStatsAgentOperation.start, payload: Data()))
        #expect(again == run)
        #expect(try await harness.finished(run.taskID) == .succeeded)

        let phases = harness.published.update { $0 }.compactMap { $0.progress?.phase }
        #expect(phases.contains(.syncing))
        #expect(phases.contains(.analyzing))
        let output = try await harness.tasks.status(run.taskID).output.map(\.text)
        #expect(output.contains("Synced 1 of 1 repositories"))

        let status = try await harness.status(workflow)
        #expect(!status.isRunning)
        #expect(status.progress == nil)
        #expect(status.state.lastRun?.outcome == .completed)
        #expect(status.state.lastRunAt == run.startedAt)
        #expect(status.state.profile?.login == "octocat")
        #expect(status.storage.isReady)
        #expect(harness.published.update { $0.last?.isRunning } == false)

        let report = try AgentPayload.decode(
            CodeStatsReport?.self,
            from: await harness.runtime.perform(
                operation: CodeStatsAgentOperation.report,
                payload: AgentPayload.encode(CodeStatsRange.all)))
        #expect(report?.totals.commits == 1)
        let authors = try await workflow.authors()
        #expect(authors.first?.email == "you@example.com")
        #expect(authors.first?.countedAsYou == true)
    }

    @Test func cancellingStopsTheRunAndRecordsIt() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let blocking = try harness.fixture.blockingTool(on: "clone")
        let workflow = await harness.workflow(
            github: CodeStatsWorkflowGitHub(listing: [
                CodeStatsRemoteRepository(fullName: "octo/huge", cloneURL: "/nowhere/huge.git")
            ]), git: blocking.tool)
        let run = try await workflow.start(.manual)
        _ = try #require(await harness.fixture.waitForProcess(blocking.pidFile))
        #expect(try await harness.status(workflow).progress?.phase == .syncing)
        _ = try await harness.runtime.perform(
            operation: CodeStatsAgentOperation.cancel, payload: Data())
        #expect(try await harness.finished(run.taskID) == .cancelled)
        let status = try await harness.status(workflow)
        #expect(status.state.lastRun?.outcome == .cancelled)
        #expect(!status.isRunning)
    }

    @Test func aDriveThatDisappearsMidRunLeavesTheRunInterruptedAndWaiting() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let local = try await harness.fixture.makeRepository("mirror/octo/local")
        try await harness.fixture.commit(
            ["a.swift": "let a = 1\n"], in: local, author: ("Octocat", "you@example.com"),
            date: "2024-05-01T10:00:00+00:00")
        let drive = CodeStatsStorageEvaluator.standardized(harness.mirror.path)
        let mounted = CodeStatsLocked(true)
        var probe = CodeStatsFileProbe.live
        probe.volume = { path in
            path.hasPrefix(drive) ? CodeStatsVolume(name: "Drive", mountPoint: drive) : nil
        }
        probe.isMounted = { _ in mounted.update { $0 } }
        let blocking = try harness.fixture.blockingTool(on: "log")
        let workflow = await harness.workflow(github: nil, git: blocking.tool, probe: probe)
        let run = try await workflow.start(.manual)
        let pid = try #require(await harness.fixture.waitForProcess(blocking.pidFile))
        mounted.update { $0 = false }
        kill(pid, SIGKILL)
        #expect(try await harness.finished(run.taskID) == .succeeded)
        let status = try await harness.status(workflow)
        #expect(status.storage == .volumeDisconnected(volumeName: "Drive"))
        #expect(status.state.lastRun?.outcome == .volumeDisconnected(volumeName: "Drive"))
        #expect(status.state.lastRun?.failed == 0)
        #expect(status.state.lastRunAt == nil)
        #expect(status.state.firstAttemptAt == run.startedAt)
        #expect(status.state.waitingFor == "Drive")
    }

    @Test func anInterruptedRunIsRecoveredWithoutRestarting() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        try harness.store.saveState(
            CodeStatsState(active: CodeStatsActiveRun(trigger: .scheduled, startedAt: started)))
        let workflow = await harness.workflow()
        let status = try await harness.status(workflow)
        #expect(!status.isRunning)
        #expect(status.state.lastRun?.outcome == .interrupted)
        #expect(status.state.lastRun?.startedAt == started)
        #expect(await harness.tasks.snapshots().isEmpty)
        #expect(harness.store.loadState().active == nil)
    }

    @Test func anEmptyIdentityIsSeededFromTheGitHubProfile() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        harness.settings.update { $0.identity = CodeStatsIdentity() }
        let workflow = await harness.workflow()
        let run = try await workflow.start(.manual)
        #expect(try await harness.finished(run.taskID) == .succeeded)
        let identity = harness.settings.update { $0.identity }
        #expect(identity.substrings == ["octocat"])
        #expect(identity.emails == ["7+octocat@users.noreply.github.com"])
    }

    @Test func aDisabledAbilityRefusesToStart() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow(enabled: false)
        await #expect(throws: AgentError.self) { _ = try await workflow.start(.manual) }
        #expect(await harness.tasks.snapshots().isEmpty)
    }
}

@Suite struct CodeStatsWorkflowRecoveryTests {
    @Test func registeringProbesNothingAndEachRunResolvesGitAgain() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let signedIn = CodeStatsLocked(false)
        let tool = harness.fixture.tool
        let helper = URL(fileURLWithPath: "/usr/bin/true")
        let workflow = await harness.workflow(resolveGit: {
            CodeStatsGit(
                executable: tool.executable, environment: tool.environment,
                credentialHelper: signedIn.update { $0 } ? helper : nil)
        })
        #expect(harness.resolutions.update { $0 } == 0)
        #expect(harness.published.update { $0.isEmpty })

        let first = try await workflow.start(.manual)
        #expect(try await harness.finished(first.taskID) == .succeeded)
        signedIn.update { $0 = true }
        let second = try await workflow.start(.manual)
        #expect(try await harness.finished(second.taskID) == .succeeded)
        #expect(harness.engineGits.update { $0.map(\.credentialHelper) } == [nil, helper])
    }

    @Test func aManualRunRefusesWhenTheFolderOrGitIsMissing() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        harness.settings.update { $0.folder = nil }
        let workflow = await harness.workflow(resolveGit: { nil })
        await #expect(throws: AgentError(.refused, CodeStatsStorageStatus.notConfigured.summary)) {
            _ = try await workflow.start(.manual)
        }
        harness.settings.update { $0.folder = harness.mirror.path }
        await #expect(throws: AgentError(.refused, CodeStatsWorkflow.gitMissing)) {
            _ = try await workflow.start(.manual)
        }
        #expect(await harness.tasks.snapshots().isEmpty)
        #expect(harness.store.loadState().firstAttemptAt == nil)
    }

    @Test func cancellingAQueuedRunRecordsItWithoutRunning() async throws {
        let harness = try CodeStatsWorkflowHarness(limits: AgentTaskLimits(concurrency: 1))
        defer { harness.fixture.remove() }
        let blocker = try await harness.block()
        let workflow = await harness.workflow()
        let run = try await workflow.start(.manual)
        #expect(try await harness.tasks.status(run.taskID).snapshot.state == .queued)
        try await workflow.cancel()
        let status = try await harness.status(workflow)
        #expect(!status.isRunning)
        #expect(status.state.lastRun?.outcome == .cancelled)
        #expect(status.state.lastRunAt == run.startedAt)
        blocker.release()
        #expect(try await harness.finished(blocker.id) == .succeeded)
        #expect(try await harness.finished(run.taskID) == .cancelled)
        #expect(harness.engineGits.update { $0.isEmpty })
    }

    @Test func aTaskCancelledBehindTheWorkflowIsReconciled() async throws {
        let harness = try CodeStatsWorkflowHarness(limits: AgentTaskLimits(concurrency: 1))
        defer { harness.fixture.remove() }
        let blocker = try await harness.block()
        defer { blocker.release() }
        let workflow = await harness.workflow()
        let run = try await workflow.start(.manual)
        _ = try await harness.tasks.cancel(run.taskID)
        let status = try await harness.status(workflow)
        #expect(!status.isRunning)
        #expect(status.state.lastRun?.outcome == .cancelled)
        #expect(status.state.lastRun?.startedAt == run.startedAt)
        #expect(harness.store.loadState().active == nil)
    }

    @Test func concurrentAuthorRequestsShareOneScan() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let local = try await harness.fixture.makeRepository("mirror/octo/local")
        try await harness.fixture.commit(
            ["a.swift": "let a = 1\n"], in: local, author: ("Octocat", "you@example.com"),
            date: "2024-05-01T10:00:00+00:00")
        let blocking = try harness.fixture.blockingTool(on: "log")
        let workflow = await harness.workflow(git: blocking.tool)
        async let first = workflow.authors()
        let pid = try #require(await harness.fixture.waitForProcess(blocking.pidFile))
        async let second = workflow.authors()
        try await Task.sleep(for: .milliseconds(300))
        kill(pid, SIGKILL)
        let (one, two) = try await (first, second)
        #expect(one == two)
        #expect(harness.resolutions.update { $0 } == 1)
    }

    @Test func anIdentityAddedWhileSeedingIsKept() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let settings = harness.settings
        settings.update { $0.identity = CodeStatsIdentity() }
        let added = CodeStatsIdentity(emails: ["me@work.com"])
        let github = CodeStatsWorkflowGitHub(onProfile: {
            settings.update { if $0.identity.isEmpty { $0.identity = added } }
        })
        let workflow = await harness.workflow(github: github)
        let run = try await workflow.start(.manual)
        #expect(try await harness.finished(run.taskID) == .succeeded)
        #expect(settings.update { $0.identity } == added)
    }

    @Test func theProfileLookupReportsTheGitHubState() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let signedIn = await harness.workflow().profile()
        #expect(signedIn.profile?.login == "octocat")
        #expect(signedIn.emails == ["7+octocat@users.noreply.github.com"])
        #expect(signedIn.issue == nil)
        let reloaded = try await harness.status(await harness.workflow())
        #expect(reloaded.state.profile?.login == "octocat")

        let signedOut = await harness.workflow(
            github: CodeStatsWorkflowGitHub(failure: .signedOut)
        ).profile()
        #expect(signedOut == CodeStatsProfileLookup(issue: .signedOut))
        #expect(await harness.workflow(github: nil).profile().issue == .unavailable)
    }

    @Test func aSignedOutGitHubIsRecordedOnTheRun() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow(github: CodeStatsWorkflowGitHub(failure: .signedOut))
        let run = try await workflow.start(.manual)
        #expect(try await harness.finished(run.taskID) == .succeeded)
        let status = try await harness.status(workflow)
        #expect(status.state.lastRun?.outcome == .completed)
        #expect(status.githubIssue == .signedOut)
    }

    @Test func failedRepositoriesKeepOnlyTheNewestErrors() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let missing = harness.fixture.root.appendingPathComponent("missing")
        let listing = (0..<(CodeStatsEngine.errorLimit + 5)).map {
            CodeStatsRemoteRepository(
                fullName: "octo/gone\($0)", cloneURL: missing.appendingPathComponent("\($0)").path)
        }
        let workflow = await harness.workflow(github: CodeStatsWorkflowGitHub(listing: listing))
        let run = try await workflow.start(.manual)
        #expect(try await harness.finished(run.taskID) == .succeeded)
        let last = try #require(try await harness.status(workflow).state.lastRun)
        #expect(last.failed == listing.count)
        #expect(last.errors.count == CodeStatsEngine.errorLimit)
    }

    @Test func settingsChangesPublishOnlyWhileEnabled() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        await harness.workflow(enabled: false).settingsChanged()
        #expect(harness.published.update { $0.isEmpty })
        harness.settings.update { $0.schedule = .weekly(weekday: 2, hour: 8) }
        await harness.workflow().settingsChanged()
        #expect(
            harness.published.update { $0.last?.settings.schedule }
                == .weekly(weekday: 2, hour: 8))
    }

    @Test func everySnapshotCarriesANewerRevision() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow()
        let first = try await harness.status(workflow)
        await workflow.settingsChanged()
        let published = try #require(harness.published.update { $0.last })
        let second = try await harness.status(workflow)
        #expect(first.revision > 0)
        #expect(published.revision > first.revision)
        #expect(second.revision > published.revision)
    }
}

@Suite struct CodeStatsScheduleJobTests {
    private func schedule(
        _ harness: CodeStatsWorkflowHarness, lastRunAt: Date?, firstAttemptAt: Date? = nil
    ) throws {
        harness.settings.update { $0.schedule = .daily(hour: 3) }
        try harness.store.saveState(
            CodeStatsState(lastRunAt: lastRunAt, firstAttemptAt: firstAttemptAt))
    }

    private func job(
        _ workflow: CodeStatsWorkflow, _ harness: CodeStatsWorkflowHarness
    ) async throws -> CodeStatsStatus {
        let body = try #require(
            AgentJobCatalog.collectors(store: nil, codeStats: workflow)[
                CodeStatsWorkflow.scheduleJobID])
        #expect(try await body() == nil)
        return try #require(harness.published.update { $0.last })
    }

    private func started(_ harness: CodeStatsWorkflowHarness) throws -> CodeStatsActiveRun {
        try #require(harness.published.update { $0.lazy.compactMap(\.state.active).first })
    }

    @Test func aScheduleWithoutAFirstRunIsNotDue() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: nil)
        let status = try await job(await harness.workflow(), harness)
        #expect(!status.isRunning)
        #expect(status.nextRunAt == nil)
        #expect(await harness.tasks.snapshots().isEmpty)
    }

    @Test func aRecentRunIsNotDueYet() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-60))
        let status = try await job(await harness.workflow(), harness)
        #expect(!status.isRunning)
        #expect(status.gitAvailable)
        #expect((status.nextRunAt ?? .distantPast) > Date())
        #expect(await harness.tasks.snapshots().isEmpty)
    }

    @Test func aDueScheduleSubmitsOneScheduledRun() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let workflow = await harness.workflow()
        _ = try await job(workflow, harness)
        let active = try started(harness)
        #expect(active.trigger == .scheduled)
        _ = try await job(workflow, harness)
        #expect(await harness.tasks.snapshots().count == 1)
        #expect(try await harness.finished(active.taskID) == .succeeded)
        let after = try await harness.status(workflow)
        #expect(after.state.lastRunAt == active.startedAt)
        #expect((after.nextRunAt ?? .distantPast) > active.startedAt)
    }

    @Test func aDueScheduleWaitsForTheDriveWithoutRunning() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let mounted = CodeStatsLocked(false)
        var probe = CodeStatsFileProbe.live
        probe.volume = { _ in CodeStatsVolume(name: "Archive", mountPoint: "/Volumes/Archive") }
        probe.isMounted = { _ in mounted.update { $0 } }
        let workflow = await harness.workflow(probe: probe)
        let waiting = try await job(workflow, harness)
        #expect(!waiting.isRunning)
        #expect(waiting.state.waitingFor == "Archive")
        #expect(waiting.storage == .volumeDisconnected(volumeName: "Archive"))
        #expect(await harness.tasks.snapshots().isEmpty)

        mounted.update { $0 = true }
        _ = try await job(workflow, harness)
        #expect(try await harness.status(workflow).state.waitingFor == nil)
        #expect(try await harness.finished(try started(harness).taskID) == .succeeded)
    }

    @Test func aFirstRunCutShortByTheDriveStillArmsTheSchedule() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(
            harness, lastRunAt: nil, firstAttemptAt: Date().addingTimeInterval(-3 * 86_400))
        let mounted = CodeStatsLocked(false)
        var probe = CodeStatsFileProbe.live
        probe.volume = { _ in CodeStatsVolume(name: "Archive", mountPoint: "/Volumes/Archive") }
        probe.isMounted = { _ in mounted.update { $0 } }
        let workflow = await harness.workflow(probe: probe)
        let waiting = try await job(workflow, harness)
        #expect(waiting.nextRunAt != nil)
        #expect(waiting.state.waitingFor == "Archive")
        #expect(await harness.tasks.snapshots().isEmpty)

        mounted.update { $0 = true }
        _ = try await job(workflow, harness)
        let active = try started(harness)
        #expect(active.trigger == .scheduled)
        #expect(try await harness.finished(active.taskID) == .succeeded)
        #expect(try await harness.status(workflow).state.lastRunAt == active.startedAt)
    }

    @Test func seriousThermalPressureDefersADueRun() async throws {
        let harness = try CodeStatsWorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let status = try await job(await harness.workflow(constrained: true), harness)
        #expect(!status.isRunning)
        #expect(await harness.tasks.snapshots().isEmpty)
    }
}

@Suite struct CodeStatsVolumeWatchTests {
    @Test func mountAndUnmountWakeTheScheduleCheckUntilStopped() {
        let center = NotificationCenter()
        let watch = CodeStatsVolumeWatch(center: center)
        let changes = CodeStatsLocked(0)
        watch.start { changes.update { $0 += 1 } }
        for name in CodeStatsVolumeWatch.names { center.post(name: name, object: nil) }
        #expect(changes.update { $0 } == 2)
        watch.stop()
        center.post(name: NSWorkspace.didMountNotification, object: nil)
        #expect(changes.update { $0 } == 2)
    }
}
