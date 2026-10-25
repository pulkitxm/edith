#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Carbon.HIToolbox
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: HingeEngine?
    private var observer: NSObjectProtocol?

    private var presentation: ControlPresentation?

    private var fixture: WorkerFixtureAdmission?
    private let commands = ExtensionCommandRegistry()
    private var suspended = false
    private var suspension: Task<Void, Never>?
    private var retiredPresentations: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            let reply = try await self.executeCommand(command, payload: payload)
            return reply
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        if command.hasPrefix("hinge.ui.") {
            guard self.service != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "hinge.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "hinge.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                self.service?.applySettings()
            case "hinge.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard action.action == "calibrate", action.value.isEmpty else {
                    throw ExtensionPeerError.invalidRequest
                }
                guard self.fixture == nil else { throw ExtensionPeerError.unavailable }
                self.service?.calibrate()
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let service = self.service else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "hinge", command: command, payload: payload,
            snapshot: { _ in
                HingeSurface.snapshot(active: HingeState.isActive())
            },
            perform: { action in
                HingeState.setActive(action == "enable")
                service.applySettings()
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
        service?.cancelPendingWork()
        if suspension == nil {
            let presentations = Array(retiredPresentations.values)
            suspension = Task { [self, service, presentation] in
                await commands.suspendAndWait()
                await service?.drain()
                await presentation?.stopAndWait()
                for task in presentations { await task.value }
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
                await self.commands.shutdownAndWait()
                let service = self.service
                _ = self.execute(["operation": "stop"])
                await service?.drain()
                for task in Array(self.retiredPresentations.values) { await task.value }
                completion()
            }
        }
    }

    private func requireEngineCurrent() throws {
    }

    private func startService(_ input: NSDictionary) -> Bool {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
        else { return false }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return false }
        SharedDefaults.store.set(true, forKey: HingeState.enabledKey)
        if fixture == nil {
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: "hinge", carbonID: 12, prefix: "hingeHotKey",
                    defaultCode: kVK_ANSI_H,
                    defaultModifiers: controlKey | optionKey))
        }
        if service == nil { service = HingeEngine(fixture: fixture) }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.service?.applySettings() }
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
                "id": "hinge", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !suspended, retiredPresentations.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "hinge",
                configuration.defaultsSuite
                    == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
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
                guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
                    input["hostedFunctionalFixture"] == nil
                else { return ["ok": false] as NSDictionary }
                fixture = try WorkerFixtureAdmission.current(
                    extensionID: "hinge", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                return ["ok": startService(input)] as NSDictionary
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            UIScale.install(from: SharedDefaults.store)
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        HingeRows(presentation: presentation)
                    }
                })
        case "synchronize":
            do { try requireEngineCurrent() } catch {
                return ["ok": false] as NSDictionary
            }
            service?.applySettings()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            suspendCommands(completion: {})
            retirePresentation()
            commands.shutdown()
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
