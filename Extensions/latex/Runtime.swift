import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithLaTeXExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: LaTeXWorker?
    private var uiModel: LaTeXModel?
    private var engineClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
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

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        stopUI()
        let streams = cliStreams; cliStreams = nil; streams?.stop()
        commands.shutdown()
        Task {
            await worker?.shutdown()
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
                "id": "latex", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "latex", let client = configuration.engineClient,
                Self.hasEditorResources
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            uiModel = LaTeXModel(remote: LaTeXUIBridge(client: client))
            TextEditingCommands.install()
        case "stopUI": stopUI()
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                Self.hasEditorResources
            else { return ["ok": false] as NSDictionary }
            if worker == nil { worker = LaTeXWorker() }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { LaTeXPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
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
        Task { await model?.shutdown() }
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
