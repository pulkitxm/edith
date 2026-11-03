import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class DownloadsExtensionService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var worker: DownloadsWorker?
    private var uiModel: YoutubeDownloader?
    private var uiSettings = false
    private var engineClient: ExtensionEngineClient?
    private var surface: DownloadsSurface?
    private var cliStreams: ExtensionCLIStreams?
    private var suspended:
        (
            worker: DownloadsWorker?, model: YoutubeDownloader?, streams: ExtensionCLIStreams?,
            cancellation: Task<Void, Never>
        )?

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var isRunning: Bool { worker != nil }
    var preparesForDisable: Bool { true }

    func prepareDisable() async throws { await runtime.stop() }

    func start() -> Bool {
        if worker == nil {
            let value = DownloadsWorker()
            worker = value
            surface = DownloadsSurface(worker: value)
        }
        return true
    }

    func synchronize() { worker?.downloader.checkAvailability() }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker else { throw ExtensionPeerError.unavailable }
        if command == "downloads.cli.catalog" {
            return try DownloadsCLIAliases.expanded(
                ExtensionCLICatalog.data(
                    DownloadCommand.self, owner: "downloads", payload: payload,
                    streaming: true))
        }
        if command.hasPrefix("downloads.cli.") {
            if cliStreams == nil {
                cliStreams = try ExtensionCLIStreams(owner: "downloads")
            }
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
            return try await DownloadsCLIExecution.stream(
                streams, operation: command, payload: payload, worker: worker.queue)
        }
        if command == "downloads.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(
                try await DownloadsCLIExecution.run(request, worker: worker.queue))
        }
        if command.hasPrefix("downloads.ui.") {
            return try await DownloadsUIBridge.execute(
                command, payload: payload, worker: worker)
        }
        if command.hasPrefix("surface.") {
            guard let surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        return try await worker.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard engineClient == nil, let client = configuration.engineClient else { return false }
        engineClient = client
        uiSettings = configuration.isSettings
        uiModel = YoutubeDownloader(
            client: DownloadsClient(client: client), remote: DownloadsUIBridge(client: client))
        TextEditingCommands.install()
        return true
    }

    func view(for presentation: UUID) -> NSViewController? {
        guard let model = uiModel else { return nil }
        let settings = uiSettings
        return NSHostingController(
            rootView: ExtensionPageHost {
                if settings {
                    DownloadsSettings(downloader: model)
                } else {
                    DownloadSheet(isPage: true, downloader: model)
                }
            })
    }

    func stopUI() -> [Task<Void, Never>] {
        engineClient?.invalidate()
        engineClient = nil
        uiSettings = false
        let model = uiModel
        uiModel = nil
        var retirements: [Task<Void, Never>] = []
        if let model {
            model.cancelPendingWork()
            retirements.append(
                Task {
                    await model.shutdown()
                    await model.tools.shutdown()
                })
        }
        ExtensionUIResources.cleanup(of: runtime, key: "textEditing") {
            TextEditingCommands.shutdown()
        }
        return retirements
    }

    func cancelPendingWork() {
        let worker = worker
        let model = uiModel
        let streams = cliStreams
        model?.cancelPendingWork()
        streams?.stop()
        let cancellation = Task {
            await worker?.cancelPendingWork()
            await model?.tools.shutdown()
        }
        suspended = (worker, model, streams, cancellation)
    }

    func drain() async {
        guard let suspended else { return }
        await suspended.cancellation.value
        await suspended.worker?.drain()
        await suspended.model?.drain()
        await suspended.streams?.stopAndWait()
    }

    func teardown() async {
        let retirements = stopUI()
        let streams = cliStreams
        cliStreams = nil
        streams?.stop()
        let stopping = worker
        worker = nil
        surface = nil
        await stopping?.shutdown()
        await streams?.stopAndWait()
        for task in retirements { await task.value }
        InputFocus.uninstall()
    }
}

@MainActor
func makeDownloadsRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "downloads", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { DownloadsExtensionService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeDownloadsRuntime()).toOpaque())
        })
}
