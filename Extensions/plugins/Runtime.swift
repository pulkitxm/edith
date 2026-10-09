import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionDocuments
import Foundation
import SwiftUI

@MainActor @objc(EdithPluginsExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: SkillsModel?
    private var surface: PluginsSurface?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        Task {
            await model?.shutdown(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "plugins", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard DocumentRenderer.isAvailable else { return ["ok": false] as NSDictionary }
            if model == nil { model = SkillsModel() }
            if let model, surface == nil { surface = PluginsSurface(model: model) }
            TextEditingCommands.install()
        case "view":
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { PluginsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            model = nil; surface = nil
            SkillBrand.shutdown()
            TextEditingCommands.shutdown()
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
