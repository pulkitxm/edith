import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: ColorPickerStore?
    private var observer: NSObjectProtocol?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
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
        case "start":
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
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Color Picker")
                    } content: {
                        Form { ColorPickerRows() }.formStyle(.grouped)
                    }
                })
        case "synchronize": service?.registerHotKey()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
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
