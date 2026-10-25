import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithLaTeXExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: LaTeXWorker?
    private var uiModel: LaTeXModel?
    private var settingsTools: LaTeXToolOwner?
    private var engineClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?
    private var suspended = false
    private var suspension: Task<Void, Never>?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            if command == "latex.cli.catalog" {
                return try ExtensionCLICatalog.data(
                    LaTeXCommand.self, owner: "latex", payload: payload, streaming: true)
            }
            if command.hasPrefix("latex.cli.") {
                if self.cliStreams == nil {
                    self.cliStreams = try ExtensionCLIStreams(owner: "latex")
                }
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try LaTeXCLIExecution.stream(
                    streams, operation: command, payload: payload, store: worker.model.store)
            }
            if command == "latex.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    try await LaTeXCLIExecution.run(request, store: worker.model.store))
            }
            if command.hasPrefix("latex.ui.") {
                return try await LaTeXUIBridge.execute(
                    command, payload: payload, model: worker.model)
            }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        commands.suspend()
        suspended = true
        let worker = worker
        let model = uiModel
        let streams = cliStreams
        worker?.cancelPendingWork()
        model?.cancelPendingWork()
        streams?.stop()
        if suspension == nil {
            let retired = Array(uiRetirements.values)
            suspension = Task { [self, worker, model, streams] in
                await worker?.model.drainTools()
                await model?.drainTools()
                await commands.suspendAndWait()
                await worker?.drain()
                await model?.drain()
                await streams?.stopAndWait()
                for task in retired { await task.value }
            }
        }
        let pending = suspension
        Task { [self] in
            await pending?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        suspendCommands(completion: {})
        stopUI()
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        let worker = worker
        Task { [self, worker, streams] in
            await suspension?.value
            await worker?.shutdown()
            await streams?.stopAndWait()
            await commands.shutdownAndWait()
            for task in Array(uiRetirements.values) { await task.value }
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "latex", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !suspended, uiRetirements.isEmpty else { return ["ok": false] as NSDictionary }
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "latex", let client = configuration.engineClient,
                Self.hasEditorResources
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            if input["location"] as? String == "settings" {
                settingsTools = LaTeXToolOwner(remote: LaTeXUIBridge(client: client))
                return ["ok": true] as NSDictionary
            }
            uiModel = LaTeXModel(remote: LaTeXUIBridge(client: client))
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "start":
            guard !suspended else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"],
                Self.hasEditorResources
            else { return ["ok": false] as NSDictionary }
            if worker == nil { worker = LaTeXWorker() }
        case "view":
            if let tools = settingsTools {
                return NSHostingController(
                    rootView: ExtensionPageHost { LaTeXSettings(owner: tools) })
            }
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { LaTeXPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            suspendCommands(completion: {})
            let streams = cliStreams; cliStreams = nil; streams?.stop()
            Task { await streams?.stopAndWait() }
            commands.shutdown()
            let stopping = worker; worker = nil
            Task { await stopping?.shutdown() }
            stopUI()
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private func stopUI() {
        engineClient?.invalidate(); engineClient = nil
        let model = uiModel; uiModel = nil
        let tools = settingsTools; settingsTools = nil
        if let tools {
            let id = UUID()
            uiRetirements[id] = Task { [self, tools] in
                await tools.shutdown()
                uiRetirements[id] = nil
            }
        }
        if let model {
            model.cancelPendingWork()
            let id = UUID()
            uiRetirements[id] = Task { [self, model] in
                await model.shutdown()
                uiRetirements[id] = nil
            }
        }
        TextEditingCommands.shutdown()
    }

    private static var hasEditorResources: Bool {
        guard let editor = LaTeXEditorResources.url, let review = LaTeXEditorResources.reviewURL,
            let editorHTML = try? String(contentsOf: editor, encoding: .utf8),
            let reviewHTML = try? String(contentsOf: review, encoding: .utf8),
            let editorScript = try? Data(
                contentsOf: editor.deletingLastPathComponent().appendingPathComponent("editor.js")),
            let reviewScript = try? Data(
                contentsOf: review.deletingLastPathComponent().appendingPathComponent("review.js")),
            FileManager.default.fileExists(
                atPath: review.deletingLastPathComponent().appendingPathComponent("review.css").path
            )
        else { return false }
        return editorHTML.contains("editor.js") && reviewHTML.contains("review.js")
            && editorScript.count > 100_000 && reviewScript.count > 10_000
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
