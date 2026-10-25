@testable import CodeStatsExtension
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Testing

private actor CodeStatsGitGate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        open = true
        for continuation in waiting { continuation.resume() }
        waiting = []
    }
}

private struct CodeStatsCancelledGitHub: CodeStatsGitHubClient {
    let failure: @Sendable () -> Error

    func profiles() async throws -> [CodeStatsProfile] { throw failure() }
    func emails(for profile: CodeStatsProfile) async -> [String] { [] }
    func repositories(for profile: CodeStatsProfile) async throws -> [CodeStatsRemoteRepository] {
        throw failure()
    }
    func token(for profile: CodeStatsProfile) async -> String? { nil }
}

@MainActor @Suite struct CodeStatsInstantPageTests {
    private let defaultsName = "test.edith.code-stats-instant.\(UUID().uuidString)"
    private let emptyPayload = Data("{}".utf8)

    private func blockedWorkflow(
        gate: CodeStatsGitGate, saved: CodeStatsStatus?
    ) throws -> (CodeStatsWorkflow, CodeStatsGitFixture) {
        let fixture = try CodeStatsGitFixture()
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        if let saved { try store.saveStatus(saved) }
        let tool = fixture.tool
        let environment = CodeStatsEnvironment(
            settings: { CodeStatsSettings(folder: "/Volumes/Archive/GitHub") },
            saveIdentity: { _ in }, isEnabled: { true },
            git: {
                await gate.wait()
                return tool
            }, github: { nil }, store: store)
        return (CodeStatsWorkflow(environment: environment), fixture)
    }

    @Test func cachedStatusAnswersFromTheSavedSnapshotWhileTheProbeIsBlocked() async throws {
        let gate = CodeStatsGitGate()
        let saved = CodeStatsPageFixture.status(
            storage: .ready(freeBytes: 7), reportedAt: Date(), gitAvailable: true,
            githubAvailable: true)
        let (workflow, fixture) = try blockedWorkflow(gate: gate, saved: saved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let cached = try #require(await workflow.cachedStatus())
        #expect(cached.gitAvailable && cached.githubAvailable)
        #expect(cached.storage == .ready(freeBytes: 7))
        await gate.release()
        await workflow.shutdown()
    }

    @Test func theUIStatusRequestRepliesFromMemoryWhileTheProbeIsBlocked() async throws {
        let gate = CodeStatsGitGate()
        let saved = CodeStatsPageFixture.status(reportedAt: Date())
        let (workflow, fixture) = try blockedWorkflow(gate: gate, saved: saved)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let reply = try await CodeStatsUIBridge.execute(
            "codeStats.ui.status", payload: emptyPayload, workflow: workflow)
        let status = try JSONDecoder().decode(CodeStatsStatus.self, from: reply)
        #expect(status.gitAvailable && status.storage == saved.storage)
        await gate.release()
        await workflow.shutdown()
    }

    @Test func withoutASavedSnapshotThereIsNoCachedStatus() async throws {
        let gate = CodeStatsGitGate()
        let (workflow, fixture) = try blockedWorkflow(gate: gate, saved: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(await workflow.cachedStatus() == nil)
        await gate.release()
        await workflow.shutdown()
    }

    @Test func aProbeSavesTheSnapshotForTheNextStart() async throws {
        let gate = CodeStatsGitGate()
        await gate.release()
        let (workflow, fixture) = try blockedWorkflow(gate: gate, saved: nil)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let probed = await workflow.status()
        #expect(probed.gitAvailable)
        let store = CodeStatsStore(root: fixture.root.appendingPathComponent("state"))
        #expect(store.loadStatus()?.gitAvailable == true)
        await workflow.shutdown()
    }

    @Test func aCancelledGitHubLookupNeverBecomesAFailureMessage() async throws {
        for failure in [
            CancellationError() as Error, URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ] {
            let fixture = try CodeStatsGitFixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let github = CodeStatsCancelledGitHub(failure: { failure })
            let environment = CodeStatsEnvironment(
                settings: { CodeStatsSettings(folder: nil) }, saveIdentity: { _ in },
                isEnabled: { true }, git: { nil }, github: { github },
                store: CodeStatsStore(root: fixture.root.appendingPathComponent("state")))
            let workflow = CodeStatsWorkflow(environment: environment)
            let lookup = await workflow.profile()
            if case .failed? = lookup.issue { Issue.record("cancellation surfaced as a failure") }
            #expect(lookup.profiles.isEmpty)
            await workflow.shutdown()
        }
    }

    @Test func aCancelledPageRequestLeavesNoVisibleError() async {
        for failure in [
            CancellationError() as Error, URLError(.cancelled),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled),
        ] {
            let agent = CodeStatsFakeAgent(status: CodeStatsPageFixture.status())
            var service = agent.service
            service.profile = { throw failure }
            service.authors = { throw failure }
            service.start = { throw failure }
            service.cancel = { throw failure }
            let model = CodeStatsModel(
                service: service, defaults: UserDefaults(suiteName: defaultsName)!)
            await model.refresh()
            await model.loadProfile()
            await model.discoverAuthors()
            await model.start()
            await model.cancel()
            #expect(model.profileLookup == nil && model.errorMessage == nil)

            service.status = { throw failure }
            let failing = CodeStatsModel(
                service: service, defaults: UserDefaults(suiteName: defaultsName)!)
            await failing.loadStatus()
            #expect(failing.loadingError == nil && failing.loadingState != .error)
        }
    }

    @Test func aSecondVisitStartsWithTheLastReportAndSkipsAnUnchangedReload() async {
        let memory = CodeStatsModelMemory()
        let reportedAt = Date()
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: reportedAt),
            reports: [.days(90): CodeStatsPageFixture.report()])
        let defaults = UserDefaults(suiteName: defaultsName)!
        let first = CodeStatsModel(
            service: agent.service, defaults: defaults, memory: memory)
        #expect(first.loadingState != .content)
        await first.refresh()
        #expect(first.loadingState == .content && first.report != nil)

        let second = CodeStatsModel(
            service: agent.service, defaults: defaults, memory: memory)
        #expect(second.report != nil && second.loadingState == .content)
        #expect(second.phase == .content)
        let before = agent.recorded.filter { $0.hasPrefix("report") }.count
        await second.refresh()
        #expect(agent.recorded.filter { $0.hasPrefix("report") }.count == before)
        #expect(second.report != nil)
    }

    @Test func aNewReportReloadsEvenWhenTheLastVisitWasSeeded() async {
        let memory = CodeStatsModelMemory()
        let agent = CodeStatsFakeAgent(
            status: CodeStatsPageFixture.status(reportedAt: Date(timeIntervalSince1970: 1)),
            reports: [.days(90): CodeStatsPageFixture.report()])
        let defaults = UserDefaults(suiteName: defaultsName)!
        let first = CodeStatsModel(service: agent.service, defaults: defaults, memory: memory)
        await first.refresh()
        agent.status = CodeStatsPageFixture.status(
            reportedAt: Date(timeIntervalSince1970: 2), revision: 5)
        let second = CodeStatsModel(service: agent.service, defaults: defaults, memory: memory)
        let before = agent.recorded.filter { $0.hasPrefix("report") }.count
        await second.refresh()
        #expect(agent.recorded.filter { $0.hasPrefix("report") }.count == before + 1)
    }
}
