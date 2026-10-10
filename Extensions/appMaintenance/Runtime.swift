import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithAppMaintenanceExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: AppMaintenanceModel?
    private var uiModel: AppMaintenanceModel?
    private var uiClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()
    private let cliStreams = try? ExtensionCLIStreams(owner: "appMaintenance")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let model = self?.model else { throw ExtensionPeerError.unavailable }
            if command == "appMaintenance.cli.catalog" { return try MaintenanceCLICatalog.data() }
            if command.hasPrefix("maintenance.cli.stream.") {
                guard let cliStreams = self?.cliStreams else {
                    throw ExtensionPeerError.unavailable
                }
                return try cliStreams.invoke(
                    MaintenanceCommand.self, operation: command, prefix: "maintenance.cli.stream",
                    payload: payload)
            }
            if command == "maintenance.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(try await MaintenanceCLIExecution.run(request))
            }
            if command.hasPrefix("maintenance.ui.") {
                return try await AppMaintenanceUICommands.execute(
                    command, payload: payload, model: model)
            }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "appMaintenance", command: command, payload: payload,
                    snapshot: { tile in AppMaintenanceSurface.snapshot(model, tile: tile) },
                    perform: { action in
                        if action == "refresh" { model.refresh() } else { model.cancel() }
                    })
            }
            return try await MaintenanceCommands.execute(command, payload: payload, model: model)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        Task {
            await commands.shutdownAndWait()
            await cliStreams?.stopAndWait()
            await model?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "appMaintenance", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = AppMaintenanceModel() }
            TextEditingCommands.install()
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            stopUI(); uiClient = client; uiModel = AppMaintenanceModel(engineClient: client)
        case "stopUI": stopUI()
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { AppMaintenanceView(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown(); cliStreams?.stop()
            model = nil
            TextEditingCommands.shutdown()
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
