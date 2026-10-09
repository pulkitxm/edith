import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: SweaterEngine?
    private var observer: NSObjectProtocol?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
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
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            SharedDefaults.store.set(true, forKey: SweaterState.enabledKey)
            if service == nil { service = SweaterEngine() }
            if observer == nil {
                observer = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                    MainActor.assumeIsolated { self?.service?.applySettings() }
                }
            }
        case "view":
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Window Sweaters")
                    } content: {
                        Form { WindowSweatersRows() }.formStyle(.grouped)
                    }
                })
        case "synchronize": service?.applySettings()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
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
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
