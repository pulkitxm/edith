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
final class KeystrokeHighlightService: ExtensionService {
    private var engine: KeystrokeHighlightRuntime?
    private var observer: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]
    private var retiredEngines: [UUID: Task<Void, Never>] = [:]
    private var suspended = false
    private var fixture: WorkerFixtureAdmission?

    var isRunning: Bool { observer != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !suspended, !ExtensionHostRole.isInterfaceProcess, presentation == nil else {
            return false
        }
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            !context.isHostedFunctionalFixture
        else { return false }
        do {
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "keystrokeHighlight", context: context.input,
                roleBundle: Bundle(for: KeystrokeHighlightService.self))
        } catch { return false }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.keystrokeHighlight,
                    prefix: "keystrokeHighlightHotKey", defaultCode: kVK_ANSI_K,
                    defaultModifiers: controlKey | optionKey | cmdKey))
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.KeystrokeHighlight.enabled)
        synchronize()
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.synchronize() }
            }
        }
        return true
    }

    func synchronize() {
        guard !suspended else { return }
        if fixture == nil {
            HotKeyRegistrar.install(HotKeyCatalog.keystrokeHighlight) { [weak self] in
                let defaults = SharedDefaults.store
                defaults.set(
                    !defaults.bool(forKey: AppStorageKeys.KeystrokeHighlight.active),
                    forKey: AppStorageKeys.KeystrokeHighlight.active)
                IPC.post(IPC.Name.settingsChanged)
                self?.synchronize()
            }
        }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.KeystrokeHighlight.active) {
            if engine == nil { engine = KeystrokeHighlightRuntime(fixture: fixture) }
            engine?.syncSettings()
        } else {
            retireEngine()
        }
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("keystrokeHighlight.ui.") {
            guard observer != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "keystrokeHighlight.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "keystrokeHighlight.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                synchronize()
            case "keystrokeHighlight.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.action == "inputMonitoring", action.value.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }
                guard fixture == nil else { throw ExtensionPeerError.unavailable }
                _ = CGRequestListenEventAccess()
                synchronize()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard observer != nil else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "keystrokeHighlight", command: command,
            payload: payload,
            snapshot: { _ in
                KeystrokeHighlightSurface.snapshot(
                    active: SharedDefaults.store.bool(
                        forKey: AppStorageKeys.KeystrokeHighlight.active))
            },
            perform: { action in
                SharedDefaults.store.set(
                    action == "enable", forKey: AppStorageKeys.KeystrokeHighlight.active)
                self.synchronize()
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
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    Form { KeystrokeHighlightRows(presentation: presentation) }.settingsForm()
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func cancelPendingWork() {
        suspended = true
        presentation?.stop()
        engine?.shutdown()
    }

    func drain() async {
        await engine?.shutdownAndWait()
        await presentation?.stopAndWait()
        await finishRetirements()
    }

    func teardown() async {
        await retirePresentation()?.value
        retireEngine()
        IPC.stopObserving(observer)
        observer = nil
        HotKeyRegistrar.shutdown()
        await finishRetirements()
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        self.presentation = nil
        return Task { await presentation.stopAndWait() }
    }

    private func retireEngine() {
        guard let engine else { return }
        self.engine = nil
        engine.shutdown()
        let id = UUID()
        retiredEngines[id] = Task { [self, engine] in
            await engine.shutdownAndWait()
            retiredEngines[id] = nil
        }
    }

    private func finishRetirements() async {
        while !retiredPresentations.isEmpty || !retiredEngines.isEmpty {
            for task in Array(retiredPresentations.values) { await task.value }
            for task in Array(retiredEngines.values) { await task.value }
        }
    }
}

@MainActor
func makeKeystrokeHighlightRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "keystrokeHighlight", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in KeystrokeHighlightService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeKeystrokeHighlightRuntime()).toOpaque())
        })
}
