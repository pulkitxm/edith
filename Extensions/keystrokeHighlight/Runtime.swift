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
final class ExtensionRuntime: NSObject {
    private var service: KeystrokeHighlightRuntime?
    private var observer: NSObjectProtocol?

    private var presentation: ControlPresentation?

    private var fixture: WorkerFixtureAdmission?
    private var engineAdmission: WorkerFixtureEngineAdmission?
    private let commands = ExtensionCommandRegistry()
    private var suspended = false
    private var suspension: Task<Void, Never>?
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]
    private var retiredServices: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        let token = (request["token"] as? String).flatMap { UUID(uuidString: $0) }
        let admission = engineAdmission
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let token, self.engineAdmission === admission else {
                throw ExtensionPeerError.unavailable
            }
            let admitted = try admission?.beginRequest(
                token: token, operation: command, payload: payload)
            defer {
                if let admitted { admission?.cancelRequest(admitted) }
            }
            let reply = try await self.executeCommand(command, payload: payload)
            if let admitted { try admission?.completeRequest(admitted) }
            return reply
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("keystrokeHighlight.ui.") {
            guard self.observer != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "keystrokeHighlight.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "keystrokeHighlight.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                self.synchronize()
            case "keystrokeHighlight.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.action == "inputMonitoring", action.value.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }
                guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
                _ = CGRequestListenEventAccess()
                self.synchronize()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard self.observer != nil else { throw ExtensionPeerError.unavailable }
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        commands.suspend()
        suspended = true
        let service = service
        let presentation = presentation
        presentation?.stop()
        service?.shutdown()
        if suspension == nil {
            let presentations = Array(retiredPresentations.values)
            let retired = Array(retiredServices.values)
            suspension = Task { [self, service, presentation] in
                await commands.suspendAndWait()
                await service?.shutdownAndWait()
                await presentation?.stopAndWait()
                for task in presentations { await task.value }
                for task in retired { await task.value }
            }
        }
        let pending = suspension
        Task { [self] in
            await pending?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        suspendCommands { [self] in
            Task { [self] in
                await commands.shutdownAndWait()
                _ = execute(["operation": "stop"])
                for task in Array(retiredPresentations.values) { await task.value }
                completion()
            }
        }
    }

    private func startService(_ input: NSDictionary) -> Bool {
        guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
        else { return false }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.keystrokeHighlight, carbonID: 9,
                    prefix: "keystrokeHighlightHotKey", defaultCode: kVK_ANSI_K,
                    defaultModifiers: controlKey | optionKey | cmdKey))
        }
        SharedDefaults.store.set(true, forKey: AppStorageKeys.KeystrokeHighlight.enabled)
        if SharedDefaults.store.object(forKey: AppStorageKeys.KeystrokeHighlight.active) == nil {
            SharedDefaults.store.set(true, forKey: AppStorageKeys.KeystrokeHighlight.active)
        }
        synchronize()
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.synchronize() }
            }
        }
        return true
    }

    private func retirePresentation() {
        guard let presentation else { return }
        presentation.stop()
        let id = UUID()
        retiredPresentations[id] = Task { [self, presentation] in
            await presentation.stopAndWait()
            retiredPresentations[id] = nil
        }
        self.presentation = nil
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "keystrokeHighlight", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !suspended, retiredPresentations.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "keystrokeHighlight",
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
            guard !suspended else { return ["ok": false] as NSDictionary }
            do {
                let admission = try WorkerFixtureEngineAdmission.current(
                    extensionID: "keystrokeHighlight", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .helper)
                engineAdmission = admission
                let started: Bool
                if let admission {
                    started = try admission.withPlatformFixture(
                        extensionID: "keystrokeHighlight", expectedRole: .helper
                    ) { namespace in
                        fixture = namespace
                        return startService(input)
                    }
                } else {
                    fixture = nil
                    started = startService(input)
                }
                return ["ok": started] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Keystroke Highlight")
                        } content: {
                            Form { KeystrokeHighlightRows(presentation: presentation) }.formStyle(
                                .grouped)
                        }
                    }
                })
        case "synchronize":
            do { try engineAdmission?.requireCurrent() } catch {
                return ["ok": false] as NSDictionary
            }
            synchronize()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            suspendCommands(completion: {})
            retirePresentation()
            commands.shutdown()
            retireService()
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()

        case "status": return ["ok": true, "running": observer != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func retireService() {
        guard let service else { return }
        self.service = nil
        service.shutdown()
        let id = UUID()
        retiredServices[id] = Task { [self, service] in
            await service.shutdownAndWait()
            retiredServices[id] = nil
        }
    }
    private func synchronize() {
        guard !suspended else { return }
        if fixture == nil {
            HotKeyRegistrar.install(HotKeyCatalog.keystrokeHighlight) { [weak self] in
                let defaults = SharedDefaults.store
                defaults.set(
                    !defaults.bool(forKey: AppStorageKeys.KeystrokeHighlight.active),
                    forKey: AppStorageKeys.KeystrokeHighlight.active)
                self?.synchronize()
            }
        }
        if SharedDefaults.store.bool(forKey: AppStorageKeys.KeystrokeHighlight.active) {
            if service == nil { service = KeystrokeHighlightRuntime(fixture: fixture) }
            service?.syncSettings()
        } else {
            retireService()
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
