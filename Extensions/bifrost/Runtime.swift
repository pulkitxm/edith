import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithBifrostExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: BifrostWorker?
    private var uiContext: BifrostUIContext?
    private var engineClient: ExtensionEngineClient?
    private var surface: BifrostSurface?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker, let surface = self.surface else {
                throw ExtensionPeerError.unavailable
            }
            if command == "bifrost.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await BifrostCLIExecution.run(request, store: worker.store))
            }
            if command.hasPrefix("bifrost.ui.") {
                return try BifrostUIContext.execute(command, payload: payload, worker: worker)
            }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        Task {
            do { try await worker?.prepareDisable(); completion(nil) } catch {
                completion(error as NSError)
            }
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "bifrost", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "bifrost", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            let context = BifrostUIContext(client: client)
            uiContext = context; BifrostUIContext.current = context
            TextEditingCommands.install()
        case "stopUI":
            uiContext?.shutdown(); uiContext = nil; BifrostUIContext.current = nil
            engineClient?.invalidate(); engineClient = nil
            TextEditingCommands.shutdown()
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if worker == nil {
                let created = BifrostWorker(); worker = created;
                surface = BifrostSurface(store: created.store)
            }
            if ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] != "1" {
                TextEditingCommands.install()
            }
        case "view":
            guard let context = uiContext else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { BifrostSettings(context: context) })
        case "synchronize": worker?.configureHotKey()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown(); worker?.shutdown(); worker = nil; surface = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
        case "status": return ["ok": true, "running": worker != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createBifrostExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
