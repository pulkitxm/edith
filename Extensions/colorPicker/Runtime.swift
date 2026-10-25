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
final class ExtensionRuntime: NSObject {
    typealias FixtureAuthority = WorkerFixtureAdmission
    private var service: ColorPickerStore?
    private var observer: NSObjectProtocol?

    private var presentation: ControlPresentation?

    private var fixture: WorkerFixtureAdmission?
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            request["hostedFunctionalFixture"] == nil
        else { completion(nil, "The functional fixture is unavailable."); return }
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let token else { throw ExtensionPeerError.invalidRequest }
            try Task.checkCancellation()
            return try await self.executeCommand(command, payload: payload)
        }
    }

    private static func admitFixtureContext(_ input: NSDictionary) throws -> FixtureAuthority? {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            input["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "colorPicker", context: input,
            roleBundle: Bundle(for: ExtensionRuntime.self))
    }

    private func checkFixtureCurrent() throws {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil else {
            throw WorkerFixtureError.invalid
        }
    }

    private func executeCommand(_ command: String, payload: Data) async throws -> Data {
        if command == "colorPicker.cli.catalog" {
            return try ColorCLIExecution.catalog(payload)
        }
        if command == "colorPicker.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            if let help = try await ColorCLIExecution.help(request) {
                return try JSONEncoder().encode(help)
            }
            let service = self.service
            if request.arguments.first == "pick", service == nil {
                throw ExtensionPeerError.unavailable
            }
            let reply = try await ColorCLIExecution.run(
                request, defaults: SharedDefaults.store,
                pick: { service?.pick() },
                write: { value in
                    if self.fixture != nil { return service?.writeFixtureCopy(value) ?? false }
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(value, forType: .string)
                }, changed: { service?.reloadHistory() })
            return try JSONEncoder().encode(reply)
        }
        if command.hasPrefix("colorPicker.ui.") {
            guard self.service != nil else { throw ExtensionPeerError.unavailable }
            let defaults = SharedDefaults.store
            switch command {
            case "colorPicker.ui.read":
                guard payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.invalidRequest
                }
            case "colorPicker.ui.update":
                try ControlPresentationContract.update(payload, defaults: defaults)
                self.service?.registerHotKey()
            case "colorPicker.ui.action":
                let action = try JSONDecoder().decode(
                    ControlPresentationAction.self, from: payload)
                guard let service = self.service else { throw ExtensionPeerError.unavailable }
                if action.action == "pick", action.value.isEmpty {
                    service.pick()
                } else if action.action == "copy",
                    let pair = action.value.split(separator: ":").first,
                    let swatch = service.history.first(where: {
                        $0.id.uuidString == String(pair)
                    }),
                    let format = action.value.split(separator: ":").last.flatMap({
                        ColorCopyFormat(rawValue: String($0))
                    }),
                    action.value == swatch.id.uuidString + ":" + format.rawValue
                {
                    service.copy(swatch, as: format)
                    if let error = service.copyError {
                        throw ExtensionPeerError.rejected(error)
                    }
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
            default: throw ExtensionPeerError.invalidRequest
            }
            return try ControlPresentationContract.snapshot(
                defaults: defaults, state: ControlPresentationState())
        }
        guard let service = self.service else { throw ExtensionPeerError.unavailable }
        return try await SurfaceCommandService.execute(
            providerID: "colorPicker", command: command, payload: payload,
            snapshot: { tile in
                try await ColorPickerSurface.snapshot(
                    tile: tile, clipboardActive: ColorPickerClipboardPeer.active,
                    pinToTop: ColorPickerClipboardPeer.pinToTop,
                    entries: { try await ColorPickerClipboardPeer.entries() })
            },
            perform: { action in
                if action == "pick" {
                    service.pick()
                } else {
                    try await ColorPickerClipboardPeer.perform(action)
                }
            })
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = service
        let ui = presentation
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        ui?.stop()
        owner?.shutdown()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            _ = await commands.suspendAndWait()
            await owner?.stopAndWait()
            await ui?.stopAndWait()
            while let task = uiDrains.values.first { await task.value }
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = service
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        retirePresentation()
        service = nil
        IPC.stopObserving(observer); observer = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            owner?.shutdown()
            HotKeyRegistrar.shutdown()
        }
        resourceStop = task
        return task
    }

    private func retirePresentation() {
        guard let owner = presentation else { return }
        owner.stop()
        let id = UUID()
        uiDrains[id] = Task { [self, owner] in
            defer { uiDrains[id] = nil }
            await owner.stopAndWait()
        }
        presentation = nil
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        if ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] != nil
            || input["hostedFunctionalFixture"] != nil
        {
            let allowed = [
                "describe", "status", "stop", "stopUI", "prepareToStop", "cancelCommand",
            ]
            guard let operation = input["operation"] as? String, allowed.contains(operation) else {
                return ["ok": false] as NSDictionary
            }
        }
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "colorPicker", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "colorPicker",
                configuration.defaultsSuite
                    == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard !commandsSuspended, uiDrains.count < 8 else {
                return ["ok": false] as NSDictionary
            }
            retirePresentation()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            retirePresentation()
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            _ = beginResourceStop()
            return ["ok": true] as NSDictionary
        case "start":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard !ExtensionHostRole.isInterfaceProcess, presentation == nil
            else { return ["ok": false] as NSDictionary }
            do {
                let verified = try Self.admitFixtureContext(input)
                guard let suite = input["defaultsSuite"] as? String,
                    suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                let admission = verified
                let construct: (WorkerFixtureAdmission?) throws -> ColorPickerStore = {
                    [self] namespace in
                    if namespace == nil {
                        HotKeyRegistrar.configure(
                            ExtensionHotKeyBinding(
                                id: HotKeyCatalog.colorPicker, carbonID: 5,
                                prefix: "colorPickerHotKey", defaultCode: kVK_ANSI_C,
                                defaultModifiers: cmdKey | optionKey | controlKey))
                    }
                    SharedDefaults.store.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
                    let owner = service ?? ColorPickerStore(fixture: namespace)
                    owner.registerHotKey()
                    return owner
                }
                service = try construct(admission)
                fixture = admission
                if observer == nil {
                    observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                        MainActor.assumeIsolated {
                            guard let self else { return }
                            do {
                                try self.checkFixtureCurrent();
                                self.service?.registerHotKey()
                            } catch {}
                        }
                    }
                }
            } catch { return ["ok": false] as NSDictionary }
        case "view":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    ControlSettingsHost(presentation: presentation) {
                        PageWorkspace {
                            PageHeader("Color Picker")
                        } content: {
                            Form { ColorPickerRows(presentation: presentation) }.formStyle(.grouped)
                        }
                    }
                })
        case "synchronize":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            do { try checkFixtureCurrent(); service?.registerHotKey() } catch {
                return ["ok": false] as NSDictionary
            }
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            _ = beginResourceStop()
        case "pick":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            do { try checkFixtureCurrent(); service?.pick() } catch {
                return ["ok": false] as NSDictionary
            }
        case "status": return ["ok": true, "running": observer != nil] as NSDictionary
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
