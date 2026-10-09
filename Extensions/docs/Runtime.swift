import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var browser: DocsBrowser?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let browser = self?.browser else { throw ExtensionPeerError.unavailable }
            return try await DocsSurface.execute(command, payload: payload, browser: browser)
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "docs", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if browser == nil { browser = DocsBrowser() }
        case "view":
            guard let browser else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { DocsScreen(browser: browser) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": _ = DocsPeerDecider.configured()
        case "stop":
            commands.shutdown()
            browser?.shutdown()
            browser = nil
        case "status": return ["ok": true, "running": browser != nil] as NSDictionary
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
