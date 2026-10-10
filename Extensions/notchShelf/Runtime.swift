import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var controller: NotchShelfController?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let controller = self?.controller else { throw ExtensionPeerError.unavailable }
            if command == "notch.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await ShelfCLIExecution.run(
                    request, root: controller.store.root, defaults: controller.context.defaults
                ) { ids in try controller.shareCLIItems(ids) }
                return try JSONEncoder().encode(reply)
            }
            return try await controller.execute(command, payload: payload)
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "notchShelf", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let context = SurfaceHostContext.current
            else { return ["ok": false] as NSDictionary }
            if controller == nil {
                controller = NotchShelfController(context: context)
                NotchPresenterState.shared.privacy = controller?.privacy
                controller?.synchronize()
            }
        case "view":
            guard let controller else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    NotchSettingsPage(controller: controller)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": controller?.synchronize()
        case "stop":
            commands.shutdown()
            controller?.shutdown(); controller = nil
            NotchPresenterState.shared.privacy = nil
            ShelfThumbnails.clear()
        case "status": return ["ok": true, "running": controller != nil] as NSDictionary
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
