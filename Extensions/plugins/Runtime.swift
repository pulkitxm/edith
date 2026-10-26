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

@MainActor @objc(EdithPluginsExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var fixtureTerminated = false
    private var fixtureRejected = false
    private let admitOrdinaryContext: (NSDictionary) throws -> WorkerFixtureAdmission?

    override convenience init() { self.init(admitOrdinaryContext: Self.admitOrdinaryContext) }

    init(admitOrdinaryContext: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?) {
        self.admitOrdinaryContext = admitOrdinaryContext
        super.init()
    }

    private static func admitOrdinaryContext(_ context: NSDictionary) throws
        -> WorkerFixtureAdmission?
    {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            context["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "plugins", context: context,
            roleBundle: Bundle(for: ExtensionRuntime.self))
    }
    private var fixtureActive = false

    private var model: SkillsModel?
    private var uiModel: SkillsModel?
    private var engineClient: ExtensionEngineClient?
    private var uiGeneration: UUID?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var stopping = false
    private var suspensionTask: Task<Void, Never>?
    private var suspensionFinished = false
    private var suspensionCompletions: [() -> Void] = []
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private var shutdownCompletions: [() -> Void] = []
    private var suspendedUIModels: [SkillsModel] = []
    private var surface: PluginsSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model, !model.isStopped else {
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
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        if suspensionFinished { completion(); return }
        suspensionCompletions.append(completion)
        guard suspensionTask == nil else { return }
        stopping = true
        commands.suspend()
        if fixtureActive { fixtureTerminated = true }
        stopUI(preservingMetadata: true)
        let streams = cliStreams
        let stoppingModel = model
        streams?.stop()
        stoppingModel?.stop()
        suspensionTask = Task {
            await commands.suspendAndWait()
            await stoppingModel?.stopAndWait()
            await streams?.stopAndWait()
            for task in Array(uiDrains.values) { await task.value }
            suspensionFinished = true
            let completions = suspensionCompletions
            suspensionCompletions.removeAll()
            for completion in completions { completion() }
            suspensionTask = nil
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        if shutdownFinished { completion(); return }
        shutdownCompletions.append(completion)
        guard shutdownTask == nil else { return }
        let ordinaryModel = !fixtureActive && model != nil
        suspendCommands(completion: {})
        commands.shutdown()
        let suspending = suspensionTask
        let stoppingModel = model
        shutdownTask = Task {
            await suspending?.value
            await stoppingModel?.shutdown()
            for owner in suspendedUIModels { await owner.shutdown() }
            await commands.shutdownAndWait()
            if ordinaryModel { SkillBrand.shutdown() }
            if ordinaryModel || !suspendedUIModels.isEmpty {
                ExtensionUIResources.cleanup(of: self, key: "textEditing") {
                    TextEditingCommands.shutdown()
                }
            }
            suspendedUIModels.removeAll()
            model = nil; surface = nil; cliStreams = nil
            fixtureActive = false
            shutdownFinished = true
            let completions = shutdownCompletions
            shutdownCompletions.removeAll()
            for completion in completions { completion() }
            shutdownTask = nil
        }
    }

    private func stopUI(preservingMetadata: Bool = false) {
        let hadUI = engineClient != nil || uiModel != nil
        uiGeneration = nil
        engineClient?.invalidate(); engineClient = nil
        let stoppingModel = uiModel; uiModel = nil
        stoppingModel?.stop()
        if let stoppingModel {
            if preservingMetadata { suspendedUIModels.append(stoppingModel) }
            let id = UUID()
            uiDrains[id] = Task {
                if preservingMetadata {
                    await stoppingModel.stopAndWait()
                } else {
                    await stoppingModel.shutdown()
                }
                uiDrains[id] = nil
            }
        }
        if hadUI, !preservingMetadata {
            ExtensionUIResources.cleanup(of: self, key: "textEditing") {
                TextEditingCommands.shutdown()
            }
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "plugins", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !stopping, !fixtureRejected, !fixtureActive, engineClient == nil else {
                return ["ok": false] as NSDictionary
            }
            do { _ = try admitOrdinaryContext(input) } catch {
                fixtureRejected = true; return ["ok": false] as NSDictionary
            }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "plugins", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            let generation = UUID()
            guard DocumentRenderer.isAvailable else { return ["ok": false] as NSDictionary }
            uiModel = SkillsModel(remote: PluginsUIBridge(client: client))
            engineClient = client; uiGeneration = generation
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "start":
            guard !stopping, !fixtureTerminated, !fixtureRejected else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String
            else { return ["ok": false] as NSDictionary }
            do {
                let admission = try admitOrdinaryContext(input)
                guard suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                if model == nil {
                    if let admission {
                        guard let defaults = UserDefaults(suiteName: suite) else {
                            throw WorkerFixtureError.invalid
                        }
                        model = PluginsFixtureTools.makeAdmittedModel(
                            defaults: defaults, dataDirectory: admission.dataDirectory, agents: [])
                    } else {
                        guard DocumentRenderer.isAvailable else {
                            return ["ok": false] as NSDictionary
                        }
                        model = SkillsModel()
                    }
                }
            } catch {
                fixtureRejected = true
                return ["ok": false] as NSDictionary
            }
            if let model, surface == nil {
                surface =
                    !fixtureActive
                    ? PluginsSurface(model: model)
                    : PluginsSurface(model: model, hidden: { false })
            }
            if !fixtureActive { TextEditingCommands.install() }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { PluginsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": model != nil && !stopping] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
