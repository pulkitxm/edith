import Darwin
import EdithExtensionSupport
import Foundation
import Testing
@testable import LidAwakeExtension

@Suite @MainActor struct LidAwakeApplicationQuitTests {
    @Test func checkedQuitPreservesConfirmedFalseAndDrainsReplyBeforeCompletion() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.on(.indefinite))
        _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
        fixture.blockQuit = true
        let runtime = ExtensionRuntime(worker: fixture.worker)
        #expect((runtime.execute(try context()) as? NSDictionary)?["ok"] as? Bool == true)
        var completed = false
        runtime.prepareToStop { completed = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.quitReply == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(fixture.quitReply != nil && !completed)
        #expect(fixture.events == ["setSleepDisabled", "extension.lifecycle.applicationQuit"])
        fixture.quitReply?.resume(); fixture.quitReply = nil
        while !completed, ContinuousClock.now < deadline { await Task.yield() }
        #expect(completed && fixture.events.last == "shutdown")
        #expect(fixture.defaults.bool(forKey: LidAwakeState.activeKey))
        let bytes = try #require(fixture.quitPayload)
        let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(object["reason"] as? String == "applicationQuit")
        #expect(object["restoreOnQuit"] as? Bool == false)
        await stop(runtime)
        #expect(!fixture.events.contains("release"))
        try await fixture.worker.prepareDisable()
        #expect(fixture.events.last == "release")
    }

    @Test func truePreferenceRestoresAndDoesNotSendRetention() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.on(.indefinite))
        let runtime = ExtensionRuntime(worker: fixture.worker)
        #expect((runtime.execute(try context()) as? NSDictionary)?["ok"] as? Bool == true)
        await stop(runtime)
        #expect(fixture.events == ["setSleepDisabled", "release"])
        #expect(!fixture.defaults.bool(forKey: LidAwakeState.activeKey))
    }

    @Test func defaultStopStillRestoresDespiteFalsePreference() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.on(.indefinite))
        _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
        await stop(ExtensionRuntime(worker: fixture.worker))
        #expect(fixture.events == ["setSleepDisabled", "release"])
    }

    @Test func failedOrCancelledQuitFallsBackToRestoration() async throws {
        for cancelled in [false, true] {
            let fixture = try Fixture()
            defer { fixture.clean() }
            _ = try await fixture.worker.perform(.on(.indefinite))
            _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
            fixture.quitError = cancelled ? CancellationError() : CocoaError(.fileReadUnknown)
            let runtime = ExtensionRuntime(worker: fixture.worker)
            _ = runtime.execute(try context())
            await stop(runtime)
            #expect(
                fixture.events == [
                    "setSleepDisabled", "extension.lifecycle.applicationQuit", "release",
                ])
            #expect(!fixture.defaults.bool(forKey: LidAwakeState.activeKey))
        }
    }

    @Test func mutationDrainReadsTheLatestConfirmedPreference() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
        fixture.blockMutation = true
        let activation = Task { try await fixture.worker.perform(.on(.indefinite)) }
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.mutationReply == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(fixture.mutationReply != nil)
        let runtime = ExtensionRuntime(worker: fixture.worker)
        _ = runtime.execute(try context())
        var completed = false
        runtime.prepareToStop { completed = true }
        await Task.yield()
        #expect(!completed)
        _ = try await fixture.worker.perform(.setRestoreOnQuit(true))
        fixture.mutationReply?.resume(); fixture.mutationReply = nil
        _ = try await activation.value
        while !completed, ContinuousClock.now < deadline { await Task.yield() }
        #expect(completed && fixture.events == ["setSleepDisabled", "release"])
    }

    @Test func failedRestorationKeepsCompletionPendingUntilRetryAcknowledges() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.on(.indefinite))
        _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
        fixture.quitError = CocoaError(.fileReadUnknown)
        fixture.failFirstRelease = true
        fixture.blockRelease = true
        let runtime = ExtensionRuntime(worker: fixture.worker)
        _ = runtime.execute(try context())
        var completed = false
        runtime.prepareToStop { completed = true }
        let deadline = ContinuousClock.now + .seconds(2)
        while fixture.releaseReply == nil, ContinuousClock.now < deadline { await Task.yield() }
        #expect(fixture.releaseReply != nil && !completed)
        fixture.releaseReply?.resume(); fixture.releaseReply = nil
        while !completed, ContinuousClock.now < deadline { await Task.yield() }
        #expect(completed && fixture.events.suffix(2) == ["release", "release"])
        #expect(!fixture.defaults.bool(forKey: LidAwakeState.activeKey))
    }

    @Test func idleQuitDoesNotAcquireOrInvokePrivilegedLease() async throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
        let runtime = ExtensionRuntime(worker: fixture.worker)
        _ = runtime.execute(try context())
        await stop(runtime)
        #expect(!fixture.events.contains("extension.lifecycle.applicationQuit"))
        #expect(!fixture.events.contains("setSleepDisabled"))
    }

    @Test func savedActiveStateIsRetainedWithoutAcquisitionOnQuitButDisableAcquiresForRestore()
        async throws
    {
        for quit in [true, false] {
            let fixture = try Fixture(savedActive: true)
            defer { fixture.clean() }
            _ = try await fixture.worker.perform(.setRestoreOnQuit(false))
            if quit {
                let runtime = ExtensionRuntime(worker: fixture.worker)
                _ = runtime.execute(try context())
                await stop(runtime)
                #expect(fixture.events.isEmpty)
            } else {
                try await fixture.worker.prepareDisable()
                #expect(fixture.events == ["status", "release"])
            }
        }
    }

    @Test(arguments: ["reason", "generation", "parent", "extra"])
    func foreignOrStaleContextIsRejected(field: String) throws {
        let fixture = try Fixture()
        defer { fixture.clean() }
        let input = try context().mutableCopy() as! NSMutableDictionary
        switch field {
        case "reason": input["reason"] = "disable"
        case "generation": input["hostGeneration"] = "0.0"
        case "parent": input["hostPID"] = getpid()
        default: input["skipRestoration"] = true
        }
        let runtime = ExtensionRuntime(worker: fixture.worker)
        #expect((runtime.execute(input) as? NSDictionary)?["ok"] as? Bool == false)
        #expect(fixture.events.isEmpty)
    }

    private func context() throws -> NSDictionary {
        let host = try #require(ExtensionProcessIdentity.read(getppid()))
        return [
            "operation": "prepareApplicationQuit", "reason": "applicationQuit",
            "hostPID": host.pid, "hostGeneration": host.generation,
        ]
    }

    private func stop(_ runtime: ExtensionRuntime) async {
        await withCheckedContinuation { continuation in
            runtime.prepareToStop { continuation.resume() }
        }
    }

    @MainActor private final class Fixture {
        let suite = "lidAwake.applicationQuit." + UUID().uuidString
        let defaults: UserDefaults
        var worker: LidAwakeWorker!
        var events: [String] = []
        var blockQuit = false
        var quitReply: CheckedContinuation<Void, Never>?
        var quitPayload: Data?
        var quitError: (any Error)?
        var blockMutation = false
        var mutationReply: CheckedContinuation<Void, Never>?
        var failFirstRelease = false
        var blockRelease = false
        var releaseReply: CheckedContinuation<Void, Never>?

        init(savedActive: Bool = false) throws {
            defaults = try #require(UserDefaults(suiteName: suite))
            let client = LidAwakePrivilegedClient(
                state: { .enabled },
                invoke: { [self] command, payload in
                    events.append(command)
                    if command == "setSleepDisabled", blockMutation {
                        await withCheckedContinuation { mutationReply = $0 }
                    }
                    if command == "extension.lifecycle.applicationQuit" {
                        quitPayload = payload
                        if let quitError { throw quitError }
                        if blockQuit { await withCheckedContinuation { quitReply = $0 } }
                    }
                    return Data()
                },
                release: { [self] in
                    events.append("release")
                    if failFirstRelease {
                        failFirstRelease = false; throw CocoaError(.fileWriteNoPermission)
                    }
                    if blockRelease { await withCheckedContinuation { releaseReply = $0 } }
                },
                shutdown: { [self] in events.append("shutdown") })
            let engine = LidAwakeEngine(
                defaults: defaults, readSystemState: { savedActive }, applySystemState: nil,
                startServices: false, privilegedClient: client)
            worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { true })
        }
        func clean() { defaults.removePersistentDomain(forName: suite) }
    }
}
