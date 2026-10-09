import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithJevExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var commands: JevCommands?
    private var model: JevSettingsModel?
    private var startup: Task<Void, Never>?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard let commands else { completion(nil, "Jev is disabled."); return }
        commands.invoke(request, completion: completion)
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "jev", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if commands == nil {
                let commands = JevCommands()
                self.commands = commands
                model = JevSettingsModel(engine: commands.engine)
                startup = Task { _ = await commands.engine.status(probe: false) }
            }
        case "view":
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { JevSettingsPane(model: model) })
        case "cancelCommand": commands?.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            startup?.cancel()
            startup = nil
            model?.shutdown()
            model = nil
            commands?.shutdown()
            commands = nil
        case "status": return ["ok": true, "running": commands != nil] as NSDictionary
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
