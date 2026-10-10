import Darwin
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithQuinjetExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var uiClient: ExtensionEngineClient?
    private var uiModel: QuinjetPageModel?
    private var uiController: NSViewController?
    private var worker: QuinjetWorker?
    private var surface: QuinjetSurface?
    private var startup: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            if command == "quinjet.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    await QuinjetCLIExecution.run(request, worker: worker))
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
        startup?.cancel()
        commands.shutdown()
        Task {
            await worker?.cancelPendingWork()
            await commands.shutdownAndWait()
            await startup?.value
            await worker?.shutdown()
            worker = nil
            surface = nil
            startup = nil
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "quinjet", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard worker == nil, input["location"] as? String == "main",
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "quinjet",
                let client = configuration.engineClient
            else { return ["ok": false] as NSDictionary }
            if let previous = uiModel {
                previous.stopRendering(); Task { await previous.shutdown() }
            }
            uiClient?.invalidate()
            uiClient = client
            let model = QuinjetPageModel(uiClient: .init(client: client))
            uiModel = model
            uiController = NSHostingController(
                rootView: ExtensionPageHost {
                    QuinjetPage(model: model)
                        .environment(\.terminalLaunchEnabled, true)
                })
        case "stopUI":
            if let model = uiModel { model.stopRendering(); Task { await model.shutdown() } }
            uiClient?.invalidate()
            uiClient = nil
            uiModel = nil
            uiController = nil
        case "start":
            guard uiModel == nil, Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            let created = QuinjetWorker()
            worker = created
            surface = QuinjetSurface(worker: created)
            startup = Task { await created.start() }
        case "view":
            if let uiController { return uiController }
            return ["ok": false] as NSDictionary
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        case "stop":
            commands.shutdown()
            startup?.cancel()
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
    }
    return UnsafeMutableRawPointer(bitPattern: address)
}

@_cdecl("edith_extension_native_task")
public func runNativeTask(_ bytes: UnsafePointer<UInt8>?, _ count: Int32) -> Int32 {
    guard let bytes, count > 0, count <= 65_536 else { return 1 }
    do {
        if let root = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
            let receipt = try JSONSerialization.data(withJSONObject: [
                "pid": getpid(), "parent": getppid(), "group": getpgrp(),
                "owner": Int32(
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_NATIVE_PARENT"] ?? "")
                    ?? 0,
                "inputTerminal": isatty(STDIN_FILENO), "bytes": count,
            ])
            try receipt.write(
                to: URL(fileURLWithPath: root).appendingPathComponent("quinjet-native-receipt.json")
            )
        }
        try QuinjetPTYBridgeCommand.run(
            encoded: Data(bytes: bytes, count: Int(count)).base64EncodedString())
        return 0
    } catch let error as QuinjetPTYBridgeExit { return error.status } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}
