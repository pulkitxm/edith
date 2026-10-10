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
    private var uiModel: StudioModel?
    private var privacy: SurfacePrivacyState?
    private let commands = ExtensionCommandRegistry()
    private let resources = StudioUIResources()
    private let work = StudioUILongOperations()
    private let streams = try! ExtensionCLIStreams(owner: "studio")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("studio.cli.") {
                return try self.streams.invoke(
                    StudioCommand.self, operation: command, prefix: "studio.cli", payload: payload)
            }
            if command.hasPrefix("studio.ui.blob.") {
                return try self.resources.invoke(command, payload: payload)
            }
            if command.hasPrefix("studio.ui.work.") {
                return try self.work.invoke(command, payload: payload)
            }
            if command.hasPrefix("studio.ui.pdf.") {
                return try await StudioUIPDFCommands.execute(
                    command, payload: payload, model: model,
                    resources: self.resources, work: self.work)
            }
            if command.hasPrefix("studio.ui.image.") {
                return try await StudioUIImageCommands.execute(
                    command, payload: payload, model: model,
                    resources: self.resources, work: self.work)
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
            await work.stopAndWait()
            await commands.shutdownAndWait()
            await model?.stopAndWait()
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
            guard Bundle.main.bundleURL.pathExtension != "appex",
                input["remoteUI"] as? Bool != true,
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil {
                model = StudioModel()
                if let channel = ExtensionSharedState.current {
                    privacy = SurfacePrivacyState(channel: channel)
                }
            }
            model?.start()
            TextEditingCommands.install()
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "studio", let client = configuration.engineClient,
                model == nil
            else { return ["ok": false] as NSDictionary }
            uiModel?.shutdown()
            let facade = StudioUIFacade(client: client)
            uiModel = StudioModel(loadsState: false, facade: facade)
            TextEditingCommands.install()
            if let channel = ExtensionSharedState.current {
                privacy = SurfacePrivacyState(channel: channel)
            }
        case "stopUI":
            TextEditingCommands.shutdown()
            uiModel?.shutdown()
            uiModel = nil
            privacy?.shutdown()
            privacy = nil
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    StudioPage(model: model).environment(\.studioPrivacy, self.privacy)
                        .environment(\.studioFacade, model.facade)
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
        resources.shutdown()
        Task { await work.stopAndWait() }
        commands.shutdown()
        TextEditingCommands.shutdown()
        uiModel?.shutdown()
        uiModel = nil
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
