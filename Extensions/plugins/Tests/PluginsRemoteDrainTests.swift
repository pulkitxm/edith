import Foundation
import Testing
@testable import PluginsExtension

@Suite @MainActor struct PluginsRemoteDrainTests {
    @Test(arguments: [false, true])
    func stoppingJoinsDirectRemoteDiscoveryAndPresentation(present: Bool) async throws {
        var suspended: CheckedContinuation<Void, Never>?
        var cancelled = false
        var starts = 0
        let suite = "com.pulkit.edith.tests.worker-" + UUID().uuidString + ".extensions.plugins"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let bridge = PluginsUIBridge(invoke: { _, _ in
            starts += 1
            await withCheckedContinuation { suspended = $0 }
            cancelled = Task.isCancelled
            throw CancellationError()
        })
        let model = SkillsModel(remote: bridge, defaults: defaults)
        let caller = Task {
            if present {
                await model.present(EdithSkillLibrary.skills[0])
            } else {
                await model.discoverAgents()
            }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while suspended == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try #require(suspended)
        var drained = false
        let shutdown = Task {
            await model.shutdown(); drained = true
        }
        while !model.isStopped, ContinuousClock.now < deadline { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        #expect(model.isStopped)
        #expect(!drained)
        continuation.resume()
        await shutdown.value
        await caller.value
        #expect(cancelled)
        #expect(model.presentedSkill == nil)
        #expect(model.installationError == nil)
        model.setSelected("synthetic-agent", enabled: true)
        await model.discoverAgents()
        model.beginRemoteInstall()
        #expect(model.selectedAgentIDs.isEmpty)
        #expect(!model.remoteInstallIsPending)
        #expect(starts == 1)
    }
    @Test func installationLogsCancelAndJoinTheActualSuspendedCallback() async throws {
        var pending: CheckedContinuation<Void, Never>?
        var cancelled = false
        var starts = 0
        let logs = SkillInstallationLogs { _ in
            starts += 1
            await withCheckedContinuation { pending = $0 }
            cancelled = Task.isCancelled
        }
        logs.append("first")
        let deadline = ContinuousClock.now + .seconds(5)
        while pending == nil, ContinuousClock.now < deadline { await Task.yield() }
        let continuation = try #require(pending)
        logs.append("queued")
        logs.stop()
        logs.append("closed")
        var drained = false
        let drain = Task {
            await logs.finishAndWait(); drained = true
        }
        for _ in 0..<20 { await Task.yield() }
        #expect(!drained)
        continuation.resume()
        await drain.value
        #expect(cancelled && drained && starts == 1)
    }

    @Test func installationLogsFlushBeforeReturningAndCloseAdmission() async {
        var lines: [String] = []
        let logs = SkillInstallationLogs { lines.append($0) }
        logs.append("first"); logs.append("last")
        await logs.finishAndWait()
        logs.append("closed")
        await logs.finishAndWait()
        #expect(lines == ["first", "last"])
        var unexpected = false
        let stopped = SkillInstallationLogs { _ in unexpected = true }
        stopped.append("pending")
        stopped.stop()
        await stopped.finishAndWait()
        #expect(!unexpected)
    }
}
