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
    #if EDITH_FUNCTIONAL_FIXTURE
    private var fixture: WorkerFixtureEngineAdmission?
    private var fixtureContext: NSDictionary?
    private var fixturePolicy: PluginsFixturePolicy?
    #endif
    private var fixtureTerminated = false
    private var fixtureRejected = false
    #if EDITH_FUNCTIONAL_FIXTURE
    private let admitFixture: (NSDictionary) throws -> WorkerFixtureEngineAdmission?
    private let fixtureDefaults: (String) -> UserDefaults?

    override convenience init() {
        self.init(admitFixture: {
            try WorkerFixtureEngineAdmission.current(
                extensionID: "plugins", context: $0,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        })
    }

    init(
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureEngineAdmission?,
        fixtureDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) {
        self.admitFixture = admitFixture
        self.fixtureDefaults = fixtureDefaults
        super.init()
    }

    #endif
    #if !EDITH_FUNCTIONAL_FIXTURE
    private let validateOrdinaryContext: (NSDictionary) throws -> Void

    override convenience init() { self.init(validateOrdinaryContext: Self.validateOrdinaryContext) }

    init(validateOrdinaryContext: @escaping (NSDictionary) throws -> Void) {
        self.validateOrdinaryContext = validateOrdinaryContext
        super.init()
    }

    private static func validateOrdinaryContext(_ context: NSDictionary) throws {
        guard ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            context["hostedFunctionalFixture"] == nil,
            try WorkerFixtureAdmission.current(
                extensionID: "plugins", context: context,
                roleBundle: Bundle(for: ExtensionRuntime.self)) == nil
        else { throw WorkerFixtureError.invalid }
    }
    #endif
    private var fixtureActive = false

    private var model: SkillsModel?
    private var uiModel: SkillsModel?
    private var engineClient: ExtensionEngineClient?
    #if EDITH_FUNCTIONAL_FIXTURE
    private var uiAdmission: WorkerFixtureUIAdmission?
    #endif
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
            #if EDITH_FUNCTIONAL_FIXTURE
            if self.fixture != nil {
                guard let policy = self.fixturePolicy else { throw ExtensionPeerError.unavailable }
                do {
                    guard let token = (request["token"] as? String).flatMap(UUID.init(uuidString:)),
                        let fixture
                    else { throw WorkerFixtureError.invalid }
                    try PluginsFixturePolicy.validate(
                        command, payload: payload, skillIDs: Set(model.skills.map(\.id)),
                        agentIDs: Set(model.agents.map(\.id)),
                        validateSurface: PluginsSurface.validate)
                    let ticket = try fixture.beginRequest(
                        token: token, operation: command, payload: payload)
                    defer { fixture.cancelRequest(ticket) }
                    let response = try await policy.perform(
                        command, payload: payload, skillIDs: Set(model.skills.map(\.id)),
                        agentIDs: Set(model.agents.map(\.id))
                    ) {
                        if command == "plugins.ui.action" {
                            return try await PluginsUIBridge.execute(
                                command, payload: payload, model: model)
                        }
                        guard let surface = self.surface else {
                            throw ExtensionPeerError.unavailable
                        }
                        return try await surface.execute(command, payload: payload)
                    }
                    try fixture.completeRequest(ticket)
                    return response
                } catch PluginsFixturePolicyError.invalid {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            #endif
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
        #if EDITH_FUNCTIONAL_FIXTURE
        fixturePolicy?.stop()
        #endif
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
            if ordinaryModel || !suspendedUIModels.isEmpty { TextEditingCommands.shutdown() }
            suspendedUIModels.removeAll()
            model = nil; surface = nil; cliStreams = nil
            #if EDITH_FUNCTIONAL_FIXTURE
            fixture = nil; fixtureContext = nil; fixturePolicy = nil
            #endif
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
        #if EDITH_FUNCTIONAL_FIXTURE
        uiAdmission = nil
        #endif
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
        if hadUI, !preservingMetadata { TextEditingCommands.shutdown() }
    }

    #if EDITH_FUNCTIONAL_FIXTURE
    private func requireCurrentFixture() throws {
        guard !fixtureTerminated, !fixtureRejected, !stopping, let fixture
        else { throw WorkerFixtureError.invalid }
        try fixture.requireCurrent()
    }

    private func invokeUI(
        _ operation: String, payload: Data, generation: UUID,
        client: ExtensionEngineClient, admission: WorkerFixtureUIAdmission
    ) async throws -> Data {
        guard !stopping, !fixtureRejected, uiGeneration == generation,
            engineClient === client, uiAdmission === admission, let uiModel, !uiModel.isStopped
        else { throw WorkerFixtureError.invalid }
        try Task.checkCancellation()
        try admission.requireCurrent()
        try PluginsFixturePolicy.validate(
            operation, payload: payload, skillIDs: Set(uiModel.skills.map(\.id)),
            agentIDs: Set(uiModel.agents.map(\.id)), validateSurface: PluginsSurface.validate)
        let response = try await client.invoke(operation, payload: payload)
        try Task.checkCancellation()
        guard !stopping, !fixtureRejected, uiGeneration == generation,
            engineClient === client, uiAdmission === admission
        else { throw WorkerFixtureError.invalid }
        try admission.requireCurrent()
        return response
    }

    #endif
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
            #if EDITH_FUNCTIONAL_FIXTURE
            let admission: WorkerFixtureUIAdmission?
            do {
                admission = try WorkerFixtureUIAdmission.current(
                    extensionID: "plugins", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                try admission?.requireCurrent()
            } catch { return ["ok": false] as NSDictionary }
            #else
            do { try validateOrdinaryContext(input) } catch {
                fixtureRejected = true; return ["ok": false] as NSDictionary
            }
            #endif
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "plugins", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            let generation = UUID()
            #if EDITH_FUNCTIONAL_FIXTURE
            if let admission {
                guard let suite = input["defaultsSuite"] as? String,
                    let defaults = fixtureDefaults(suite)
                else { return ["ok": false] as NSDictionary }
                do { try admission.requireCurrent() } catch { return ["ok": false] as NSDictionary }
                let bridge = PluginsUIBridge(invoke: { [weak self] operation, payload in
                    guard let self else { throw WorkerFixtureError.invalid }
                    return try await self.invokeUI(
                        operation, payload: payload, generation: generation,
                        client: client, admission: admission)
                })
                uiModel = PluginsFixtureTools.makeAdmittedModel(
                    defaults: defaults,
                    dataDirectory: URL(fileURLWithPath: admission.descriptor.dataDirectory),
                    agents: [], remote: bridge)
            } else {
                guard DocumentRenderer.isAvailable else { return ["ok": false] as NSDictionary }
                uiModel = SkillsModel(remote: PluginsUIBridge(client: client))
            }
            #else
            guard DocumentRenderer.isAvailable else { return ["ok": false] as NSDictionary }
            uiModel = SkillsModel(remote: PluginsUIBridge(client: client))
            #endif
            engineClient = client; uiGeneration = generation
            #if EDITH_FUNCTIONAL_FIXTURE
            uiAdmission = admission
            #endif
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "start":
            guard !stopping, !fixtureTerminated, !fixtureRejected else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String
            else { return ["ok": false] as NSDictionary }
            do {
                #if EDITH_FUNCTIONAL_FIXTURE
                let admission = try admitFixture(input)
                if let fixture {
                    guard let admission, admission.descriptor == fixture.descriptor,
                        suite == fixtureContext?["defaultsSuite"] as? String
                    else { throw WorkerFixtureError.invalid }
                }
                guard
                    admission != nil
                        || suite
                            == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                if model == nil {
                    if let admission {
                        guard let identifier = input["hostIdentifier"] as? String,
                            suite == identifier + ".extensions.plugins",
                            admission.descriptor.inputs.count == 1,
                            admission.descriptor.inputs[0].name == "agents",
                            admission.descriptor.inputs[0].maximumBytes <= 8192,
                            admission.descriptor.outputs.isEmpty
                        else { throw WorkerFixtureError.invalid }
                        let agents = try PluginsFixtureTools.admittedAgents(
                            admission.readInput(named: "agents"))
                        fixture = admission
                        fixtureActive = true
                        fixtureContext = input.copy() as? NSDictionary
                        fixturePolicy = try PluginsFixturePolicy(
                            validateSurface: PluginsSurface.validate,
                            requireCurrent: { [weak self] in
                                guard let self else { throw WorkerFixtureError.invalid }
                                try self.requireCurrentFixture()
                            })
                        guard let defaults = fixtureDefaults(suite) else {
                            throw WorkerFixtureError.invalid
                        }
                        try requireCurrentFixture()
                        model = PluginsFixtureTools.makeAdmittedModel(
                            defaults: defaults,
                            dataDirectory: URL(fileURLWithPath: admission.descriptor.dataDirectory),
                            agents: agents)
                        try requireCurrentFixture()
                    } else {
                        guard DocumentRenderer.isAvailable else {
                            return ["ok": false] as NSDictionary
                        }
                        model = SkillsModel()
                    }
                }
                #else
                try validateOrdinaryContext(input)
                guard suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
                else { return ["ok": false] as NSDictionary }
                if model == nil {
                    guard DocumentRenderer.isAvailable else { return ["ok": false] as NSDictionary }
                    model = SkillsModel()
                }
                #endif
            } catch {
                fixtureRejected = true
                #if EDITH_FUNCTIONAL_FIXTURE
                fixturePolicy?.stop()
                #endif
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
            #if EDITH_FUNCTIONAL_FIXTURE
            do { try uiAdmission?.requireCurrent() } catch { return ["ok": false] as NSDictionary }
            #endif
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
