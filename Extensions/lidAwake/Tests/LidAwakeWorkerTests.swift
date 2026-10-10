import EdithExtensionSupport
import Foundation
import Testing
@testable import LidAwakeExtension

private final class LidAwakeJournalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    var failRestoration = false
    func record(_ value: String) { lock.lock(); events.append(value); lock.unlock() }
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

@Suite @MainActor struct LidAwakeWorkerTests {
    @Test func recoveryOnlyWorkerRetriesRestorationWithoutActivation() async throws {
        let suite = "lidAwake.recovery." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.activeKey)
        LidAwakeState.setSession(.oneHour, defaults)
        let deadline = Date(
            timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down) + 600)
        LidAwakeState.setSessionDeadline(deadline, defaults)
        var mutations: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { value in
                mutations.append(value); return .applied
            },
            startServices: false, recoveryOnly: true)
        let worker = LidAwakeWorker(
            defaults: defaults, engine: engine, recoveryOnly: true,
            confirm: {
                Issue.record("Recovery must not request activation approval"); return true
            })
        #expect(!defaults.bool(forKey: LidAwakeState.enabledKey))
        #expect(engine.remaining == nil)
        #expect(LidAwakeState.sessionDeadline(defaults) == deadline)
        #expect(mutations.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.perform(.on(.indefinite), requiresConfirmation: true)
        }
        try await worker.prepareDisable()
        #expect(mutations == [false])
        #expect(!engine.snapshot().active)
        worker.shutdown()
    }

    @Test func failedPreparationKeepsTheWorkerEnabledAndRestorable() async throws {
        let suite = "lidAwake.worker." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: LidAwakeState.activeKey)
        var outcomes: [LidAwakeOutcome] = [
            .failed("Restore permission denied"), .applied, .applied, .applied,
        ]
        var mutations: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { true },
            applySystemState: { value in
                mutations.append(value); return outcomes.removeFirst()
            }, startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { true })
        await #expect(throws: LidAwakeOperationFailure.self) { try await worker.prepareDisable() }
        #expect(defaults.bool(forKey: LidAwakeState.enabledKey))
        #expect(defaults.bool(forKey: LidAwakeState.activeKey))
        #expect(try await worker.perform(.status).lastError == "Restore permission denied")
        try await worker.prepareDisable()
        #expect(mutations == [false, false])
        #expect(!engine.snapshot().active)
        #expect(defaults.bool(forKey: LidAwakeState.enabledKey))
        worker.shutdown()
        #expect(!defaults.bool(forKey: LidAwakeState.enabledKey))
        await #expect(throws: ExtensionPeerError.self) { try await worker.perform(.status) }
    }

    @Test func originalPolicyIsJournaledBeforeEffectsAndRetainedAfterFailedRestore() async throws {
        let probe = LidAwakeJournalProbe()
        let controller = LidAwakePrivilegedController(
            read: {
                probe.record("read"); return false
            },
            apply: { value in
                probe.record("apply:\(value)")
                if !value, probe.failRestoration { throw CocoaError(.fileWriteNoPermission) }
            }, save: { probe.record("journal:\($0.map(String.init) ?? "clear")") })
        try await controller.setSleepDisabled(true)
        #expect(probe.recorded == ["read", "journal:false", "apply:true"])
        probe.failRestoration = true
        await #expect(throws: CocoaError.self) { try await controller.restore() }
        #expect(!probe.recorded.contains("journal:clear"))
        probe.failRestoration = false
        try await controller.restore()
        #expect(probe.recorded.suffix(2) == ["apply:false", "journal:clear"])
        let count = probe.recorded.count
        try await controller.restore()
        #expect(probe.recorded.count == count)
    }

    @Test func journalFailurePreventsAnyPrivilegedEffect() async throws {
        let probe = LidAwakeJournalProbe()
        let controller = LidAwakePrivilegedController(
            read: { false }, apply: { probe.record("apply:\($0)") },
            save: { _ in throw CocoaError(.fileWriteNoPermission) })
        await #expect(throws: CocoaError.self) { try await controller.setSleepDisabled(true) }
        #expect(probe.recorded.isEmpty)
    }

    @Test func hiddenActionsAndStaleActivationAreRejectedBeforeMutation() async throws {
        let suite = "lidAwake.surface." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var mutations: [Bool] = []
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { value in
                mutations.append(value); return .applied
            }, startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { true })
        defer { worker.shutdown() }
        let surface = LidAwakeSurface(worker: worker, privacy: { [:] })
        var tile = SurfaceTile(.ability("lidAwake"))
        let request = SurfaceSnapshotRequest(target: .notch, tile: tile)
        let on = SurfaceActionRequest(snapshot: request, actionID: "on")
        _ = try await surface.execute(
            "surface.perform", payload: on.encoded(providerID: "lidAwake"))
        #expect(mutations == [true])
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: on.encoded(providerID: "lidAwake"))
        }
        tile.showActions = false
        let hidden = SurfaceActionRequest(
            snapshot: .init(target: .home, tile: tile), actionID: "off")
        await #expect(throws: ExtensionPeerError.self) {
            try await surface.execute(
                "surface.perform", payload: hidden.encoded(providerID: "lidAwake"))
        }
        #expect(mutations == [true])
        tile = SurfaceTile(.actions); tile.hiddenFields = ["lidAwake"]
        let masked = try SurfaceSnapshot.decode(
            try await surface.execute(
                "surface.snapshot",
                payload: SurfaceSnapshotRequest(target: .home, tile: tile).encoded(
                    providerID: "lidAwake")), providerID: "lidAwake")
        #expect(masked.rows.isEmpty && masked.actions.isEmpty && masked.metrics.isEmpty)
        await #expect(throws: ExtensionPeerError.self) {
            try await worker.perform(.setRestoreOnQuit(false))
        }
        try await worker.prepareDisable()
    }
}
