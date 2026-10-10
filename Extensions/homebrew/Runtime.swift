import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var surface: HomebrewSurface?
    private var uiModel: HomebrewPageModel?
    private var uiClient: ExtensionEngineClient?
    private var operations: HomebrewEngineCommands?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let surface = self.surface else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("homebrew.") {
                guard let operations = self.operations else { throw ExtensionPeerError.unavailable }
                return try await operations.execute(command, payload: payload)
            }
            return try await SurfaceCommandService.execute(
                providerID: "homebrew", command: command, payload: payload,
                snapshot: { try await surface.snapshot($0) },
                perform: { _ in throw ExtensionPeerError.invalidRequest })
        }
    }

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
            if operations == nil { operations = HomebrewEngineCommands() }
            if surface == nil { surface = HomebrewSurface() }
            TextEditingCommands.install()
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI()
            uiClient = client
            uiModel = HomebrewPageModel(engineClient: client)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("Homebrew")
                    } content: {
                        HomebrewMaintenanceView(model: model)
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown()
            surface?.shutdown(); surface = nil
            operations?.shutdown(); operations = nil
            TextEditingCommands.shutdown()
        case "cancel":
            return ["ok": true, "cancelled": operations?.cancel() ?? false] as NSDictionary
        case "synchronize": break
        case "status": return ["ok": true, "running": operations != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func stopUI() {
        uiModel?.cancel()
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            await operations?.shutdownAndWait()
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
