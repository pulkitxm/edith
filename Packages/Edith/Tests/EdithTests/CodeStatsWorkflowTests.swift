import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

private struct WorkflowGitHub: CodeStatsGitHubClient {
    var listing: [CodeStatsRemoteRepository] = []

    func profile() async throws -> CodeStatsProfile {
        CodeStatsProfile(id: 7, login: "octocat", name: "Octo")
    }

    func emails(for profile: CodeStatsProfile) async -> [String] { [profile.noreplyEmail] }

    func repositories() async throws -> [CodeStatsRemoteRepository] { listing }
}

private struct WorkflowHarness {
    let fixture: CodeStatsGitFixture
    let mirror: URL
    let settings: CodeStatsLocked<CodeStatsSettings>
    let published: CodeStatsLocked<[CodeStatsStatus]>
    let store: CodeStatsStore
    let tasks: AgentTaskService
    let runtime: AgentRuntime

    init() throws {
        fixture = try CodeStatsGitFixture()
        mirror = fixture.root.appendingPathComponent("mirror", isDirectory: true)
        try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
        settings = CodeStatsLocked(
            CodeStatsSettings(folder: mirror.path, identity: CodeStatsGitFixture.me))
        published = CodeStatsLocked([])
        store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        tasks = try AgentTaskService(directory: nil)
        runtime = AgentRuntime(build: "test", store: nil)
    }

    func workflow(
        github: WorkflowGitHub? = WorkflowGitHub(), git: CodeStatsGit? = nil,
        probe: CodeStatsFileProbe = .live, enabled: Bool = true, constrained: Bool = false
    ) async -> CodeStatsWorkflow {
        let settings = settings
        let published = published
        let tool = git ?? fixture.tool
        let environment = CodeStatsEnvironment(
            settings: { settings.update { $0 } },
            saveIdentity: { identity in settings.update { $0.identity = identity } },
            isEnabled: { enabled }, git: { tool }, github: { github }, probe: probe,
            store: store, isThermallyConstrained: { constrained },
            makeEngine: { github, git, store, probe in
                CodeStatsEngine(
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

    func status(_ workflow: CodeStatsWorkflow) async throws -> CodeStatsStatus {
        try AgentPayload.decode(
            CodeStatsStatus.self,
            from: await runtime.perform(operation: CodeStatsAgentOperation.status, payload: Data()))
    }
}

@Suite struct CodeStatsWorkflowTests {
    @Test func aSubmittedRunPublishesProgressAndKeepsOneFlight() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        let remote = try await harness.remote("demo")
        let workflow = await harness.workflow(
            github: WorkflowGitHub(listing: [
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
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        let blocking = try harness.fixture.blockingTool(on: "clone")
        let workflow = await harness.workflow(
            github: WorkflowGitHub(listing: [
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
        let harness = try WorkflowHarness()
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
        #expect(status.state.waitingFor == "Drive")
    }

    @Test func anInterruptedRunIsRecoveredWithoutRestarting() async throws {
        let harness = try WorkflowHarness()
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
        let harness = try WorkflowHarness()
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
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        let workflow = await harness.workflow(enabled: false)
        await #expect(throws: AgentError.self) { _ = try await workflow.start(.manual) }
        #expect(await harness.tasks.snapshots().isEmpty)
    }
}

@Suite struct CodeStatsScheduleJobTests {
    private func schedule(_ harness: WorkflowHarness, lastRunAt: Date?) throws {
        harness.settings.update { $0.schedule = .daily(hour: 3) }
        try harness.store.saveState(CodeStatsState(lastRunAt: lastRunAt))
    }

    private func job(_ workflow: CodeStatsWorkflow) async throws -> CodeStatsStatus {
        let body = try #require(
            AgentJobCatalog.collectors(store: nil, codeStats: workflow)[
                CodeStatsWorkflow.scheduleJobID])
        return try AgentPayload.decode(CodeStatsStatus.self, from: try #require(await body()))
    }

    @Test func aScheduleWithoutAFirstRunIsNotDue() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: nil)
        let status = try await job(await harness.workflow())
        #expect(!status.isRunning)
        #expect(status.nextRunAt == nil)
        #expect(await harness.tasks.snapshots().isEmpty)
    }

    @Test func aRecentRunIsNotDueYet() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-60))
        let status = try await job(await harness.workflow())
        #expect(!status.isRunning)
        #expect((status.nextRunAt ?? .distantPast) > Date())
        #expect(await harness.tasks.snapshots().isEmpty)
    }

    @Test func aDueScheduleSubmitsOneScheduledRun() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let workflow = await harness.workflow()
        let status = try await job(workflow)
        let active = try #require(status.state.active)
        #expect(active.trigger == .scheduled)
        _ = try await job(workflow)
        #expect(await harness.tasks.snapshots().count == 1)
        #expect(try await harness.finished(active.taskID) == .succeeded)
        let after = try await harness.status(workflow)
        #expect(after.state.lastRunAt == active.startedAt)
        #expect((after.nextRunAt ?? .distantPast) > active.startedAt)
    }

    @Test func aDueScheduleWaitsForTheDriveWithoutRunning() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let mounted = CodeStatsLocked(false)
        var probe = CodeStatsFileProbe.live
        probe.volume = { _ in CodeStatsVolume(name: "Archive", mountPoint: "/Volumes/Archive") }
        probe.isMounted = { _ in mounted.update { $0 } }
        let workflow = await harness.workflow(probe: probe)
        let waiting = try await job(workflow)
        #expect(!waiting.isRunning)
        #expect(waiting.state.waitingFor == "Archive")
        #expect(waiting.storage == .volumeDisconnected(volumeName: "Archive"))
        #expect(await harness.tasks.snapshots().isEmpty)

        mounted.update { $0 = true }
        let resumed = try await job(workflow)
        #expect(resumed.state.waitingFor == nil)
        let active = try #require(resumed.state.active)
        #expect(try await harness.finished(active.taskID) == .succeeded)
    }

    @Test func seriousThermalPressureDefersADueRun() async throws {
        let harness = try WorkflowHarness()
        defer { harness.fixture.remove() }
        try schedule(harness, lastRunAt: Date().addingTimeInterval(-3 * 86_400))
        let status = try await job(await harness.workflow(constrained: true))
        #expect(!status.isRunning)
        #expect(await harness.tasks.snapshots().isEmpty)
    }
}
