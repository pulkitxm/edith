import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithCleanerExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: CleanerModel?
    private var uiModel: CleanerModel?
    private var uiClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let model = self?.model else { throw ExtensionPeerError.unavailable }
            if command == "cleaner.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(try await CleanerCLIExecution.run(request))
            }
            if command.hasPrefix("cleaner.ui.") {
                return try await CleanerUICommands.execute(command, payload: payload, model: model)
            }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "cleaner", command: command, payload: payload,
                    snapshot: { tile in CleanerSurface.snapshot(model) },
                    perform: { action in
                        if action == "scan" { model.scan() } else { model.cancelScan() }
                    })
            }
            return try await CleanerCommands.execute(command, payload: payload, model: model)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            await model?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "cleaner", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = CleanerModel() }
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient,
                let defaults = UserDefaults(suiteName: configuration.defaultsSuite)
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client;
            uiModel = CleanerModel(engineClient: client, defaults: defaults)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { CleanerPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            model = nil
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        let model = uiModel; uiModel = nil
        uiClient?.invalidate(); uiClient = nil
        Task { await model?.shutdown() }
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
