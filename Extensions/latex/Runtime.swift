import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class LaTeXExtensionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: LaTeXWorker?
    private var uiModel: LaTeXModel?
    private var settingsTools: LaTeXToolOwner?
    private var engineClient: ExtensionEngineClient?
    private var cliStreams: ExtensionCLIStreams?

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { worker?.isStopped == false }

    func start() -> Bool {
        guard Self.hasEditorResources else { return false }
        if worker == nil { worker = LaTeXWorker() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker else { throw ExtensionPeerError.unavailable }
        if command == "latex.cli.catalog" {
            return try LaTeXCLIExecution.catalog(payload)
        }
        if command.hasPrefix("latex.cli.") {
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "latex")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
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

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard engineClient == nil, let client = configuration.engineClient,
            Self.hasEditorResources
        else { return false }
        engineClient = client
        if configuration.isSettings {
            settingsTools = LaTeXToolOwner(remote: LaTeXUIBridge(client: client))
            return true
        }
        uiModel = LaTeXModel(remote: LaTeXUIBridge(client: client))
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        if let tools = settingsTools {
            return NSHostingController(
                rootView: ExtensionPageHost { LaTeXSettings(owner: tools) })
        }
        guard let model = uiModel else { return nil }
        return NSHostingController(
            rootView: ExtensionPageHost { LaTeXPage(model: model) })
    }

    func stopUI() -> [Task<Void, Never>] {
        engineClient?.invalidate()
        engineClient = nil
        let model = uiModel
        uiModel = nil
        let tools = settingsTools
        settingsTools = nil
        var retirements: [Task<Void, Never>] = []
        if let tools {
            retirements.append(Task { await tools.shutdown() })
        }
        if let model {
            model.cancelPendingWork()
            retirements.append(Task { await model.shutdown() })
        }
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        return retirements
    }

    func cancelPendingWork() {
        worker?.cancelPendingWork()
        uiModel?.cancelPendingWork()
        cliStreams?.stop()
    }

    func drain() async {
        await worker?.model.drainTools()
        await uiModel?.drainTools()
        await worker?.drain()
        await uiModel?.drain()
        await cliStreams?.stopAndWait()
    }

    func teardown() async {
        let retirements = stopUI()
        let streams = cliStreams
        cliStreams = nil
        streams?.stop()
        let stopping = worker
        worker = nil
        await stopping?.shutdown()
        await streams?.stopAndWait()
        for task in retirements { await task.value }
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

@MainActor
func makeLaTeXRuntime() -> ExtensionServiceRuntime {
    ExtensionServiceRuntime(
        id: "latex", role: "app", bundle: Bundle(for: LaTeXExtensionService.self)
    ) { LaTeXExtensionService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeLaTeXRuntime()).toOpaque())
        })
}
