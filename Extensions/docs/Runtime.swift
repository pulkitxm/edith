import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var browser: DocsBrowser?
    private var uiBrowser: DocsBrowser?
    private var engineClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let browser = self?.browser else { throw ExtensionPeerError.unavailable }
            if command == "docs.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await DocsCLIExecution.run(request, browser: browser))
            }
            if command.hasPrefix("docs.ui.") {
                return try await DocsUIBridge.execute(command, payload: payload, browser: browser)
            }
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
        case "configureUI":
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "docs", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            uiBrowser = DocsBrowser(remote: DocsUIBridge(client: client))
        case "stopUI":
            uiBrowser?.shutdown(); uiBrowser = nil
            engineClient?.invalidate(); engineClient = nil
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if browser == nil { browser = DocsBrowser() }
        case "view":
            guard let browser = uiBrowser else { return ["ok": false] as NSDictionary }
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
