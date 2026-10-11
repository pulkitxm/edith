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
    private var fixture: WorkerFixtureEngineAdmission?
    private var fixtureContext: NSDictionary?
    private var fixturePolicy: PluginsFixturePolicy?
    private var fixtureTerminated = false
    private var fixtureRejected = false
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

    private var model: SkillsModel?
    private var uiModel: SkillsModel?
    private var engineClient: ExtensionEngineClient?
    private var uiAdmission: WorkerFixtureUIAdmission?
    private var uiGeneration: UUID?
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var stopping = false
    private var surface: PluginsSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model, !model.isStopped else {
                throw ExtensionPeerError.unavailable
            }
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

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        stopping = true
        fixturePolicy?.stop()
        if fixture != nil { fixtureTerminated = true }
        stopUI()
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        let stoppingModel = model; model = nil; surface = nil
        stoppingModel?.stop()
        commands.shutdown()
        Task {
            await stoppingModel?.shutdown()
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            for task in Array(uiDrains.values) { await task.value }
            completion()
        }
    }

    private func stopUI() {
        let hadUI = engineClient != nil || uiModel != nil
        uiGeneration = nil; uiAdmission = nil
        engineClient?.invalidate(); engineClient = nil
        let stoppingModel = uiModel; uiModel = nil
        stoppingModel?.stop()
        if let stoppingModel {
            let id = UUID()
            uiDrains[id] = Task {
                await stoppingModel.shutdown()
                uiDrains[id] = nil
            }
        }
        if hadUI { TextEditingCommands.shutdown() }
    }

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
            guard !stopping, !fixtureRejected, fixture == nil, engineClient == nil else {
                return ["ok": false] as NSDictionary
            }
            let admission: WorkerFixtureUIAdmission?
            do {
                admission = try WorkerFixtureUIAdmission.current(
                    extensionID: "plugins", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                try admission?.requireCurrent()
            } catch { return ["ok": false] as NSDictionary }
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "plugins", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            let generation = UUID()
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
            engineClient = client; uiGeneration = generation; uiAdmission = admission
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "start":
            guard !stopping, !fixtureTerminated, !fixtureRejected else {
                return ["ok": false] as NSDictionary
            }
            guard let suite = input["defaultsSuite"] as? String
            else { return ["ok": false] as NSDictionary }
            do {
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
            } catch {
                fixtureRejected = true
                fixturePolicy?.stop()
                return ["ok": false] as NSDictionary
            }
            if let model, surface == nil {
                surface =
                    fixture == nil
                    ? PluginsSurface(model: model)
                    : PluginsSurface(model: model, hidden: { false })
            }
            if fixture == nil { TextEditingCommands.install() }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            do { try uiAdmission?.requireCurrent() } catch { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { PluginsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            let ordinaryModel = fixture == nil && model != nil
            prepareToStop(completion: {})
            if ordinaryModel {
                SkillBrand.shutdown()
                TextEditingCommands.shutdown()
            }
            fixture = nil
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
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
