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
    private var uiClient: ExtensionEngineClient?
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
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if commands == nil {
                let commands = JevCommands()
                self.commands = commands
                startup = Task { _ = await commands.engine.status(probe: false) }
            }
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI()
            uiClient = client
            model = JevSettingsModel(engineClient: client)
        case "stopUI": stopUI()
        case "view":
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { JevSettingsPane(model: model) })
        case "cancelCommand": commands?.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            startup?.cancel()
            startup = nil
            commands?.shutdown()
            commands = nil
        case "status": return ["ok": true, "running": commands != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        model?.shutdown(); model = nil
        uiClient?.invalidate(); uiClient = nil
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let owner = commands
        owner?.suspend()
        let startup = startup
        startup?.cancel()
        Task { [self, owner, startup] in
            await startup?.value
            await owner?.suspendAndWait()
            self.startup = nil
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let owner = commands
        let startup = startup
        startup?.cancel()
        Task { [self, owner, startup] in
            await startup?.value
            await owner?.shutdownAndWait()
            self.startup = nil
            completion()
        }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
