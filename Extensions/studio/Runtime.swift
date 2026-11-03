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
final class StudioService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var fixture: StudioFixtureTools?
    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let fixtureDefaults: (String) -> UserDefaults?
    private let expectedSuite: () -> String?
    private var model: StudioModel?
    private var uiScenes: [UUID: StudioUIScene] = [:]
    private var retiringScenes: [UUID: Task<Void, Never>] = [:]
    private var navigation: StudioSettingsNavigation?
    private var privacy: SurfacePrivacyState?
    private let recorderCommands = StudioUIRecorderCommands()
    private let videoSessions = StudioUIVideoSessions()
    private let resources = StudioUIResources()
    private let work = StudioUILongOperations()
    private var streams: ExtensionCLIStreams?
    private var hadEngine = false
    private var hadUI = false
    private var suspendedWork: SuspendedWork?

    private struct SuspendedWork {
        let model: StudioModel?
        let fixture: StudioFixtureTools?
        let streams: ExtensionCLIStreams?
        let scenes: [StudioUIScene]
    }

    init(
        runtime: ExtensionServiceRuntime,
        admitFixture: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil,
        fixtureDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
        expectedSuite: @escaping () -> String? = {
            ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
        }
    ) {
        self.runtime = runtime
        self.admitFixture =
            admitFixture ?? {
                try WorkerFixtureAdmission.current(
                    extensionID: "studio", context: $0,
                    roleBundle: Bundle(for: StudioService.self))
            }
        self.fixtureDefaults = fixtureDefaults
        self.expectedSuite = expectedSuite
        work.onChange = { [weak self] state in self?.videoSessions.recordExport(state) }
        videoSessions.onExport = { [weak self] state in self?.model?.exportState = state }
    }

    var isRunning: Bool { model != nil }

    var allowsUIDuringRetirement: Bool { true }

    var statusDetails: [String: Any] {
        ["preventsQuit": videoSessions.export?.phase == "running"]
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        let input = context.input
        guard !ExtensionHostRole.isInterfaceProcess, input["remoteUI"] as? Bool != true
        else { return false }
        do {
            let admission = try admitFixture(input)
            if model == nil {
                if let admission {
                    let tools = try StudioFixtureTools(admission: admission)
                    guard let suite = input["defaultsSuite"] as? String,
                        let defaults = fixtureDefaults(suite)
                    else { return false }
                    model = tools.makeModel(defaults: defaults)
                    fixture = tools
                } else {
                    model = StudioModel()
                    if let channel = ExtensionSharedState.current {
                        privacy = SurfacePrivacyState(channel: channel)
                    }
                }
            }
        } catch { return false }
        if fixture == nil, navigation == nil {
            navigation = StudioSettingsNavigation(bridge: input["hostNavigation"] as? NSObject)
            VideoEditorOpenBridge.shared.present = { [weak self] in self?.surfaceEditor() }
        }
        model?.start()
        if fixture == nil { TextEditingCommands.install() }
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        privacy?.refresh()
        for scene in uiScenes.values { scene.synchronize() }
        return true
    }

    func invoke(_ command: String, token: UUID, payload: Data) async throws -> Data {
        guard let model = self.model else { throw ExtensionPeerError.unavailable }
        if let fixture = self.fixture {
            if let admission = fixture.engineAdmission {
                let receipt = try admission.beginRequest(
                    token: token, operation: command, payload: payload)
                defer { admission.cancelRequest(receipt) }
                let result: Data
                if command == "studio.ui.video.export" {
                    result = try await StudioUILongOperations.scoped(payload: payload) { body in
                        try JSONEncoder().encode(
                            self.work.start(retained: true) { progress in
                                try JSONEncoder().encode(
                                    try await fixture.renderNativeExport(
                                        payload: body, progress: progress))
                            })
                    }
                } else if command == "studio.ui.work.read" || command == "studio.ui.work.cancel" {
                    result = try self.work.invoke(command, payload: payload)
                } else {
                    throw WorkerFixtureError.invalid
                }
                try admission.completeRequest(receipt)
                return result
            }
            if command == "surface.snapshot" {
                return try await SurfaceCommandService.execute(
                    providerID: "studio", command: command,
                    payload: payload,
                    snapshot: { tile in
                        StudioSurface.snapshot(model, files: [], projects: [], tile: tile)
                    }, perform: { _ in throw ExtensionPeerError.unavailable })
            }
            guard
                ["studio.tools.list", "studio.tools.schema"]
                    .contains(command)
            else { throw ExtensionPeerError.unavailable }
        }
        if command == "studio.cli.catalog" {
            return try ExtensionCLICatalog.data(
                StudioCommand.self, owner: "studio", payload: payload, streaming: true)
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
        if let fixture = self.fixture {
            return try await StudioCommands.execute(
                command, payload: payload, model: model,
                workflowDirectory: fixture.admission.dataDirectory)
        }
        return try await StudioCommands.execute(command, payload: payload, model: model)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        do {
            guard try admitFixture(configuration.input) == nil else { return false }
        } catch { return false }
        guard !configuration.uiOnly, configuration.defaultsSuite == expectedSuite(),
            let client = configuration.engineClient, model == nil,
            let route = StudioUIScene.Route(context: configuration.input),
            uiScenes.count < 16 || uiScenes[client.presentationID] != nil
        else { return false }
        if let previous = uiScenes[client.presentationID] { retire(previous) }
        uiScenes[client.presentationID] = StudioUIScene(client: client, route: route)
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard let scene = uiScenes[presentation],
            scene.route == StudioUIScene.Route(context: context.input)
        else { return nil }
        return scene.controller()
    }

    func acceptsStopUI(for presentation: UUID?) -> Bool {
        presentation.map { uiScenes[$0] != nil } ?? true
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        guard let presentation else {
            let scenes = Array(uiScenes.values)
            uiScenes.removeAll()
            let tasks = scenes.map { retire($0) }
            if !scenes.isEmpty {
                ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                    TextEditingCommands.shutdown()
                }
            }
            return tasks
        }
        guard let scene = uiScenes.removeValue(forKey: presentation) else { return [] }
        let task = retire(scene)
        if !uiScenes.values.contains(where: { $0.route == .main }) {
            ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
        }
        return [task]
    }

    func cancelPendingWork() {
        let owned = SuspendedWork(
            model: model, fixture: fixture, streams: streams, scenes: Array(uiScenes.values))
        suspendedWork = owned
        owned.fixture?.engineAdmission?.closeAdmission()
        owned.fixture?.nativeExporter?.suspendCommands()
        work.suspend()
        videoSessions.suspend()
        resources.suspend()
        owned.streams?.stop()
        owned.model?.suspendCommands()
        for scene in owned.scenes { scene.suspendCommands() }
    }

    func drain() async {
        guard let owned = suspendedWork else { return }
        await owned.streams?.stopAndWait()
        await work.suspendAndWait()
        await resources.suspendAndWait()
        await owned.fixture?.nativeExporter?.suspendCommandsAndWait()
        await owned.model?.suspendCommandsAndWait()
        for scene in owned.scenes { await scene.suspendCommandsAndWait() }
    }

    func finishBeforeStop() async {
        let ownedFixture = fixture
        let ownedStreams = streams
        let ownedScenes = Array(uiScenes.values)
        hadEngine = model != nil && fixture == nil
        hadUI = !ownedScenes.isEmpty
        ownedFixture?.engineAdmission?.closeAdmission()
        ownedFixture?.nativeExporter?.suspendCommands()
        work.suspend()
        videoSessions.suspend()
        resources.suspend()
        ownedStreams?.stop()
        for scene in ownedScenes {
            scene.suspendCommands()
            retire(scene)
        }
        uiScenes.removeAll()
        navigation?.invalidate()
        navigation = nil
        VideoEditorOpenBridge.shared.present = {}
        if hadEngine || hadUI {
            ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
        }
    }

    func teardown() async {
        let ownedModel = model
        let ownedFixture = fixture
        let ownedStreams = streams
        for scene in Array(retiringScenes.values) { await scene.value }
        await ownedStreams?.stopAndWait()
        await work.stopAndWait()
        await videoSessions.stopAndWait()
        await resources.shutdownAndWait()
        await ownedFixture?.stopNativeExportAndWait()
        if hadEngine { await VideoEditorOpenBridge.shared.stopAndWait() }
        await ownedModel?.stopAndWait()
        if hadEngine { await VideoExporter.shared.suspendCommandsAndWait() }
        if hadEngine, #available(macOS 15.0, *) {
            await StudioRecordBridge.shared.stopAndWait()
            await VideoRecorder.shutdownAll()
        }
        model = nil
        privacy?.shutdown()
        privacy = nil
        fixture = nil
    }

    private func surfaceEditor() {
        guard !runtime.isStopping else { return }
        for scene in uiScenes.values where scene.route == .main { scene.model.facade?.refresh() }
        navigation?.surface()
    }

    @discardableResult
    private func retire(_ scene: StudioUIScene) -> Task<Void, Never> {
        scene.stop()
        let id = UUID()
        let task = Task { [weak self] in
            await scene.stopAndWait()
            self?.retiringScenes[id] = nil
        }
        retiringScenes[id] = task
        return task
    }
}

@MainActor
func makeStudioRuntime(
    admitFixture: ((NSDictionary) throws -> WorkerFixtureAdmission?)? = nil,
    fixtureDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) },
    expectedSuite: @escaping () -> String? = {
        ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
    },
    image: UnsafeRawPointer = #dsohandle
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "studio", role: "app", bundle: Bundle(for: BundleAnchor.self), image: image
    ) {
        StudioService(
            runtime: $0, admitFixture: admitFixture, fixtureDefaults: fixtureDefaults,
            expectedSuite: expectedSuite)
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeStudioRuntime()).toOpaque())
        })
}
