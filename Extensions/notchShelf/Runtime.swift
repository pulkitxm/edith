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
final class ExtensionRuntime: NSObject {
    private var startRequested = false
    #if EDITH_FUNCTIONAL_FIXTURE
    private var fixture: WorkerFixtureEngineAdmission?
    private var fixtureContext: NSDictionary?
    private var fixturePreferences: NotchFixturePreferences?
    #endif
    private var fixtureRejected = false
    private var fixtureUI = false
    private var stopped = false
    private var suspensionTask: Task<Void, Never>?
    private var suspensionFinished = false
    private var suspensionCompletions: [() -> Void] = []
    private var shutdownTask: Task<Void, Never>?
    private var shutdownFinished = false
    private var shutdownCompletions: [() -> Void] = []
    #if EDITH_FUNCTIONAL_FIXTURE
    private let fixtureAdmission: @MainActor (NSDictionary) throws -> WorkerFixtureEngineAdmission?
    #endif
    private var fixtureActive = false
    private var controller: NotchShelfController?
    private struct UIScene {
        let client: ExtensionEngineClient?
        let settings: NotchSettingsModel?
        let chrome: NotchChromeClient?
        #if EDITH_FUNCTIONAL_FIXTURE
        var admission: WorkerFixtureUIAdmission? = nil
        #endif
        let generation: UUID
    }
    private var uiScenes: [UUID: UIScene] = [:]
    private var suspendedUIScenes: [UIScene] = []
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private var selectedPresentation: UUID?
    private let commands = ExtensionCommandRegistry()
    private var panelEngine: NotchPanelEngine?
    private var cliStreams: ExtensionCLIStreams?
    private var browserStreams: ExtensionCLIStreams?

    private let contextSource: @MainActor () -> SurfaceHostContext?
    private let connectedDisplays: @MainActor () -> [UInt32: CGSize]
    private let createController:
        @MainActor (SurfaceHostContext, [NotchPanelDisplay]) -> NotchShelfController

    #if EDITH_FUNCTIONAL_FIXTURE
    init(
        fixtureAdmission:
            @escaping @MainActor (NSDictionary) throws -> WorkerFixtureEngineAdmission? = {
                try WorkerFixtureEngineAdmission.current(
                    extensionID: "notchShelf", context: $0,
                    roleBundle: Bundle(for: ExtensionRuntime.self), expectedRole: .helper)
            },
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
        self.fixtureAdmission = fixtureAdmission
        self.contextSource = contextSource
        self.connectedDisplays = connectedDisplays
        self.createController = createController
        super.init()
    }

    #else
    private let validateOrdinaryContext: @MainActor (NSDictionary) throws -> Void

    init(
        validateOrdinaryContext: @escaping @MainActor (NSDictionary) throws -> Void =
            ExtensionRuntime.validateOrdinaryContext,
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
        self.validateOrdinaryContext = validateOrdinaryContext
        self.contextSource = contextSource
        self.connectedDisplays = connectedDisplays
        self.createController = createController
        super.init()
    }

    private static func validateOrdinaryContext(_ context: NSDictionary) throws {
        guard ProcessInfo.processInfo.environment["EDITH_FUNCTIONAL_FIXTURE"] == nil,
            context["hostedFunctionalFixture"] == nil,
            try WorkerFixtureAdmission.current(
                extensionID: "notchShelf", context: context,
                roleBundle: Bundle(for: ExtensionRuntime.self)) == nil
        else { throw WorkerFixtureError.invalid }
    }

    #endif
    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard !stopped, !fixtureRejected else {
            completion(nil, ExtensionPeerError.unavailable.localizedDescription as NSString)
            return
        }
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, !stopped, !fixtureRejected else { throw ExtensionPeerError.unavailable }
            #if EDITH_FUNCTIONAL_FIXTURE
            if fixtureActive {
                guard startRequested, let preferences = fixturePreferences,
                    ["notch.settings.read", "notch.settings.write", "notchShelf.cli.catalog"]
                        .contains(
                            command)
                else { throw ExtensionPeerError.unavailable }
                do {
                    guard let token = (request["token"] as? String).flatMap(UUID.init(uuidString:)),
                        let fixture
                    else { throw WorkerFixtureError.invalid }
                    if command == "notchShelf.cli.catalog" {
                        guard payload == Data("{}".utf8) else {
                            throw ExtensionPeerError.invalidRequest
                        }
                    } else {
                        try NotchFixturePreferences.validate(
                            command, payload: payload, schema: NotchSettingsSchema.defaults,
                            accepts: NotchSettingsSchema.accepts)
                    }
                    let ticket = try fixture.beginRequest(
                        token: token, operation: command, payload: payload)
                    defer { fixture.cancelRequest(ticket) }
                    let response: Data
                    if command == "notchShelf.cli.catalog" {
                        try requireCurrentFixture()
                        response = try NotchCLIProviderCatalog.encode(payload)
                    } else {
                        let values = try preferences.execute(command, payload: payload)
                        let snapshot = NotchSettingsSnapshot(
                            preferences: values, activeIDs: [], browserProfile: nil,
                            bluetoothPrivacyRequired: false)
                        try snapshot.validate()
                        try requireCurrentFixture()
                        response = try JSONEncoder().encode(snapshot)
                    }
                    try fixture.completeRequest(ticket)
                    return response
                } catch NotchFixturePreferencesError.invalid {
                    throw ExtensionPeerError.invalidRequest
                }
            }
            #endif
            if command == "notchShelf.cli.catalog" {
                return try NotchCLIProviderCatalog.encode(payload)
            }
            guard startRequested, !fixtureActive else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("notch.panel.") || command == "notch.chrome.read"
                || command == "notch.chrome.action" || command == "notch.chrome.thumbnail"
                || command == "notch.chrome.browser" || command == "notch.chrome.quick"
                || command == "notch.chrome.camera"
            {
                return try await self.executePanel(command, payload: payload)
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
                    if self.browserStreams == nil {
                        self.browserStreams = try ExtensionCLIStreams(owner: "notchShelf")
                    }
                    guard let streams = self.browserStreams else {
                        throw ExtensionPeerError.unavailable
                    }
                    return try streams.invoke(
                        BrowserCommand.self, operation: command, prefix: "browser.cli",
                        payload: payload)
                }
            }

            guard let controller = self.controller else { throw ExtensionPeerError.unavailable }
            if ["notch.cli.start", "notch.cli.read", "notch.cli.cancel", "notch.cli.end"].contains(
                command)
            {
                let configuration = ShelfCLIConfiguration(
                    root: controller.store.root, defaults: controller.context.defaults,
                    open: { NSWorkspace.shared.open($0) },
                    reveal: { NSWorkspace.shared.activateFileViewerSelecting($0) },
                    share: { try await controller.shareCLIItems($0) },
                    checkAccess: controller.requireShelfCLIAccess)
                return try ShelfCLIEnvironment.$configuration.withValue(configuration) {
                    if self.cliStreams == nil {
                        self.cliStreams = try ExtensionCLIStreams(owner: "notchShelf")
                    }
                    guard let streams = self.cliStreams else {
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
    }

    #if EDITH_FUNCTIONAL_FIXTURE
    private func requireCurrentFixture() throws {
        guard !stopped, !fixtureRejected, let fixture else { throw WorkerFixtureError.invalid }
        try fixture.requireCurrent()
    }

    private func invokeSettingsUI(
        _ operation: String, payload: Data, presentation: UUID, generation: UUID,
        client: ExtensionEngineClient, admission: WorkerFixtureUIAdmission
    ) async throws -> Data {
        guard !stopped, !fixtureRejected,
            let scene = uiScenes[presentation], scene.generation == generation,
            scene.client === client, scene.admission === admission
        else { throw WorkerFixtureError.invalid }
        try Task.checkCancellation()
        try admission.requireCurrent()
        try NotchFixturePreferences.validate(
            operation, payload: payload, schema: NotchSettingsSchema.defaults,
            accepts: NotchSettingsSchema.accepts)
        let response = try await client.invoke(operation, payload: payload)
        try Task.checkCancellation()
        guard !stopped, !fixtureRejected,
            uiScenes[presentation]?.generation == generation
        else { throw WorkerFixtureError.invalid }
        try admission.requireCurrent()
        return response
    }

    #endif
    private func executePanel(_ command: String, payload: Data) async throws -> Data {
        guard Bundle.main.bundleURL.pathExtension != "appex",
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        if suspensionFinished { completion(); return }
        suspensionCompletions.append(completion)
        guard suspensionTask == nil else { return }
        startRequested = false
        stopped = true
        commands.suspend()
        #if EDITH_FUNCTIONAL_FIXTURE
        fixturePreferences?.stop()
        #endif
        stopUI(preservingMetadata: true)
        let streams = cliStreams
        let browserCommands = browserStreams
        let ownedController = controller
        let ownedPanel = panelEngine
        let cameraEngine = ownedPanel?.cameraEngine
        ownedPanel?.beginSuspension()
        streams?.stop()
        browserCommands?.stop()
        ownedController?.beginSuspension()
        cameraEngine?.shutdown()
        suspensionTask = Task {
            await commands.suspendAndWait()
            await ownedPanel?.suspendAndWait()
            await streams?.stopAndWait()
            await browserCommands?.stopAndWait()
            for task in Array(uiDrains.values) { await task.value }
            await ownedController?.stopAndWait()
            await cameraEngine?.shutdownAndWait()
            suspensionFinished = true
            let completions = suspensionCompletions
            suspensionCompletions.removeAll()
            for completion in completions { completion() }
            suspensionTask = nil
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        if shutdownFinished { completion(); return }
        shutdownCompletions.append(completion)
        guard shutdownTask == nil else { return }
        suspendCommands(completion: {})
        commands.shutdown()
        let suspending = suspensionTask
        let ownedController = controller
        let ownedPanel = panelEngine
        shutdownTask = Task {
            await suspending?.value
            await ownedPanel?.stopAndWait()
            await ownedController?.shutdownAndWait()
            for scene in suspendedUIScenes { await scene.chrome?.stopAndWait() }
            await commands.shutdownAndWait()
            suspendedUIScenes.removeAll()
            selectedPresentation = nil
            controller = nil; panelEngine = nil
            cliStreams = nil; browserStreams = nil
            NotchPresenterState.shared.privacy = nil
            ShelfThumbnails.clear()
            #if EDITH_FUNCTIONAL_FIXTURE
            fixture = nil; fixtureContext = nil; fixturePreferences = nil
            #endif
            fixtureActive = false; fixtureUI = false
            shutdownFinished = true
            let completions = shutdownCompletions
            shutdownCompletions.removeAll()
            for completion in completions { completion() }
            shutdownTask = nil
        }
    }

    private func stopUI(_ presentation: UUID? = nil, preservingMetadata: Bool = false) {
        let keys = presentation.map { [$0] } ?? Array(uiScenes.keys)
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
            uiDrains[drainID] = Task {
                await scene.settings?.stopAndWait()
                if preservingMetadata {
                    await scene.chrome?.suspendAndWait()
                } else {
                    await scene.chrome?.stopAndWait()
                }
                uiDrains[drainID] = nil
            }
        }
        if !preservingMetadata, presentation == nil || selectedPresentation == presentation {
            selectedPresentation = nil
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "notchShelf", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard !stopped, !fixtureRejected, !fixtureActive else {
                return ["ok": false] as NSDictionary
            }
            #if EDITH_FUNCTIONAL_FIXTURE
            let admission: WorkerFixtureUIAdmission?
            do {
                admission = try WorkerFixtureUIAdmission.current(
                    extensionID: "notchShelf", context: input,
                    roleBundle: Bundle(for: ExtensionRuntime.self))
                try admission?.requireCurrent()
                if let admission {
                    guard input["location"] as? String == "settings",
                        admission.descriptor.rolePath.hasSuffix("/notchShelf/helper.bundle"),
                        input["engineClient"] != nil
                    else { throw WorkerFixtureError.invalid }
                }
            } catch { return ["ok": false] as NSDictionary }
            #else
            do { try validateOrdinaryContext(input) } catch {
                fixtureRejected = true; return ["ok": false] as NSDictionary
            }
            #endif
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "notchShelf", input["tile"] == nil,
                input["target"] == nil,
                let rawPresentation = input["presentationID"] as? String,
                let presentation = UUID(uuidString: rawPresentation),
                let location = input["location"] as? String
            else { return ["ok": false] as NSDictionary }
            for (key, scene) in Array(uiScenes)
            where scene.chrome?.stopped == true || scene.settings?.stopped == true { stopUI(key) }
            guard uiScenes.count < 16 || uiScenes[presentation] != nil else {
                return ["ok": false] as NSDictionary
            }
            let generation = UUID()
            var scene: UIScene
            if location == "settings" {
                let model: NotchSettingsModel
                #if EDITH_FUNCTIONAL_FIXTURE
                if let admission, let client = configuration.engineClient {
                    model = NotchSettingsModel(invoke: { [weak self] operation, payload in
                        guard let self else { throw WorkerFixtureError.invalid }
                        return try await self.invokeSettingsUI(
                            operation, payload: payload, presentation: presentation,
                            generation: generation, client: client, admission: admission)
                    })
                } else {
                    model = NotchSettingsModel(client: configuration.engineClient)
                }
                #else
                model = NotchSettingsModel(client: configuration.engineClient)
                #endif
                scene = UIScene(
                    client: configuration.engineClient, settings: model, chrome: nil,
                    generation: generation)
                #if EDITH_FUNCTIONAL_FIXTURE
                scene.admission = admission
                #endif
            } else if location == "notch", let section = input["section"] as? String,
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
                return ["ok": false] as NSDictionary
            }
            stopUI(presentation)
            uiScenes[presentation] = scene
            #if EDITH_FUNCTIONAL_FIXTURE
            fixtureUI = fixtureUI || admission != nil
            #endif
            selectedPresentation = presentation
        case "stopUI":
            stopUI((input["presentationID"] as? String).flatMap(UUID.init(uuidString:)))
        case "start":
            guard !stopped, !fixtureRejected else { return ["ok": false] as NSDictionary }
            do {
                #if EDITH_FUNCTIONAL_FIXTURE
                let admitted = try fixtureAdmission(input)
                if let admitted {
                    guard admitted.descriptor.owner == "notchShelf",
                        admitted.descriptor.role == "helper",
                        controller == nil, panelEngine == nil, uiScenes.isEmpty
                    else { throw WorkerFixtureError.invalid }
                    if let fixture {
                        guard fixture.descriptor == admitted.descriptor
                        else { throw WorkerFixtureError.invalid }
                    }
                    fixture = admitted
                    fixtureActive = true
                    if fixturePreferences == nil {
                        guard let suite = input["defaultsSuite"] as? String,
                            let identifier = input["hostIdentifier"] as? String
                        else { throw WorkerFixtureError.invalid }
                        fixtureContext = input.copy() as? NSDictionary
                        fixturePreferences = try NotchFixturePreferences(
                            suite: suite,
                            expectedSuite: identifier + ".extensions.notchShelf",
                            schema: NotchSettingsSchema.defaults,
                            isString: NotchSettingsSchema.isString,
                            accepts: NotchSettingsSchema.accepts,
                            requireCurrent: { [weak self] in
                                guard let self else { throw WorkerFixtureError.invalid }
                                try self.requireCurrentFixture()
                            })
                    } else {
                        guard
                            input["defaultsSuite"] as? String
                                == fixtureContext?["defaultsSuite"] as? String
                        else { throw WorkerFixtureError.invalid }
                        try requireCurrentFixture()
                    }
                    startRequested = true
                    return ["ok": true] as NSDictionary
                }
                guard !fixtureActive else { throw WorkerFixtureError.invalid }
                #else
                try validateOrdinaryContext(input)
                #endif
            } catch {
                fixtureRejected = true
                startRequested = false
                return ["ok": false] as NSDictionary
            }
            guard Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let context = contextSource()
            else { return ["ok": false] as NSDictionary }
            startRequested = true
            startAttachedController(context)
        case "view":
            guard !stopped, !fixtureRejected, !fixtureActive else {
                return ["ok": false] as NSDictionary
            }
            guard
                let key = (input["presentationID"] as? String).flatMap(UUID.init(uuidString:))
                    ?? selectedPresentation,
                let scene = uiScenes[key]
            else { return ["ok": false] as NSDictionary }
            #if EDITH_FUNCTIONAL_FIXTURE
            do { try scene.admission?.requireCurrent() } catch {
                return ["ok": false] as NSDictionary
            }
            #endif
            if let chrome = scene.chrome {
                return NSHostingController(
                    rootView: ExtensionPageHost { NotchPanelPage(client: chrome) })
            }
            guard let model = scene.settings else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { NotchSettingsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !stopped, !fixtureRejected, !fixtureActive else {
                return ["ok": false] as NSDictionary
            }
            controller?.synchronize()
        case "stop": prepareToStop(completion: {})
        case "status":
            return [
                "ok": true, "running": controller != nil && !stopped,
                "startRequested": startRequested,
                "controllerAttached": controller != nil,
                "panelAttached": !stopped && panelEngine?.attached == true,
                "fixture": fixtureActive, "fixtureRejected": fixtureRejected,
                "stopped": stopped,
            ] as NSDictionary
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
