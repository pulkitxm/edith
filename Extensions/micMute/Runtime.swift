import AppKit
import Carbon.HIToolbox
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: MicMuteEngine?
    private var observer: NSObjectProtocol?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "micMute", command: command, payload: payload,
                snapshot: { _ in MicMuteSurface.snapshot(muted: service.muted, error: service.error)
                },
                perform: { action in
                    service.setMuted(action == "mute")
                })
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "micMute", "role": "helper",
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
                    id: HotKeyCatalog.micMute, carbonID: 6, prefix: "micHotKey",
                    defaultCode: kVK_ANSI_M, defaultModifiers: cmdKey | shiftKey))
            SharedDefaults.store.set(true, forKey: AppStorageKeys.Mic.muteEnabled)
            if service == nil { service = MicMuteEngine() }
            service?.syncSettings()
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.service?.syncSettings() }
                }
            }
        case "view":
            guard let service else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Mic Mute")
                    } content: {
                        Form { MicMuteRows(service: service) }.formStyle(.grouped)
                    }
                })
        case "synchronize": service?.syncSettings()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown()
            service?.shutdown()
            service = nil
            IPC.stopObserving(observer)
            observer = nil
            HotKeyRegistrar.shutdown()
        case "toggle": service?.toggle()
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
