import Darwin
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithQuinjetExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var uiClient: ExtensionEngineClient?
    private var settingsModel: QuinjetSettingsModel?
    private var uiLocation: String?
    private var uiModel: QuinjetPageModel?
    private var uiController: NSViewController?
    private var worker: QuinjetWorker?
    private var surface: QuinjetSurface?
    private var startup: Task<Void, Never>?
    private var draining = false
    private var uiStops: [UUID: Task<Void, Never>] = [:]
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        _ = commands.suspend()
        draining = true
        QuinjetWorkOwnership.beginSuspension()
        retireUI()
        let startup = startup, worker = worker
        startup?.cancel()
        worker?.beginSuspension()
        Task { [self, startup, worker] in
            _ = await commands.suspendAndWait()
            await startup?.value
            await worker?.cancelPendingWork()
            for task in Array(uiStops.values) { await task.value }
            await QuinjetWorkOwnership.shutdown()
            completion()
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        draining = true
        QuinjetWorkOwnership.beginSuspension()
        retireUI()
        startup?.cancel()
        commands.shutdown()
        let startup = startup, worker = worker
        worker?.beginSuspension()
        Task { [self, startup, worker] in
            await worker?.cancelPendingWork()
            await commands.shutdownAndWait()
            await startup?.value
            await worker?.shutdown()
            self.worker = nil
            surface = nil
            self.startup = nil
            for task in Array(uiStops.values) { await task.value }
            await QuinjetWorkOwnership.shutdown()
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
            guard !draining, uiStops.isEmpty, worker == nil,
                let location = input["location"] as? String,
                ["main", "settings"].contains(location),
                location != "settings" || input["section"] as? String == "extension",
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "quinjet",
                let rawID = input["presentationID"] as? String,
                let presentationID = UUID(uuidString: rawID),
                location == "settings" || configuration.engineClient != nil
            else { return ["ok": false] as NSDictionary }
            retireUI()
            uiClient = configuration.engineClient
            uiLocation = location
            if location == "settings" {
                let model: QuinjetSettingsModel
                if let client = configuration.engineClient {
                    model = QuinjetSettingsModel(client: client)
                } else {
                    model = QuinjetSettingsModel { _, _ in throw ExtensionPeerError.unavailable }
                }
                settingsModel = model
                uiModel = nil
                uiController = NSHostingController(
                    rootView: ExtensionPageHost {
                        QuinjetSettingsPage(model: model)
                    })
                return ["ok": true] as NSDictionary
            }
            guard let client = configuration.engineClient else {
                return ["ok": false] as NSDictionary
            }
            let model = QuinjetPageModel(uiClient: .init(client: client))
            model.terminalUI = OwnedTerminalUIPresentation(
                id: presentationID,
                holders: { [weak model] in model?.tabs.map(\.holder) ?? [] },
                action: { [weak model] in model?.terminalUIAction($0) ?? false },
                paneAction: { [weak model] action, holder in
                    guard let model, model.selectedTab?.holder === holder else { return }
                    model.terminalPaneAction(action)
                }, close: { [weak model] in model?.stopRendering() })
            uiModel = model
            uiController = NSHostingController(
                rootView: ExtensionPageHost {
                    QuinjetPage(model: model)
                        .environment(\.terminalLaunchEnabled, true)
                })
        case "terminalUI", "terminalUIStatus":
            guard let binding = uiModel?.terminalUI else { return ["ok": false] as NSDictionary }
            return binding.execute(input)
        case "stopUI": retireUI()
        case "start":
            guard !draining, uiLocation == nil, !ExtensionHostRole.isInterfaceProcess,
                let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            let created = QuinjetWorker()
            worker = created
            surface = QuinjetSurface(worker: created)
            startup = Task { await created.start() }
        case "view":
            if input["location"] as? String == uiLocation, let uiController { return uiController }
            return ["ok": false] as NSDictionary
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
        case "stop": prepareToStop(completion: {})
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }
    private func retireUI() {
        let model = uiModel, settings = settingsModel, client = uiClient
        model?.stopRendering()
        settings?.shutdown()
        uiModel = nil; settingsModel = nil; uiClient = nil; uiLocation = nil; uiController = nil
        if model != nil || settings != nil {
            let id = UUID()
            uiStops[id] = Task { [self, model, settings, client] in
                defer { client?.invalidate(); uiStops[id] = nil }
                await model?.shutdown()
                await settings?.shutdownAndWait()
            }
        } else {
            client?.invalidate()
        }
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
        if let root = ExtensionEnvironment.values["EDITH_EXTENSION_FIXTURE_HOME"] {
            let receipt = try JSONSerialization.data(withJSONObject: [
                "pid": getpid(), "parent": getppid(), "group": getpgrp(),
                "owner": Int32(
                    ExtensionEnvironment.values["EDITH_EXTENSION_NATIVE_PARENT"] ?? "")
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
