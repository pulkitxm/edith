#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import EdithExtensionDocuments
import Foundation
import SwiftUI

@MainActor
final class PluginsService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var fixtureRejected = false
    private let admitOrdinaryContext: (NSDictionary) throws -> WorkerFixtureAdmission?

    init(
        runtime: ExtensionServiceRuntime,
        admitOrdinaryContext: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? =
            PluginsService.admitOrdinaryContext
    ) {
        self.runtime = runtime
        self.admitOrdinaryContext = admitOrdinaryContext
    }

    static func admitOrdinaryContext(_ context: NSDictionary) throws -> WorkerFixtureAdmission? {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            context["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "plugins", context: context,
            roleBundle: Bundle(for: PluginsService.self))
    }

    private var model: SkillsModel?
    private var uiModel: SkillsModel?
    private var engineClient: ExtensionEngineClient?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var suspendedUIModels: [SkillsModel] = []
    private var surface: PluginsSurface?
    private var cliStreams: ExtensionCLIStreams?

    var isRunning: Bool { model != nil && !(runtime.isSuspended || runtime.isStopping) }
    var allowsUIDuringRetirement: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !fixtureRejected else { return false }
        guard let suite = context.input["defaultsSuite"] as? String else { return false }
        do {
            let admission = try admitOrdinaryContext(context.input)
            if model == nil {
                if let admission {
                    guard let defaults = UserDefaults(suiteName: suite) else {
                        throw WorkerFixtureError.invalid
                    }
                    model = PluginsFixtureTools.makeAdmittedModel(
                        defaults: defaults, dataDirectory: admission.dataDirectory, agents: [])
                } else {
                    guard DocumentRenderer.isAvailable else { return false }
                    model = SkillsModel()
                }
            }
        } catch {
            fixtureRejected = true
            return false
        }
        if let model, surface == nil { surface = PluginsSurface(model: model) }
        TextEditingCommands.install()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let model = self.model, !model.isStopped else {
            throw ExtensionPeerError.unavailable
        }
        if command == "plugins.cli.catalog" {
            return try ExtensionCLICatalog.data(
                SkillsCommand.self, owner: "plugins", payload: payload, streaming: true)
        }
        if command.hasPrefix("plugins.cli.") {
            if self.cliStreams == nil {
                self.cliStreams = try ExtensionCLIStreams(owner: "plugins")
            }
            guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
            return try await SkillsCLIExecution.stream(
                streams, operation: command, payload: payload, model: model)
        }
        if command == "plugins.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await SkillsCLIExecution.run(request, model: model))
        }
        if command.hasPrefix("plugins.ui.") {
            return try await PluginsUIBridge.execute(command, payload: payload, model: model)
        }
        guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
        return try await surface.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !fixtureRejected, engineClient == nil else { return false }
        do { _ = try admitOrdinaryContext(configuration.input) } catch {
            fixtureRejected = true
            return false
        }
        guard let client = configuration.engineClient, DocumentRenderer.isAvailable else {
            return false
        }
        uiModel = SkillsModel(remote: PluginsUIBridge(client: client))
        engineClient = client
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { PluginsPage(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        releaseUI(preservingMetadata: false).map { [$0] } ?? []
    }

    func cancelPendingWork() {
        releaseUI(preservingMetadata: true)
        cliStreams?.stop()
        model?.stop()
    }

    func drain() async {
        await model?.stopAndWait()
        await cliStreams?.stopAndWait()
        while let task = uiDrains.values.first { await task.value }
    }

    func teardown() async {
        let ordinaryModel = model != nil
        await model?.shutdown()
        for owner in suspendedUIModels { await owner.shutdown() }
        if ordinaryModel { SkillBrand.shutdown() }
        if ordinaryModel || !suspendedUIModels.isEmpty {
            ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
        }
        suspendedUIModels.removeAll()
        model = nil
        surface = nil
        cliStreams = nil
    }

    @discardableResult
    private func releaseUI(preservingMetadata: Bool) -> Task<Void, Never>? {
        let hadUI = engineClient != nil || uiModel != nil
        engineClient?.invalidate()
        engineClient = nil
        let stoppingModel = uiModel
        uiModel = nil
        stoppingModel?.stop()
        var retirement: Task<Void, Never>?
        if let stoppingModel {
            if preservingMetadata { suspendedUIModels.append(stoppingModel) }
            let id = UUID()
            let task = Task { [self] in
                if preservingMetadata {
                    await stoppingModel.stopAndWait()
                } else {
                    await stoppingModel.shutdown()
                }
                uiDrains[id] = nil
            }
            uiDrains[id] = task
            retirement = task
        }
        if hadUI, !preservingMetadata {
            ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
        }
        return retirement
    }
}

@MainActor
func makePluginsRuntime(
    admitOrdinaryContext: @escaping (NSDictionary) throws -> WorkerFixtureAdmission? =
        PluginsService.admitOrdinaryContext
) -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "plugins", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { PluginsService(runtime: $0, admitOrdinaryContext: admitOrdinaryContext) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makePluginsRuntime()).toOpaque())
        })
}
