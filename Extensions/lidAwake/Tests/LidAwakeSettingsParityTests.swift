import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import LidAwakeExtension

@MainActor
private final class LidSettingsBridge: NSObject {
    let surface: LidAwakeSurface
    var operations: [String] = []
    var cancelled: [String] = []
    var delayed: (ExtensionEngineRequest, (NSData) -> Void)?
    var delay = false

    init(surface: LidAwakeSurface) { self.surface = surface }

    @objc(invoke:completion:)
    func invoke(_ bytes: NSData, completion: @escaping (NSData) -> Void) {
        let request = try! ExtensionEngineWire.decode(
            ExtensionEngineRequest.self, from: bytes as Data)
        operations.append(request.operation)
        if delay { delayed = (request, completion); return }
        Task {
            do {
                try request.validate()
                let payload = try await surface.execute(request.operation, payload: request.payload)
                completion(
                    try ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: true, payload: payload))
                        as NSData)
            } catch {
                completion(
                    try! ExtensionEngineWire.encode(
                        ExtensionEngineReply(token: request.token, ok: false)) as NSData)
            }
        }
    }

    @objc(cancel:) func cancel(_ token: NSString) { cancelled.append(token as String) }
}

@MainActor @Suite(.serialized)
struct LidAwakeSettingsParityTests {
    private func fixture() -> UserDefaults {
        UserDefaults(suiteName: "edith.lidAwake.settings.fixture." + UUID().uuidString)!
    }

    private func settle(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(predicate())
    }

    @Test func originalRestoreToggleRequiresConfirmationAndUsesOwningEngineSnapshot() async throws {
        let defaults = fixture()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false },
            applySystemState: { _ in
                Issue.record("Preference writes must not change system state"); return .applied
            },
            startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { false })
        let bridge = LidSettingsBridge(surface: LidAwakeSurface(worker: worker, privacy: { [:] }))
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = LidAwakeSettingsModel(client: client)
        defer { model.stop(); worker.shutdown() }
        await model.operations.refreshStatus()?.value
        let control = LidAwakeRestorationControl(operations: model.operations)
        #expect(control.binding.wrappedValue)
        control.binding.wrappedValue = false
        #expect(control.confirmingDisabled)
        #expect(LidAwakeState.restoresOnQuit(defaults))
        #expect(bridge.operations == ["lidAwake.status"])
        control.cancelDisable()
        control.confirmDisable()
        #expect(LidAwakeState.restoresOnQuit(defaults))
        control.binding.wrappedValue = false
        control.confirmDisable()
        try await settle {
            model.operations.lastSnapshot?.restoreOnQuit == false && !model.operations.applying
        }
        #expect(!LidAwakeState.restoresOnQuit(defaults))
        #expect(!control.binding.wrappedValue)
        control.binding.wrappedValue = true
        try await settle {
            model.operations.lastSnapshot?.restoreOnQuit == true && !model.operations.applying
        }
        #expect(LidAwakeState.restoresOnQuit(defaults))
        #expect(
            bridge.operations == [
                "lidAwake.status", "lidAwake.restoreOnQuit", "lidAwake.restoreOnQuit",
            ])
    }

    @Test func storedQuitPolicySurvivesWorkerStartAndCLIStillRequiresExplicitYes() async throws {
        let defaults = fixture()
        defaults.set(false, forKey: LidAwakeState.restoreOnQuitKey)
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false }, applySystemState: { _ in .applied },
            startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { false })
        defer { worker.shutdown() }
        #expect(!LidAwakeState.restoresOnQuit(defaults))
        let enabled = try await LidAwakeCLIExecution.run(
            .init(arguments: ["restore-on-quit", "true", "--json"]), worker: worker)
        #expect(enabled.exitCode == 0 && LidAwakeState.restoresOnQuit(defaults))
        let preview = try await LidAwakeCLIExecution.run(
            .init(arguments: ["restore-on-quit", "false", "--json"]), worker: worker)
        #expect(preview.exitCode == 0 && preview.stdout.contains("\"performed\": false"))
        #expect(LidAwakeState.restoresOnQuit(defaults))
        let applied = try await LidAwakeCLIExecution.run(
            .init(arguments: ["restore-on-quit", "false", "--yes", "--json"]), worker: worker)
        #expect(applied.exitCode == 0 && applied.stderr.isEmpty)
        #expect(!LidAwakeState.restoresOnQuit(defaults))
    }

    @Test func normalOwnerStopHonorsQuitPreferenceWhileDisableAlwaysRestores() async throws {
        for forceDisable in [false, true] {
            let defaults = fixture()
            var effects: [Bool] = []
            let engine = LidAwakeEngine(
                defaults: defaults, readSystemState: { false },
                applySystemState: { value in
                    effects.append(value); return .applied
                }, startServices: false)
            let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { true })
            _ = try await worker.perform(.on(.indefinite))
            _ = try await worker.perform(.setRestoreOnQuit(false))
            if forceDisable { try await worker.prepareDisable() }
            await worker.prepareToStop()
            #expect(effects == (forceDisable ? [true, false] : [true]))
            #expect(defaults.bool(forKey: LidAwakeState.activeKey) == !forceDisable)
            await #expect(throws: (any Error).self) {
                try await worker.perform(.setRestoreOnQuit(true))
            }
        }
    }

    @Test func stoppedClientCancelsReadAndRejectsLatePreferenceSnapshotAndNewWrites() async throws {
        let defaults = fixture()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false }, applySystemState: { _ in .applied },
            startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { false })
        defer { worker.shutdown() }
        let bridge = LidSettingsBridge(surface: LidAwakeSurface(worker: worker, privacy: { [:] }))
        let client = try #require(ExtensionEngineClient(bridge: bridge, presentationID: UUID()))
        let model = LidAwakeSettingsModel(client: client)
        await model.operations.refreshStatus()?.value
        bridge.delay = true
        let pending = model.operations.refreshStatus()
        try await settle { bridge.delayed != nil }
        let (request, completion) = try #require(bridge.delayed)
        model.stop()
        await pending?.value
        try await settle { bridge.cancelled.contains(request.token.uuidString) }
        defaults.set(false, forKey: LidAwakeState.restoreOnQuitKey)
        completion(
            try ExtensionEngineWire.encode(
                ExtensionEngineReply(
                    token: request.token, ok: true, payload: JSONEncoder().encode(engine.snapshot())
                )) as NSData)
        await Task.yield()
        #expect(model.operations.lastSnapshot?.restoreOnQuit == true)
        await model.operations.perform(.setRestoreOnQuit(true))?.value
        #expect(!LidAwakeState.restoresOnQuit(defaults))
        #expect(bridge.operations == ["lidAwake.status", "lidAwake.status"])
    }

    @Test func originalRowsRenderNeverVisibleAtCompactRegularZoomAndBothColorSchemes() async throws
    {
        _ = NSApplication.shared
        let shared = SharedDefaults.store
        let oldZoom = shared.object(forKey: WindowZoom.defaultsKey)
        let oldScale = UIScale.current
        defer {
            if let oldZoom {
                shared.set(oldZoom, forKey: WindowZoom.defaultsKey)
            } else {
                shared.removeObject(forKey: WindowZoom.defaultsKey)
            }
            UIScale.apply(oldScale)
        }
        let defaults = fixture()
        let engine = LidAwakeEngine(
            defaults: defaults, readSystemState: { false }, applySystemState: { _ in .applied },
            startServices: false)
        let worker = LidAwakeWorker(defaults: defaults, engine: engine, confirm: { false })
        let model = LidAwakeOperationModel { request in try await worker.perform(request) }
        await model.refreshStatus()?.value
        defer { model.cancel(); worker.shutdown() }
        for width in [420.0, 900.0] {
            for zoom in [1.0, 1.5] {
                for scheme in [ColorScheme.light, .dark] {
                    shared.set(zoom, forKey: WindowZoom.defaultsKey)
                    UIScale.apply(zoom)
                    let state = ExtensionPresentationState(
                        compact: width == 420, visible: false,
                        availableWidth: width, intrinsic: false)
                    let content = state.withContext {
                        ExtensionPageHost {
                            Form { LidAwakeRows(operations: model, chooseSession: { _ in }) }
                                .formStyle(.grouped)
                        }
                    }
                    let view = NSHostingView(rootView: content.environment(\.colorScheme, scheme))
                    view.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    view.layoutSubtreeIfNeeded()
                    #expect(view.window == nil && !view.subviews.isEmpty)
                    #expect(view.fittingSize.width.isFinite && view.fittingSize.height.isFinite)
                    #expect(!model.applying && model.errorMessage == nil)
                }
            }
        }
    }
}
