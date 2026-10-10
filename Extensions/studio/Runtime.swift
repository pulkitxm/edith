import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import Foundation
import SwiftUI

@MainActor
@objc(EdithStudioExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: StudioModel?
    private var privacy: SurfacePrivacyState?
    private let commands = ExtensionCommandRegistry()
    private let streams = try! ExtensionCLIStreams(owner: "studio")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("studio.cli.") {
                return try self.streams.invoke(
                    StudioCommand.self, operation: command, prefix: "studio.cli", payload: payload)
            }
            if command.hasPrefix("studio.ui.") {
                return try await StudioUICommands.execute(command, payload: payload, model: model)
            }
            if command == "studio.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await StudioCLIExecution.run(request, model: model))
            }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "studio", command: command, payload: payload,
                    snapshot: { tile in
                        let files = try StudioMediaLibrary.list(defaults: model.defaults)
                        let projects = try await BlockingWork.perform {
                            VideoProject.listProjects()
                        }
                        return StudioSurface.snapshot(
                            model, files: files, projects: projects, tile: tile)
                    },
                    perform: { action in try StudioSurface.perform(action, model: model) })
            }
            return try await StudioCommands.execute(command, payload: payload, model: model)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        streams.stop()
        Task {
            await streams.stopAndWait()
            await commands.shutdownAndWait()
            shutdown()
            if #available(macOS 15.0, *) {
                await StudioRecordBridge.shared.shutdown(); await VideoRecorder.shutdownAll()
            }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "studio", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard input["remoteUI"] as? Bool != true,
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil {
                model = StudioModel()
                if let channel = ExtensionSharedState.current {
                    privacy = SurfacePrivacyState(channel: channel)
                }
            }
            TextEditingCommands.install()
        case "view":
            guard let model else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    StudioPage(model: model).environment(\.studioPrivacy, self.privacy)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": privacy?.refresh()
        case "stop": shutdown()
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func shutdown() {
        streams.stop()
        commands.shutdown()
        TextEditingCommands.shutdown()
        model?.shutdown()
        model = nil
        privacy?.shutdown()
        privacy = nil
        VideoEditorOpenBridge.shared.shutdown()
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
