#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class PresenterExtensionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var service: PresenterDetector?
    private var state: PresenterState?
    private var observer: NSObjectProtocol?
    private var pauseObserver: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var fixture: WorkerFixtureAdmission?

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { state != nil }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        if command == "presenter.cli.catalog" {
            return try PresenterCLIExecution.catalog(payload)
        }
        if command == "presenter.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await PresenterCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            guard state != nil else { throw ExtensionPeerError.unavailable }
            let reply = try await PresenterCLIExecution.run(
                request, defaults: SharedDefaults.store
            ) { [self] operation in
                if operation == .stop { self.service?.pauseUntilShareEnds() }
                let snapshot = PresenterRuntimeOperationExecution.perform(
                    operation, post: { _ in })
                applyState()
                return snapshot
            }
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("presenter.ui.") {
            guard state != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "presenter.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "presenter.ui.update":
                let wasManual = defaults.bool(forKey: AppStorageKeys.Presenter.mode)
                try ControlPresentationContract.update(payload, defaults: defaults)
                if wasManual && !defaults.bool(forKey: AppStorageKeys.Presenter.mode) {
                    self.service?.pauseUntilShareEnds()
                }
                applyState()
            case "presenter.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.value.isEmpty else { throw ExtensionPeerError.invalidRequest }
                switch action.action {
                case "screenRecording":
                    guard fixture == nil else { throw ExtensionPeerError.unavailable }
                    guard
                        let url = URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                        )
                    else { throw ExtensionPeerError.invalidRequest }
                    NSWorkspace.shared.open(url)
                case "start": _ = PresenterRuntimeOperationExecution.perform(.start)
                case "stop":
                    self.service?.pauseUntilShareEnds()
                    _ = PresenterRuntimeOperationExecution.perform(.stop)
                default: throw ExtensionPeerError.invalidRequest
                }
                applyState()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults,
                state: ControlPresentationState(
                    jevConfigured: PresenterJevClient.configured() != nil))
        }
        guard state != nil else { throw ExtensionPeerError.unavailable }
        if command == "surface.snapshot" || command == "surface.perform" {
            return try await SurfaceCommandService.execute(
                providerID: "presenter", command: command, payload: payload,
                snapshot: { _ in
                    PresenterSurface.snapshot(PresenterRuntimeOperationExecution.status())
                },
                perform: { [self] action in
                    if action == "stop" { self.service?.pauseUntilShareEnds() }
                    _ = PresenterRuntimeOperationExecution.perform(
                        action == "stop" ? .stop : .start)
                    applyState()
                })
        }
        switch command {
        case "presenter.start": _ = PresenterRuntimeOperationExecution.perform(.start)
        case "presenter.stop": _ = PresenterRuntimeOperationExecution.perform(.stop)
        case "presenter.status": break
        default:
            throw ExtensionPeerError.rejected("Presenter does not support this command.")
        }
        applyState()
        let snapshot = PresenterRuntimeOperationExecution.status()
        return try JSONSerialization.data(withJSONObject: [
            "enabled": snapshot.enabled, "manual": snapshot.manual,
            "autoActive": snapshot.autoActive, "active": snapshot.active,
            "autoReason": snapshot.autoReason ?? "",
        ])

    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        do {
            guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                !context.isHostedFunctionalFixture
            else { throw WorkerFixtureError.invalid }
            fixture = try WorkerFixtureAdmission.current(
                extensionID: "presenter", context: input,
                roleBundle: Bundle(for: PresenterExtensionService.self))
            return startOwned()
        } catch { return false }
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !(runtime.isSuspended || runtime.isStopping) else { return false }
        applyState()
        return true
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard presentationStops.isEmpty,
            configuration.defaultsSuite
                == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        _ = retirePresentation()
        presentation = ControlPresentation(client: configuration.engineClient)
        return true
    }

    func view(for presentationID: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard let presentation else { return nil }
        if let controller = PresenterSidebarScene.controller(
            context.input, presentation: presentation)
        {
            return controller
        }
        return NSHostingController(
            rootView: ExtensionPageHost {
                ControlSettingsHost(presentation: presentation) {
                    Form { PresenterRows(presentation: presentation) }.settingsForm()
                }
            })
    }

    func stopUI(for presentationID: UUID?) -> [Task<Void, Never>] {
        retirePresentation().map { [$0] } ?? []
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        switch operation {
        case "prepareToStop":
            runtime.prepareToStop {}
        case "pauseUntilShareEnds":
            service?.pauseUntilShareEnds()
        default:
            return nil
        }
        return ["ok": true] as NSDictionary
    }

    func cancelPendingWork() {
        presentation?.stop()
        service?.suspendWork()
    }

    func drain() async {
        await service?.suspendAndWait()
        await finishPresentations(presentation)
    }

    func teardown() async {
        let retiring = retirePresentation()
        let detector = service
        service = nil
        detector?.shutdown()
        state?.shutdown()
        state = nil
        IPC.stopObserving(observer)
        IPC.stopObserving(pauseObserver)
        observer = nil
        pauseObserver = nil
        HotKeyRegistrar.shutdown()
        await retiring?.value
        await finishPresentations(nil)
    }

    private func applyState() {
        guard !(runtime.isSuspended || runtime.isStopping), state != nil else { return }
        if fixture == nil {
            HotKeyRegistrar.install(HotKeyCatalog.presenter) { [weak self] in
                let operation: PresenterRuntimeOperation =
                    SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.mode)
                    ? .stop : .start
                _ = PresenterRuntimeOperationExecution.perform(operation)
                self?.applyState()
            }
        }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.autoEnabled) {
            if service == nil { service = PresenterDetector(fixture: fixture) }
            service?.applySettings()
        } else {
            service?.shutdown()
            service = nil
            SharedDefaults.store.set(false, forKey: AppStorageKeys.Presenter.autoActive)
        }
        state?.refresh()
    }

    private func startOwned() -> Bool {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil else { return false }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Presenter.enabled)
        SharedDefaults.store.set(false, forKey: AppStorageKeys.Presenter.autoActive)
        if state == nil { state = PresenterState() }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.presenter, prefix: "presenterHotKey",
                    defaultCode: kVK_ANSI_P, defaultModifiers: shiftKey | optionKey | cmdKey))
        }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.applyState() }
            }
            pauseObserver = IPC.observe(IPC.Name.presenterPauseAuto) { [weak self] in
                MainActor.assumeIsolated { self?.service?.pauseUntilShareEnds() }
            }
        }
        applyState()
        return true
    }

    private func retirePresentation() -> Task<Void, Never>? {
        guard let presentation else { return nil }
        presentation.stop()
        let id = UUID()
        let task = Task { [self, presentation] in
            defer { presentationStops[id] = nil }
            await presentation.stopAndWait()
        }
        presentationStops[id] = task
        self.presentation = nil
        return task
    }

    private func finishPresentations(_ presentation: ControlPresentation?) async {
        await presentation?.stopAndWait()
        while !presentationStops.isEmpty {
            let pending = Array(presentationStops.values)
            for task in pending { await task.value }
        }
    }
}

@MainActor
func makePresenterRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "presenter", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { PresenterExtensionService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makePresenterRuntime()).toOpaque())
        })
}
