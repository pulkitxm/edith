#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: SweaterEngine?
    private var observer: NSObjectProtocol?

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
                if command.hasPrefix("windowSweaters.ui.") {
                    guard let self, self.service != nil else {
                        throw ExtensionPeerError.unavailable
                    }
                    let defaults = SharedDefaults.store
                    switch command {
                    case "windowSweaters.ui.read":
                        guard payload == Data("{}".utf8) else {
                            throw ExtensionPeerError.invalidRequest
                        }
                    case "windowSweaters.ui.update":
                        try ControlPresentationContract.update(payload, defaults: defaults)
                        self.service?.applySettings()
                    case "windowSweaters.ui.action":
                        _ = try JSONDecoder().decode(
                            ControlPresentationAction.self, from: payload)
                        throw ExtensionPeerError.invalidRequest
                    default: throw ExtensionPeerError.invalidRequest
                    }
                    return try ControlPresentationContract.snapshot(
                        defaults: defaults, state: ControlPresentationState())
                }
                guard let self, let service = self.service else {
                    throw ExtensionPeerError.unavailable
                }
                return try await SurfaceCommandService.execute(
                    providerID: "windowSweaters", command: command, payload: payload,
                    snapshot: { _ in
                        WindowSweatersSurface.snapshot(
                            active: SweaterState.isActive(),
                            pattern: SweaterState.settings().pattern.rawValue)
                    },
                    perform: { action in
                        SweaterState.setActive(action == "enable")
                        service.applySettings()
                        IPC.post(IPC.Name.settingsChanged)
                    })
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
                "id": "windowSweaters", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !draining, presentationStops.isEmpty else { return ["ok": false] as NSDictionary }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "windowSweaters",
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
                    extensionID: "windowSweaters", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .helper)
                engineAdmission = admission
                if let admission {
                    return try admission.withPlatformFixture(
                        extensionID: "windowSweaters", expectedRole: .helper
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
                    extensionID: "windowSweaters", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                return startOwned(input)
            } catch { return ["ok": false] as NSDictionary }
            #endif
        case "view":
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Window Sweaters")
                        } content: {
                            Form { WindowSweatersRows() }.formStyle(.grouped)
                        }
                    }
                })
        case "synchronize":
            guard !draining else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            if let engineAdmission {
                do { try engineAdmission.requireCurrent() } catch {
                    return ["ok": false] as NSDictionary
                }
            }
            #endif
            service?.applySettings()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            retirePresentation()
            commands.shutdown()
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func startOwned(_ input: NSDictionary) -> NSObject {
        guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
        else { return ["ok": false] as NSDictionary }
        guard let suite = input["defaultsSuite"] as? String,
            suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
        else { return ["ok": false] as NSDictionary }
        SharedDefaults.store.set(true, forKey: SweaterState.enabledKey)
        if service == nil { service = SweaterEngine(fixture: fixture) }
        if observer == nil {
            observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.service?.applySettings() }
            }
        }
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
