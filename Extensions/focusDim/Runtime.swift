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
final class FocusDimService: ExtensionService {
    private var engine: FocusDimEngine?
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
                extensionID: "focusDim", context: context.input,
                roleBundle: Bundle(for: FocusDimService.self))
        } catch { return false }
        SharedDefaults.store.set(true, forKey: FocusDimState.enabledKey)
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: "focusDim", prefix: "focusDimHotKey",
                    defaultCode: kVK_ANSI_F,
                    defaultModifiers: cmdKey | optionKey))
        }
        if engine == nil { engine = FocusDimEngine(fixture: fixture) }
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
        if command.hasPrefix("focusDim.ui.") {
            guard engine != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "focusDim.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "focusDim.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                engine?.applySettings()
            case "focusDim.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.action == "screenRecording", action.value.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }
                guard fixture == nil else { throw ExtensionPeerError.unavailable }
                _ = CGRequestScreenCaptureAccess()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let engine else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "focusDim", command: command, payload: payload,
            snapshot: { _ in
                FocusDimSurface.snapshot(active: FocusDimState.isActive())
            },
            perform: { action in
                FocusDimState.setActive(action == "enable")
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
                    FocusDimSettings(presentation: presentation)
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
func makeFocusDimRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "focusDim", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in FocusDimService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeFocusDimRuntime()).toOpaque())
        })
}
