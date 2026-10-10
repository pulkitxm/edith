#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import Foundation
import SwiftUI

@MainActor
@objc(EdithStudioExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var fixture: StudioFixtureTools?
    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let fixtureDefaults: (String) -> UserDefaults?
    private var model: StudioModel?
    private var uiScenes: [UUID: StudioUIScene] = [:]
    private var navigation: StudioSettingsNavigation?
    private let uiConfiguration: (NSDictionary) -> ExtensionUIConfiguration?
    private var privacy: SurfacePrivacyState?
    private let commands = ExtensionCommandRegistry()
    private let recorderCommands = StudioUIRecorderCommands()
    private let videoSessions = StudioUIVideoSessions()
    private let resources = StudioUIResources()
    private let work = StudioUILongOperations()
    private var streams: ExtensionCLIStreams?

    override convenience init() {
        self.init(uiConfiguration: { ExtensionUIConfiguration(context: $0) })
    }

    init(
        uiConfiguration: @escaping (NSDictionary) -> ExtensionUIConfiguration?,
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? = {
            try WorkerFixtureAdmission.current(
                extensionID: "studio", context: $0,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        }, fixtureDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) {
        self.uiConfiguration = uiConfiguration
        self.admitFixture = admitFixture
        self.fixtureDefaults = fixtureDefaults
        super.init()
        work.onChange = { [weak self] state in self?.videoSessions.recordExport(state) }
        videoSessions.onExport = { [weak self] state in self?.model?.exportState = state }
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model else { throw ExtensionPeerError.unavailable }
            if self.fixture != nil {
                if command == "surface.snapshot" {
                    return try await SurfaceCommandService.execute(
                        providerID: "studio", command: command,
                        payload: payload,
                        snapshot: { tile in
                            StudioSurface.snapshot(model, files: [], projects: [], tile: tile)
                        }, perform: { _ in throw ExtensionPeerError.unavailable })
                }
                guard
                    ["studio.tools.list", "studio.tools.schema", "studio.ui.settings.snapshot"]
                        .contains(command)
                else { throw ExtensionPeerError.unavailable }
            }
            if command.hasPrefix("studio.cli.") {
                if self.streams == nil { self.streams = try ExtensionCLIStreams(owner: "studio") }
                guard let streams = self.streams else { throw ExtensionPeerError.unavailable }
                return try streams.invoke(
                    StudioCommand.self, operation: command, prefix: "studio.cli", payload: payload)
            }
            if command.hasPrefix("studio.ui.") {
                do {
                    if command == "studio.ui.settings.open" {
                        guard let navigation = self.navigation else {
                            throw ExtensionPeerError.unavailable
                        }
                        return try await navigation.execute(payload)
                    }
                    if command.hasPrefix("studio.ui.record.") {
                        return try await self.recorderCommands.execute(
                            command, payload: payload, work: self.work)
                    }
                    if command.hasPrefix("studio.ui.media.") {
                        return try await StudioUIMediaCommands.execute(
                            command, payload: payload, resources: self.resources, work: self.work)
                    }
                    if command.hasPrefix("studio.ui.video.") {
                        return try await self.videoSessions.execute(
                            command, payload: payload, resources: self.resources, work: self.work)
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
                        return try await StudioUICommands.execute(
                            command, payload: payload, model: model)
                    }
                } catch is CancellationError { throw CancellationError() } catch {
                    return try JSONEncoder().encode(StudioUIFailure(error))
                }
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
        let hadEngine = model != nil && fixture == nil
        commands.shutdown()
        streams?.stop()
        Task {
            await streams?.stopAndWait()
            await work.stopAndWait()
            await videoSessions.stopAndWait()
            await commands.shutdownAndWait()
            if hadEngine { await VideoEditorOpenBridge.shared.stopAndWait() }
            await model?.stopAndWait()
            shutdown()
            if hadEngine, #available(macOS 15.0, *) {
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
                let suite = input["defaultsSuite"] as? String
            else { return ["ok": false] as NSDictionary }
            do {
                let admission = try admitFixture(input)
                guard
                    admission != nil
                        || suite
                            == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                if model == nil {
                    if let admission {
                        let tools = try StudioFixtureTools(admission: admission)
                        guard let defaults = fixtureDefaults(suite) else {
                            return ["ok": false] as NSDictionary
                        }
                        model = tools.makeModel(defaults: defaults)
                        fixture = tools
                    } else {
                        model = StudioModel()
                        if let channel = ExtensionSharedState.current {
                            privacy = SurfacePrivacyState(channel: channel)
                        }
                    }
                }
            } catch { return ["ok": false] as NSDictionary }
            if fixture == nil, navigation == nil {
                navigation = StudioSettingsNavigation(bridge: input["hostNavigation"] as? NSObject)
            }
            model?.start()
            if fixture == nil { TextEditingCommands.install() }
        case "configureUI":
            do {
                guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }
            } catch { return ["ok": false] as NSDictionary }
            guard let configuration = uiConfiguration(input),
                configuration.extensionID == "studio", !configuration.uiOnly,
                configuration.defaultsSuite
                    == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let client = configuration.engineClient, model == nil,
                let route = StudioUIScene.Route(context: input),
                uiScenes.count < 16 || uiScenes[client.presentationID] != nil
            else { return ["ok": false] as NSDictionary }
            uiScenes[client.presentationID]?.stop()
            uiScenes[client.presentationID] = StudioUIScene(client: client, route: route)
        case "stopUI":
            if input["presentationID"] == nil {
                for scene in uiScenes.values { scene.stop() }
                uiScenes.removeAll()
                TextEditingCommands.shutdown()
                return ["ok": true] as NSDictionary
            }
            guard let value = input["presentationID"] as? String,
                let id = UUID(uuidString: value), let scene = uiScenes.removeValue(forKey: id)
            else { return ["ok": false] as NSDictionary }
            scene.stop()
            if !uiScenes.values.contains(where: { $0.route == .main }) {
                TextEditingCommands.shutdown()
            }
        case "view":
            guard let value = input["presentationID"] as? String,
                let id = UUID(uuidString: value), let scene = uiScenes[id],
                scene.route == StudioUIScene.Route(context: input)
            else { return ["ok": false] as NSDictionary }
            return scene.controller()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            privacy?.refresh()
            for scene in uiScenes.values { scene.synchronize() }
        case "stop": shutdown()
        case "status":
            return [
                "ok": true, "running": model != nil,
                "preventsQuit": videoSessions.export?.phase == "running",
            ] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func shutdown() {
        let hadEngine = model != nil && fixture == nil
        streams?.stop()
        resources.shutdown()
        Task {
            await work.stopAndWait(); await videoSessions.stopAndWait()
        }
        commands.shutdown()
        if hadEngine || !uiScenes.isEmpty { TextEditingCommands.shutdown() }
        for scene in uiScenes.values { scene.stop() }
        uiScenes.removeAll()
        navigation?.invalidate()
        navigation = nil
        model?.shutdown()
        model = nil
        privacy?.shutdown()
        privacy = nil
        if hadEngine { VideoEditorOpenBridge.shared.shutdown() }
        fixture = nil
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
