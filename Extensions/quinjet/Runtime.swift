import AppKit
import Darwin
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class QuinjetService: ExtensionService {
    private var uiClient: ExtensionEngineClient?
    private var settingsModel: QuinjetSettingsModel?
    private var uiModel: QuinjetPageModel?
    private var uiController: NSViewController?
    private var uiLocation: String?
    private var worker: QuinjetWorker?
    private var surface: QuinjetSurface?
    private var startup: Task<Void, Never>?
    private var uiStops: [UUID: Task<Void, Never>] = [:]

    var isRunning: Bool { worker?.isStopped == false }

    func start() -> Bool {
        guard uiController == nil, !ExtensionHostRole.isInterfaceProcess else { return false }
        guard worker == nil else { return true }
        let created = QuinjetWorker()
        worker = created
        surface = QuinjetSurface(worker: created)
        startup = Task { await created.start() }
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let worker else { throw ExtensionPeerError.unavailable }
        await startup?.value
        if command == "quinjet.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            return try JSONEncoder().encode(await QuinjetCLIExecution.run(request, worker: worker))
        }
        if command.hasPrefix("surface.") {
            guard let surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
        return try await worker.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard worker == nil, let location = configuration.location,
            ["main", "settings"].contains(location),
            location != "settings" || configuration.section == "extension",
            location == "settings" || configuration.engineClient != nil
        else { return false }
        if configuration.isSettings {
            retireUI()
            uiClient = configuration.engineClient
            uiLocation = location
            let model: QuinjetSettingsModel
            if let client = configuration.engineClient {
                model = QuinjetSettingsModel(client: client)
            } else {
                model = QuinjetSettingsModel { _, _ in throw ExtensionPeerError.unavailable }
            }
            settingsModel = model
            uiController = NSHostingController(
                rootView: ExtensionPageHost {
                    QuinjetSettingsPage(model: model)
                })
            return true
        }
        guard let client = configuration.engineClient else { return false }
        retireUI()
        uiClient = client
        uiLocation = location
        let model = QuinjetPageModel(uiClient: .init(client: client))
        model.terminalUI = OwnedTerminalUIPresentation(
            id: client.presentationID,
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
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard context.input["location"] as? String == uiLocation else { return nil }
        return view(for: presentation)
    }

    func view(for presentation: UUID) -> NSViewController? {
        if let client = uiClient, client.presentationID != presentation { return nil }
        return uiController
    }

    func stopUI() -> [Task<Void, Never>] {
        retireUI().map { [$0] } ?? []
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "terminalUI" || operation == "terminalUIStatus" else { return nil }
        return uiModel?.terminalUI?.execute(context)
    }

    func cancelPendingWork() {
        QuinjetWorkOwnership.beginSuspension()
        retireUI()
        startup?.cancel()
        worker?.beginSuspension()
    }

    func drain() async {
        await startup?.value
        await worker?.cancelPendingWork()
        await awaitUIStops()
        await QuinjetWorkOwnership.shutdown()
    }

    func teardown() async {
        retireUI()
        let stopping = worker
        let starting = startup
        worker = nil
        surface = nil
        startup = nil
        await starting?.value
        await stopping?.shutdown()
        await awaitUIStops()
        await QuinjetWorkOwnership.shutdown()
    }

    private func awaitUIStops() async {
        for task in Array(uiStops.values) { await task.value }
    }

    @discardableResult
    private func retireUI() -> Task<Void, Never>? {
        let model = uiModel
        let settings = settingsModel
        let client = uiClient
        model?.stopRendering()
        settings?.shutdown()
        uiModel = nil
        settingsModel = nil
        uiClient = nil
        uiLocation = nil
        uiController = nil
        guard model != nil || settings != nil else {
            client?.invalidate()
            return nil
        }
        let id = UUID()
        let task = Task { [self, model, settings, client] in
            defer {
                client?.invalidate()
                uiStops[id] = nil
            }
            await model?.shutdown()
            await settings?.shutdownAndWait()
        }
        uiStops[id] = task
        return task
    }
}

@MainActor
func makeQuinjetRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "quinjet", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { _ in QuinjetService() }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    let address = MainActor.assumeIsolated {
        UInt(bitPattern: Unmanaged.passRetained(makeQuinjetRuntime()).toOpaque())
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
