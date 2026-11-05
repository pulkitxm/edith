#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class HingeService: ExtensionService {
    private var engine: HingeEngine?
    private var observer: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]
    private var suspended = false
    private var fixture: WorkerFixtureAdmission?

    var isRunning: Bool { engine != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !suspended, !ExtensionHostRole.isInterfaceProcess, presentation == nil else {
            return false
        }
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            !context.isHostedFunctionalFixture
        else { return false }
        do {
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "hinge", context: context.input,
                roleBundle: Bundle(for: HingeService.self))
        } catch { return false }
        SharedDefaults.store.set(true, forKey: HingeState.enabledKey)
        ControlPresentationContract.applyQueued(defaults: SharedDefaults.store)
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: "hinge", prefix: "hingeHotKey",
                    defaultCode: kVK_ANSI_H,
                    defaultModifiers: controlKey | optionKey))
        }
        if engine == nil { engine = HingeEngine(fixture: fixture) }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.engine?.applySettings() }
            }
        }
        return true
    }

    func synchronize() {
        engine?.applySettings()
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("hinge.ui.") {
            guard engine != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "hinge.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "hinge.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                engine?.applySettings()
            case "hinge.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.action == "calibrate", action.value.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }
                guard fixture == nil else { throw ExtensionPeerError.unavailable }
                engine?.calibrate()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let engine else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "hinge", command: command, payload: payload,
            snapshot: { _ in
                HingeSurface.snapshot(active: HingeState.isActive())
            },
            perform: { action in
                HingeState.setActive(action == "enable")
                engine.applySettings()
                IPC.post(IPC.Name.settingsChanged)
            })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !suspended, retiredPresentations.isEmpty,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        if let stopping = retirePresentation() {
            let id = UUID()
            retiredPresentations[id] = Task { [self] in
                await stopping.value
                retiredPresentations[id] = nil
            }
        }
        presentation = ControlPresentation(client: configuration.engineClient)
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let presentation = self.presentation else { return nil }
        UIScale.install(from: SharedDefaults.store)
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    HingeRows(presentation: presentation)
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        suspended = true
        presentation?.stop()
        engine?.cancelPendingWork()
    }

    func drain() async {
        await engine?.drain()
        await presentation?.stopAndWait()
        await finishRetiredPresentations()
    }

    func teardown() async {
        await retirePresentation()?.value
        await finishRetiredPresentations()
        let stopping = engine
        engine = nil
        stopping?.shutdown()
        IPC.stopObserving(observer)
        observer = nil
        HotKeyRegistrar.shutdown()
        await stopping?.drain()
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        self.presentation = nil
        return Task { await presentation.stopAndWait() }
    }

    private func finishRetiredPresentations() async {
        while !retiredPresentations.isEmpty {
            for task in Array(retiredPresentations.values) { await task.value }
        }
    }
}

@MainActor
func makeHingeRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "hinge", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in HingeService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeHingeRuntime()).toOpaque())
        })
}
