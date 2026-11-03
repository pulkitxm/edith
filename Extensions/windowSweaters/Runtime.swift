#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class WindowSweatersService: ExtensionService {
    private var engine: SweaterEngine?
    private var observer: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var draining = false
    private var fixture: WorkerFixtureAdmission?

    var isRunning: Bool { engine != nil }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !draining, !ExtensionHostRole.isInterfaceProcess, presentation == nil else {
            return false
        }
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            !context.isHostedFunctionalFixture
        else { return false }
        do {
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "windowSweaters", context: context.input,
                roleBundle: Bundle(for: WindowSweatersService.self))
        } catch { return false }
        SharedDefaults.store.set(true, forKey: SweaterState.enabledKey)
        if engine == nil { engine = SweaterEngine(fixture: fixture) }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.engine?.applySettings() }
            }
        }
        return true
    }

    func synchronize() {
        guard !draining else { return }
        engine?.applySettings()
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("windowSweaters.ui.") {
            guard engine != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "windowSweaters.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "windowSweaters.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                engine?.applySettings()
            case "windowSweaters.ui.action":
                _ = try JSONDecoder().decode(ControlPresentationAction.self, from: payload)
                throw ExtensionPeerError.invalidRequest
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let engine else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "windowSweaters", command: command, payload: payload,
            snapshot: { _ in
                WindowSweatersSurface.snapshot(active: SweaterState.isActive())
            },
            perform: { action in
                SweaterState.setActive(action == "enable")
                engine.applySettings()
                IPC.post(IPC.Name.settingsChanged)
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
                    Form { WindowSweatersRows(presentation: presentation) }.edithForm()
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
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
func makeWindowSweatersRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "windowSweaters", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in WindowSweatersService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeWindowSweatersRuntime()).toOpaque())
        })
}
