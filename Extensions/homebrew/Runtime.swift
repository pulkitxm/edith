import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var model: HomebrewPageModel?

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "homebrew", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let path = input["dataDirectory"] as? String,
                URL(fileURLWithPath: path).standardizedFileURL.path == ExtensionData.root.path
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = HomebrewPageModel() }
            TextEditingCommands.install()
        case "view":
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Homebrew")
                    } content: {
                        HomebrewMaintenanceView(model: model)
                    }
                })
        case "stop":
            model?.cancel()
            model = nil
            TextEditingCommands.shutdown()
        case "cancel": return ["ok": true, "cancelled": model?.cancel() ?? false] as NSDictionary
        case "synchronize": break
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
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
