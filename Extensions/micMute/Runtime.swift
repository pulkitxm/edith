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
final class MicMuteService: ExtensionService {
    private var engine: MicMuteEngine?
    private var observer: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var draining = false
    private var fixture: WorkerFixtureAdmission?

    var isRunning: Bool { observer != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !draining, !ExtensionHostRole.isInterfaceProcess, presentation == nil else {
            return false
        }
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            !context.isHostedFunctionalFixture
        else { return false }
        do {
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "micMute", context: context.input,
                roleBundle: Bundle(for: MicMuteService.self))
        } catch { return false }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.micMute, prefix: "micHotKey",
                    defaultCode: kVK_ANSI_M, defaultModifiers: cmdKey | shiftKey))
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Mic.muteEnabled)
        if engine == nil { engine = MicMuteEngine(fixture: fixture) }
        engine?.syncSettings()
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.engine?.syncSettings() }
            }
        }
        return true
    }

    func synchronize() {
        guard !draining else { return }
        engine?.syncSettings()
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("micMute.ui.") {
            guard engine != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "micMute.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "micMute.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                engine?.syncSettings()
            case "micMute.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.value.isEmpty, let engine else {
                    throw ExtensionPeerError.invalidRequest
                }
                switch action.action {
                case "mute": engine.setMuted(true)
                case "unmute": engine.setMuted(false)
                case "retry": engine.retry()
                default: throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults,
                state: ControlPresentationState(
                    muted: engine?.muted ?? false, error: engine?.error))
        }
        guard let engine else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "micMute", command: command, payload: payload,
            snapshot: { _ in
                MicMuteSurface.snapshot(muted: engine.muted)
            },
            perform: { action in
                guard action == "toggle" else { throw ExtensionPeerError.invalidRequest }
                engine.toggle()
            })
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !draining, presentationStops.isEmpty,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        if let stopping = retirePresentation() {
            let id = UUID()
            presentationStops[id] = Task { [self] in
                await stopping.value
                presentationStops[id] = nil
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
                    Form { MicMuteRows(presentation: presentation) }.settingsForm()
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "toggle" else { return nil }
        engine?.toggle()
        return ["ok": true] as NSDictionary
    }

    func cancelPendingWork() {
        draining = true
        presentation?.stop()
        engine?.suspendWork()
    }

    func drain() async {
        await engine?.suspendAndWait()
        await presentation?.stopAndWait()
        await finishPresentationStops()
    }

    func teardown() async {
        await retirePresentation()?.value
        await finishPresentationStops()
        engine?.shutdown()
        engine = nil
        IPC.stopObserving(observer)
        observer = nil
        HotKeyRegistrar.shutdown()
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        self.presentation = nil
        return Task { await presentation.stopAndWait() }
    }

    private func finishPresentationStops() async {
        while !presentationStops.isEmpty {
            for task in Array(presentationStops.values) { await task.value }
        }
    }
}

@MainActor
func makeMicMuteRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "micMute", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in MicMuteService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeMicMuteRuntime()).toOpaque())
        })
}
