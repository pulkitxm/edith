import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: ColorPickerStore?
    private var observer: NSObjectProtocol?

    private var presentation: ControlPresentation?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command == "colorPicker.cli.catalog" {
                return try ColorCLIExecution.catalog(payload)
            }
            if command == "colorPicker.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                if let help = try await ColorCLIExecution.help(request) {
                    return try JSONEncoder().encode(help)
                }
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
                guard let service = self.service else { throw ExtensionPeerError.unavailable }
                let reply = try await ColorCLIExecution.run(
                    request, defaults: SharedDefaults.store,
                    pick: { service.pick() },
                    write: { value in
                        NSPasteboard.general.clearContents()
                        return NSPasteboard.general.setString(value, forType: .string)
                    }, changed: { service.reloadHistory() })
                return try JSONEncoder().encode(reply)
            }
            if command.hasPrefix("colorPicker.ui.") {
                guard let self, self.service != nil else { throw ExtensionPeerError.unavailable }
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
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "colorPicker", command: command, payload: payload,
                snapshot: { _ in
                    ColorPickerSurface.snapshot(history: service.history, error: service.copyError)
                },
                perform: { action in
                    if action == "pick" {
                        service.pick()
                    } else if let color = service.history.first(where: {
                        "copy:" + $0.id.uuidString == action
                    }) {
                        service.copyDefault(color)
                    } else {
                        throw ExtensionPeerError.invalidRequest
                    }
                })
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            _ = execute(["operation": "stop"])
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
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
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            presentation?.stop()
            presentation = ControlPresentation(client: configuration.engineClient)
            return ["ok": true] as NSDictionary
        case "stopUI":
            presentation?.stop()
            presentation = nil
            return ["ok": true] as NSDictionary
        case "prepareToStop":
            commands.shutdown()
            return ["ok": true] as NSDictionary
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex", presentation == nil
            else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            HotKeyRegistrar.configure(
                ExtensionHotKeyBinding(
                    id: HotKeyCatalog.colorPicker, carbonID: 5, prefix: "colorPickerHotKey",
                    defaultCode: kVK_ANSI_C, defaultModifiers: cmdKey | optionKey | controlKey))
            SharedDefaults.store.set(true, forKey: AppStorageKeys.ColorPicker.enabled)
            if service == nil { service = ColorPickerStore() }
            service?.registerHotKey()
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.service?.registerHotKey() }
                }
            }
        case "view":
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
        case "synchronize": service?.registerHotKey()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            presentation?.stop()
            presentation = nil
            commands.shutdown()
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()
        case "pick": service?.pick()
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
