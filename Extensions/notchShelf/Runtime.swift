#if canImport(WorkerFixtureSupport)
import WorkerFixtureSupport
#endif
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class NotchShelfService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var startRequested = false
    private var fixtureRejected = false
    private var fixtureActive = false
    private var controller: NotchShelfController?
    private struct UIScene {
        let client: ExtensionEngineClient?
        let settings: NotchSettingsModel?
        let chrome: NotchChromeClient?
        let generation: UUID
    }
    private var uiScenes: [UUID: UIScene] = [:]
    private var suspendedUIScenes: [UIScene] = []
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var panelEngine: NotchPanelEngine?
    private var cliStreams: ExtensionCLIStreams?
    private var browserStreams: ExtensionCLIStreams?
    private var suspendingStreams: ExtensionCLIStreams?
    private var suspendingBrowserStreams: ExtensionCLIStreams?
    private var suspendingController: NotchShelfController?
    private var suspendingPanel: NotchPanelEngine?
    private var suspendingCamera: NotchCameraEngine?

    private let contextSource: @MainActor () -> SurfaceHostContext?
    private let connectedDisplays: @MainActor () -> [UInt32: CGSize]
    private let createController:
        @MainActor (SurfaceHostContext, [NotchPanelDisplay]) -> NotchShelfController

    private let admitOrdinaryContext: @MainActor (NSDictionary) throws -> WorkerFixtureAdmission?

    init(
        runtime: ExtensionServiceRuntime,
        admitOrdinaryContext:
            @escaping @MainActor (NSDictionary) throws -> WorkerFixtureAdmission? =
            NotchShelfService.admitOrdinaryContext,
        contextSource: @escaping @MainActor () -> SurfaceHostContext? = {
            SurfaceHostContext.current
        },
        connectedDisplays: @escaping @MainActor () -> [UInt32: CGSize] = {
            Dictionary(
                uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                    guard
                        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                            as? UInt32
                    else { return nil }
                    return (id, screen.frame.size)
                })
        },
        createController:
            @escaping @MainActor (SurfaceHostContext, [NotchPanelDisplay]) -> NotchShelfController =
            {
                NotchShelfController(context: $0, hostDisplays: $1)
            }
    ) {
        self.runtime = runtime
        self.admitOrdinaryContext = admitOrdinaryContext
        self.contextSource = contextSource
        self.connectedDisplays = connectedDisplays
        self.createController = createController
    }

    static func admitOrdinaryContext(_ context: NSDictionary) throws
        -> WorkerFixtureAdmission?
    {
        guard ExtensionEnvironment.values["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            context["hostedFunctionalFixture"] == nil
        else { throw WorkerFixtureError.invalid }
        return try WorkerFixtureAdmission.current(
            extensionID: "notchShelf", context: context,
            roleBundle: Bundle(for: NotchShelfService.self))
    }

    private var stopped: Bool { runtime.isSuspended || runtime.isStopping }

    var isRunning: Bool { controller != nil && !stopped }

    var allowsUIDuringRetirement: Bool { true }

    var statusDetails: [String: Any] {
        [
            "startRequested": startRequested,
            "controllerAttached": controller != nil,
            "panelAttached": !stopped && panelEngine?.attached == true,
            "fixture": fixtureActive, "fixtureRejected": fixtureRejected,
            "stopped": stopped,
        ]
    }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard !fixtureRejected else { return false }
        let input = context.input
        do {
            if try admitOrdinaryContext(input) != nil {
                guard controller == nil, panelEngine == nil, uiScenes.isEmpty,
                    input["defaultsSuite"] as? String
                        == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
                else { throw WorkerFixtureError.invalid }
                fixtureActive = true
                startRequested = true
                return true
            }
            guard !fixtureActive else { throw WorkerFixtureError.invalid }
        } catch {
            fixtureRejected = true
            startRequested = false
            return false
        }
        guard !ExtensionHostRole.isInterfaceProcess,
            let context = contextSource()
        else { return false }
        startRequested = true
        startAttachedController(context)
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !stopped, !fixtureRejected, !fixtureActive else { return false }
        controller?.synchronize()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !stopped, !fixtureRejected else { throw ExtensionPeerError.unavailable }
        if command == "notchShelf.cli.catalog" {
            return try NotchCLIProviderCatalog.encode(payload)
        }
        guard startRequested, !fixtureActive else { throw ExtensionPeerError.unavailable }
        if command.hasPrefix("notch.panel.") || command == "notch.chrome.read"
            || command == "notch.chrome.action" || command == "notch.chrome.thumbnail"
            || command == "notch.chrome.browser" || command == "notch.chrome.quick"
            || command == "notch.chrome.camera"
        {
            return try await executePanel(command, payload: payload)
        }
        if command == "browser.cli" || command.hasPrefix("browser.cli.") {
            let configuration = BrowserCLIExecution.configuration(request: {
                [weak self] request in
                guard let browser = self?.controller?.browserEngine else {
                    throw ExtensionPeerError.unavailable
                }
                return try await browser.cliQueue.invoke(request)
            })
            return try await BrowserCLIEnvironment.$configuration.withValue(configuration) {
                if command == "browser.cli" {
                    let request = try JSONDecoder().decode(
                        ExtensionCLIRequest.self, from: payload)
                    return try JSONEncoder().encode(
                        try await ExtensionCLIExecution.run(
                            BrowserCommand.self, request: request))
                }
                if browserStreams == nil {
                    browserStreams = try ExtensionCLIStreams(owner: "notchShelf")
                }
                guard let streams = browserStreams else {
                    throw ExtensionPeerError.unavailable
                }
                return try streams.invoke(
                    BrowserCommand.self, operation: command, prefix: "browser.cli",
                    payload: payload)
            }
        }

        guard let controller = controller else { throw ExtensionPeerError.unavailable }
        if ["notch.cli.start", "notch.cli.read", "notch.cli.cancel", "notch.cli.end"].contains(
            command)
        {
            let configuration = ShelfCLIExecution.configuration(
                root: controller.store.root, defaults: controller.context.defaults,
                checkAccess: controller.requireShelfCLIAccess
            ) { ids in try await controller.shareCLIItems(ids) }
            return try await ShelfCLIEnvironment.$configuration.withValue(configuration) {
                () async throws -> Data in
                if cliStreams == nil {
                    cliStreams = try ExtensionCLIStreams(owner: "notchShelf")
                }
                guard let streams = cliStreams else {
                    throw ExtensionPeerError.unavailable
                }
                return try streams.invoke(
                    ShelfCommand.self, operation: command, prefix: "notch.cli", payload: payload
                )
            }
        }
        if command == "notch.cli" {
            let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
            let reply = try await ShelfCLIExecution.run(
                request, root: controller.store.root, defaults: controller.context.defaults,
                checkAccess: controller.requireShelfCLIAccess
            ) { ids in try await controller.shareCLIItems(ids) }
            return try JSONEncoder().encode(reply)
        }
        return try await controller.execute(command, payload: payload)
    }

    private func executePanel(_ command: String, payload: Data) async throws -> Data {
        guard !ExtensionHostRole.isInterfaceProcess,
            payload.count <= NotchPanelEngine.maximumBytes,
            let context = contextSource()
        else { throw ExtensionPeerError.invalidRequest }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        if command == "notch.panel.attach" {
            if let engine = panelEngine {
                return try encoder.encode(
                    engine.attach(decoder.decode(NotchPanelAttach.self, from: payload)))
            }
            guard controller == nil else { throw ExtensionPeerError.invalidRequest }
            let engine = NotchPanelEngine(
                context: context,
                connectedDisplays: connectedDisplays,
                invalidate: { presentation in
                    DistributedNotificationCenter.default().postNotificationName(
                        Notification.Name(
                            context.sharedState.namespace + ".notchPanel." + presentation.uuidString
                        ),
                        object: nil, userInfo: nil, deliverImmediately: true)
                })
            let batch = try engine.attach(decoder.decode(NotchPanelAttach.self, from: payload))
            panelEngine = engine
            startAttachedController(context)
            return try encoder.encode(startRequested ? engine.batch() : batch)
        }
        guard let engine = panelEngine else { throw ExtensionPeerError.unavailable }
        switch command {
        case "notch.panel.scene.stop":
            try engine.stopScene(decoder.decode(NotchPanelSceneStop.self, from: payload))
        case "notch.panel.wait":
            return try encoder.encode(
                await engine.wait(decoder.decode(NotchPanelWait.self, from: payload)))
        case "notch.panel.geometry":
            try engine.geometry(decoder.decode(NotchPanelGeometry.self, from: payload))
        case "notch.panel.measure":
            try engine.measure(decoder.decode(NotchPanelMeasure.self, from: payload))
        case "notch.panel.pointer":
            try engine.pointer(decoder.decode(NotchPanelPointer.self, from: payload))
        case "notch.panel.transfer.ack":
            try engine.acknowledgeTransfer(
                decoder.decode(NotchPanelTransferAcknowledgement.self, from: payload))
        case "notch.panel.transfer.finish":
            try engine.finishTransfer(decoder.decode(NotchPanelTransferFinish.self, from: payload))
        case "notch.panel.drop": try engine.drop(decoder.decode(NotchPanelDrop.self, from: payload))
        case "notch.panel.promise.prepare":
            return try encoder.encode(
                engine.preparePromise(decoder.decode(NotchPanelPromise.self, from: payload)))
        case "notch.panel.promise.finish":
            try engine.finishPromise(decoder.decode(NotchPanelPromise.self, from: payload))
        case "notch.panel.detach":
            try engine.detach(decoder.decode(NotchPanelIdentity.self, from: payload))
        case "notch.chrome.camera":
            return try await engine.camera(decoder.decode(NotchCameraRequest.self, from: payload))
        case "notch.chrome.quick":
            return try await engine.quickActions(
                decoder.decode(NotchQuickActionRequest.self, from: payload))
        case "notch.chrome.browser":
            return try await engine.browser(
                decoder.decode(NotchBrowserRemoteRequest.self, from: payload))
        case "notch.chrome.thumbnail":
            let request = try decoder.decode(NotchChromeAction.self, from: payload)
            let snapshot = try engine.chrome(
                .init(displayID: request.displayID, presentationID: request.presentationID))
            guard request.identity == snapshot.identity,
                let item = snapshot.items.first(where: { $0.id == request.itemID }),
                !snapshot.hiddenWidgets.contains(.ability("notchShelf")), let controller
            else { throw ExtensionPeerError.invalidRequest }
            let image = await controller.thumbnail(for: item)
            guard let data = image?.tiffRepresentation, data.count <= 524288 else { return Data() }
            return data
        case "notch.chrome.read":
            return try encoder.encode(
                engine.chrome(decoder.decode(NotchChromeRead.self, from: payload)))
        case "notch.chrome.action":
            let request = try decoder.decode(NotchChromeAction.self, from: payload)
            try engine.action(request)
            return try encoder.encode(
                engine.chrome(
                    .init(displayID: request.displayID, presentationID: request.presentationID)))
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    private func startAttachedController(_ context: SurfaceHostContext) {
        guard startRequested, controller == nil, let engine = panelEngine, engine.attached else {
            return
        }
        let owned = createController(context, Array(engine.displays.values))
        controller = owned
        engine.bind(owned)
        NotchPresenterState.shared.privacy = owned.privacy
        owned.synchronize()
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard !stopped, !fixtureRejected, !fixtureActive else { return false }
        let input = configuration.input
        do {
            guard try admitOrdinaryContext(input) == nil else { return false }
        } catch {
            fixtureRejected = true
            return false
        }
        guard input["tile"] == nil, input["target"] == nil,
            let rawPresentation = input["presentationID"] as? String,
            let presentation = UUID(uuidString: rawPresentation),
            let location = configuration.location
        else { return false }
        for (key, scene) in Array(uiScenes)
        where scene.chrome?.stopped == true || scene.settings?.stopped == true {
            _ = retireUI(key)
        }
        guard uiScenes.count < 16 || uiScenes[presentation] != nil else { return false }
        let generation = UUID()
        let scene: UIScene
        if configuration.isSettings {
            let model = NotchSettingsModel(client: configuration.engineClient)
            scene = UIScene(
                client: configuration.engineClient, settings: model, chrome: nil,
                generation: generation)
        } else if location == "notch", let section = configuration.section,
            section.hasPrefix("panel."), let id = UInt32(section.dropFirst(6)),
            section == "panel." + String(id), let client = configuration.engineClient
        {
            let chrome = NotchChromeClient(
                displayID: id, presentationID: presentation,
                namespace: configuration.hostIdentifier
            ) {
                operation, payload in try await client.invoke(operation, payload: payload)
            }
            scene = UIScene(
                client: client, settings: nil, chrome: chrome,
                generation: generation)
        } else {
            return false
        }
        _ = retireUI(presentation)
        uiScenes[presentation] = scene
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !stopped, !fixtureRejected, !fixtureActive, let scene = uiScenes[presentation]
        else { return nil }
        if let chrome = scene.chrome {
            return NSHostingController(
                rootView: ExtensionPageHost { NotchPanelPage(client: chrome) })
        }
        guard let model = scene.settings else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { NotchSettingsPage(model: model) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        retireUI(presentation)
    }

    func cancelPendingWork() {
        startRequested = false
        _ = retireUI(nil, preservingMetadata: true)
        suspendingStreams = cliStreams
        suspendingBrowserStreams = browserStreams
        suspendingController = controller
        suspendingPanel = panelEngine
        suspendingCamera = suspendingPanel?.cameraEngine
        suspendingPanel?.beginSuspension()
        suspendingStreams?.stop()
        suspendingBrowserStreams?.stop()
        suspendingController?.beginSuspension()
        suspendingCamera?.shutdown()
    }

    func drain() async {
        await suspendingPanel?.suspendAndWait()
        await suspendingStreams?.stopAndWait()
        await suspendingBrowserStreams?.stopAndWait()
        for task in Array(uiDrains.values) { await task.value }
        await suspendingController?.stopAndWait()
        await suspendingCamera?.shutdownAndWait()
    }

    func teardown() async {
        let ownedController = controller
        let ownedPanel = panelEngine
        await ownedPanel?.stopAndWait()
        await ownedController?.shutdownAndWait()
        for scene in suspendedUIScenes { await scene.chrome?.stopAndWait() }
        suspendedUIScenes.removeAll()
        controller = nil
        panelEngine = nil
        cliStreams = nil
        browserStreams = nil
        suspendingStreams = nil
        suspendingBrowserStreams = nil
        suspendingController = nil
        suspendingPanel = nil
        suspendingCamera = nil
        NotchPresenterState.shared.privacy = nil
        ShelfThumbnails.clear()
        fixtureActive = false
    }

    private func retireUI(_ presentation: UUID?, preservingMetadata: Bool = false) -> [Task<
        Void, Never
    >] {
        let keys = presentation.map { [$0] } ?? Array(uiScenes.keys)
        var tasks: [Task<Void, Never>] = []
        for key in keys {
            guard let scene = uiScenes.removeValue(forKey: key) else { continue }
            scene.settings?.stop()
            if preservingMetadata {
                suspendedUIScenes.append(scene)
                scene.chrome?.beginSuspension()
            } else {
                scene.chrome?.stop()
            }
            scene.client?.invalidate()
            let drainID = UUID()
            let task = Task {
                await scene.settings?.stopAndWait()
                if preservingMetadata {
                    await scene.chrome?.suspendAndWait()
                } else {
                    await scene.chrome?.stopAndWait()
                }
                uiDrains[drainID] = nil
            }
            uiDrains[drainID] = task
            tasks.append(task)
        }
        return tasks
    }
}

@MainActor
func makeNotchShelfRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "notchShelf", role: "helper", bundle: Bundle(for: BundleAnchor.self)
    ) { NotchShelfService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeNotchShelfRuntime()).toOpaque())
        })
}
