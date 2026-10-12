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
@objc(EdithPresenterExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var service: PresenterDetector?
    private var state: PresenterState?
    private var observer: NSObjectProtocol?
    private var pauseObserver: NSObjectProtocol?
    private var presentation: ControlPresentation?
    private var presentationStops: [UUID: Task<Void, Never>] = [:]
    private var draining = false

    private var fixture: WorkerFixtureAdmission?
    #if EDITH_FUNCTIONAL_FIXTURE
    private var engineAdmission: WorkerFixtureEngineAdmission?
    #endif
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            return try await self.withFixtureRequest(
                command, payload: payload, token: request["token"] as? String
            ) { [weak self] in
                if command == "presenter.cli.catalog" {
                    return try PresenterCLIExecution.catalog(payload)
                }
                if command == "presenter.cli" {
                    let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                    if let help = try await PresenterCLIExecution.help(request) {
                        return try JSONEncoder().encode(help)
                    }
                    guard let self, self.state != nil else { throw ExtensionPeerError.unavailable }
                    let reply = try await PresenterCLIExecution.run(
                        request, defaults: SharedDefaults.store
                    ) { operation in
                        if operation == .stop { self.service?.pauseUntilShareEnds() }
                        let snapshot = PresenterRuntimeOperationExecution.perform(
                            operation, post: { _ in })
                        self.synchronize()
                        return snapshot
                    }
                    return try JSONEncoder().encode(reply)
                }
                if command.hasPrefix("presenter.ui.") {
                    guard let self, self.state != nil else { throw ExtensionPeerError.unavailable }
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
                        self.synchronize()
                    case "presenter.ui.action":
                        let action = try JSONDecoder().decode(
                            ControlPresentationAction.self, from: payload)
                        guard action.value.isEmpty else { throw ExtensionPeerError.invalidRequest }
                        switch action.action {
                        case "screenRecording":
                            guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
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
                        self.synchronize()
                    default: throw ExtensionPeerError.invalidRequest
                    }
                    return try ControlPresentationContract.snapshot(
                        defaults: defaults,
                        state: ControlPresentationState(
                            jevConfigured: PresenterJevClient.configured() != nil))
                }
                guard let self, self.state != nil else { throw ExtensionPeerError.unavailable }
                if command == "surface.snapshot" || command == "surface.perform" {
                    return try await SurfaceCommandService.execute(
                        providerID: "presenter", command: command, payload: payload,
                        snapshot: { _ in
                            PresenterSurface.snapshot(PresenterRuntimeOperationExecution.status())
                        },
                        perform: { action in
                            if action == "stop" { self.service?.pauseUntilShareEnds() }
                            _ = PresenterRuntimeOperationExecution.perform(
                                action == "stop" ? .stop : .start)
                            self.synchronize()
                        })
                }
                switch command {
                case "presenter.start": _ = PresenterRuntimeOperationExecution.perform(.start)
                case "presenter.stop": _ = PresenterRuntimeOperationExecution.perform(.stop)
                case "presenter.status": break
                default:
                    throw ExtensionPeerError.rejected("Presenter does not support this command.")
                }
                self.synchronize()
                let snapshot = PresenterRuntimeOperationExecution.status()
                return try JSONSerialization.data(withJSONObject: [
                    "enabled": snapshot.enabled, "manual": snapshot.manual,
                    "autoActive": snapshot.autoActive, "active": snapshot.active,
                    "autoReason": snapshot.autoReason ?? "",
                ])
            }
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        _ = commands.suspend()
        draining = true
        let presentation = presentation
        presentation?.stop()
        let service = service
        service?.suspendWork()
        Task { [self, service, presentation] in
            _ = await commands.suspendAndWait()
            await service?.suspendAndWait()
            await finishPresentations(presentation)
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        draining = true
        retirePresentation()
        let service = service
        service?.suspendWork()
        commands.shutdown()
        Task { [self, service] in
            await commands.shutdownAndWait()
            await service?.suspendAndWait()
            await finishPresentations(nil)
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "presenter", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !draining, presentationStops.isEmpty else { return ["ok": false] as NSDictionary }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "presenter",
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            retirePresentation()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            retirePresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard !draining else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            do {
                let admission = try WorkerFixtureEngineAdmission.current(
                    extensionID: "presenter", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .helper)
                engineAdmission = admission
                if let admission {
                    return try admission.withPlatformFixture(
                        extensionID: "presenter", expectedRole: .helper
                    ) { namespace in
                        fixture = namespace
                        return startOwned(input)
                    }
                }
                fixture = nil
                return startOwned(input)
            } catch { return ["ok": false] as NSDictionary }
            #else
            do {
                guard ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                    input["hostedFunctionalFixture"] == nil
                else { throw WorkerFixtureError.invalid }
                fixture = try WorkerFixtureAdmission.current(
                    extensionID: "presenter", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                return startOwned(input)
            } catch { return ["ok": false] as NSDictionary }
            #endif
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            if let controller = PresenterSidebarScene.controller(input, presentation: presentation)
            {
                return controller
            }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Presenter")
                        } content: {
                            Form { PresenterRows(presentation: presentation) }.formStyle(.grouped)
                        }
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !draining else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let engineAdmission {
                do { try engineAdmission.requireCurrent() } catch {
                    return ["ok": false] as NSDictionary
                }
            }
            #endif
            synchronize()
        case "stop":
            retirePresentation()
            commands.shutdown()
            service?.shutdown()
            service = nil
            state?.shutdown()
            state = nil
            IPC.stopObserving(observer)
            IPC.stopObserving(pauseObserver)
            observer = nil
            pauseObserver = nil
            HotKeyRegistrar.shutdown()
        case "pauseUntilShareEnds": service?.pauseUntilShareEnds()
        case "status": return ["ok": true, "running": state != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func synchronize() {
        guard !draining, state != nil else { return }
        #if EDITH_FUNCTIONAL_FIXTURE
        if let engineAdmission {
            do { try engineAdmission.requireCurrent() } catch { return }
        }
        #endif
        if fixture == nil {
            HotKeyRegistrar.install(HotKeyCatalog.presenter) { [weak self] in
                let operation: PresenterRuntimeOperation =
                    SharedDefaults.store.bool(forKey: AppStorageKeys.Presenter.mode)
                    ? .stop : .start
                _ = PresenterRuntimeOperationExecution.perform(operation)
                self?.synchronize()
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

    private func startOwned(_ input: NSDictionary) -> NSObject {
        guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
        else { return ["ok": false] as NSDictionary }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return ["ok": false] as NSDictionary }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.Presenter.enabled)
        SharedDefaults.store.set(false, forKey: AppStorageKeys.Presenter.autoActive)
        if state == nil { state = PresenterState() }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.presenter, carbonID: 5, prefix: "presenterHotKey",
                    defaultCode: kVK_ANSI_P, defaultModifiers: shiftKey | optionKey | cmdKey))
        }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.synchronize() }
            }
            pauseObserver = IPC.observe(IPC.Name.presenterPauseAuto) { [weak self] in
                MainActor.assumeIsolated { self?.service?.pauseUntilShareEnds() }
            }
        }
        synchronize()
        return ["ok": true] as NSDictionary
    }

    private func withFixtureRequest(
        _ operation: String, payload: Data, token: String?,
        execute: () async throws -> Data
    ) async throws -> Data {
        #if EDITH_FUNCTIONAL_FIXTURE
        guard let admission = engineAdmission else { return try await execute() }
        guard let token, let identifier = UUID(uuidString: token) else {
            throw WorkerFixtureError.invalid
        }
        let request = try admission.beginRequest(
            token: identifier, operation: operation, payload: payload)
        do {
            let result = try await execute()
            try Task.checkCancellation()
            try admission.completeRequest(request)
            return result
        } catch {
            admission.cancelRequest(request)
            throw error
        }
        #else
        return try await execute()
        #endif
    }

    private func retirePresentation() {
        guard let presentation else { return }
        presentation.stop()
        let id = UUID()
        presentationStops[id] = Task { [self, presentation] in
            defer { presentationStops[id] = nil }
            await presentation.stopAndWait()
        }
        self.presentation = nil
    }

    private func finishPresentations(_ presentation: ControlPresentation?) async {
        await presentation?.stopAndWait()
        while !presentationStops.isEmpty {
            let pending = Array(presentationStops.values)
            for task in pending { await task.value }
        }
    }

}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
