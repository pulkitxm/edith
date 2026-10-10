import AppKit
import EdithExtensionSupport
import EdithExtensionCommands
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithDownloadsExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: DownloadsWorker?
    private var uiModel: YoutubeDownloader?
    private var engineClient: ExtensionEngineClient?
    private var surface: DownloadsSurface?
    private let commands = ExtensionCommandRegistry()
    private var stopped = false
    private var activeCalls = 0
    private var stoppingTask: Task<Void, Never>?

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, !self.stopped, let worker = self.worker else {
                throw ExtensionPeerError.unavailable
            }
            self.activeCalls += 1
            defer { self.activeCalls -= 1 }
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
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await worker.execute(command, payload: payload)
        }
    }
    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        if let stoppingTask {
            Task {
                await stoppingTask.value; completion()
            }; return
        }
        stopped = true
        commands.shutdown()
        let task = Task {
            await worker?.shutdown()
            while activeCalls > 0 { await Task.yield() }
        }
        stoppingTask = task
        Task {
            await task.value; completion()
        }
    }
    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        prepareToStop { completion(nil) }
    }
    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "downloads", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard engineClient == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "downloads", let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            engineClient = client
            uiModel = YoutubeDownloader(
                client: DownloadsClient(client: client), remote: DownloadsUIBridge(client: client))
            TextEditingCommands.install()
        case "stopUI":
            engineClient?.invalidate(); engineClient = nil
            let model = uiModel; uiModel = nil
            Task {
                await model?.shutdown(); await model?.tools.shutdown()
            }
            TextEditingCommands.shutdown()
        case "start":
            guard !stopped, let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if worker == nil {
                let value = DownloadsWorker()
                worker = value
                surface = DownloadsSurface(worker: value)
                TextEditingCommands.install()
            }
        case "view":
            guard let model = uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    if input["location"] as? String == "settings" {
                        DownloadsSettings(downloader: model)
                    } else {
                        DownloadSheet(isPage: true, downloader: model)
                    }
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": worker?.downloader.checkAvailability()
        case "stop":
            commands.shutdown()
            worker = nil
            surface = nil
            TextEditingCommands.shutdown()
            InputFocus.uninstall()
        case "status": return ["ok": true, "running": !stopped && worker != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let runtime = MainActor.assumeIsolated { ExtensionRuntime() }
    return Unmanaged.passRetained(runtime).toOpaque()
}
