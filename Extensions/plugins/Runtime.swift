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
    private var fixture: PluginsFixtureTools?
    private let admitFixture: (NSDictionary) throws -> WorkerFixtureAdmission?
    private let fixtureDefaults: (String) -> UserDefaults?

    override convenience init() {
        self.init(admitFixture: {
            try WorkerFixtureAdmission.current(
                extensionID: "plugins", context: $0,
                roleBundle: Bundle(for: ExtensionRuntime.self))
        })
    }

    init(
        admitFixture: @escaping (NSDictionary) throws -> WorkerFixtureAdmission?,
        fixtureDefaults: @escaping (String) -> UserDefaults? = { UserDefaults(suiteName: $0) }
    ) {
        self.admitFixture = admitFixture
        self.fixtureDefaults = fixtureDefaults
        super.init()
    }

    private var model: SkillsModel?
    private var uiModel: SkillsModel?
    private var engineClient: ExtensionEngineClient?
    private var surface: PluginsSurface?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let model = self.model, !model.isStopped else {
                throw ExtensionPeerError.unavailable
            }
            if self.fixture != nil && !["surface.snapshot", "surface.perform"].contains(command) {
                throw ExtensionPeerError.unavailable
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
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        Task {
            await model?.shutdown()
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            completion()
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
            do {
                guard try admitFixture(input) == nil else { return ["ok": false] as NSDictionary }
            } catch { return ["ok": false] as NSDictionary }
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "plugins", let client = configuration.engineClient,
                DocumentRenderer.isAvailable
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            uiModel = SkillsModel(remote: PluginsUIBridge(client: client))
            TextEditingCommands.install()
        case "stopUI":
            let hadUI = engineClient != nil || uiModel != nil
            engineClient?.invalidate(); engineClient = nil
            let model = uiModel; uiModel = nil
            Task { await model?.shutdown() }
            if hadUI { TextEditingCommands.shutdown() }
        case "start":
            guard let suite = input["defaultsSuite"] as? String
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
                        let tools = try PluginsFixtureTools(admission: admission)
                        guard let defaults = fixtureDefaults(suite) else {
                            return ["ok": false] as NSDictionary
                        }
                        model = tools.makeModel(defaults: defaults)
                        fixture = tools
                    } else {
                        guard DocumentRenderer.isAvailable else {
                            return ["ok": false] as NSDictionary
                        }
                        model = SkillsModel()
                    }
                }
            } catch { return ["ok": false] as NSDictionary }
            if let model, surface == nil {
                surface =
                    fixture == nil
                    ? PluginsSurface(model: model)
                    : PluginsSurface(model: model, hidden: { false })
            }
            if fixture == nil { TextEditingCommands.install() }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { PluginsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            let streams = cliStreams; cliStreams = nil; streams?.stop()
            Task { await streams?.stopAndWait() }
            commands.shutdown()
            let stopping = model; model = nil; surface = nil
            Task { await stopping?.shutdown() }
            if fixture == nil && stopping != nil {
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
