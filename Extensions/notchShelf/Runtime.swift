import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var startRequested = false
    private var controller: NotchShelfController?
    private struct UIScene {
        let client: ExtensionEngineClient?
        let settings: NotchSettingsModel?
        let chrome: NotchChromeClient?
    }
    private var uiScenes: [UUID: UIScene] = [:]
    private var selectedPresentation: UUID?
    private let commands = ExtensionCommandRegistry()
    private var panelEngine: NotchPanelEngine?
    private let cliStreams = try! ExtensionCLIStreams(owner: "notchShelf")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("notch.panel.") || command == "notch.chrome.read"
                || command == "notch.chrome.action" || command == "notch.chrome.thumbnail"
                || command == "notch.chrome.browser" || command == "notch.chrome.quick"
                || command == "notch.chrome.camera"
            {
                return try await self.executePanel(command, payload: payload)
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
                    try self.cliStreams.invoke(
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

    private func executePanel(_ command: String, payload: Data) async throws -> Data {
        guard Bundle.main.bundleURL.pathExtension != "appex",
            payload.count <= NotchPanelEngine.maximumBytes,
            let context = SurfaceHostContext.current
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
                connectedDisplays: {
                    Dictionary(
                        uniqueKeysWithValues: NSScreen.screens.compactMap { screen in
                            guard
                                let id = screen.deviceDescription[
                                    NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32
                            else { return nil }
                            return (id, screen.frame.size)
                        })
                },
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
        let owned = NotchShelfController(
            context: context, hostDisplays: Array(engine.displays.values))
        controller = owned
        engine.bind(owned)
        NotchPresenterState.shared.privacy = owned.privacy
        owned.synchronize()
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        cliStreams.stop()
        panelEngine?.stop()
        stopUI()
        let cameraEngine = panelEngine?.cameraEngine
        let browserEngine = controller?.browserEngine
        controller?.shutdown()
        controller = nil
        NotchPresenterState.shared.privacy = nil
        ShelfThumbnails.clear()
        Task {
            await commands.shutdownAndWait()
            await cliStreams.stopAndWait()
            await browserEngine?.stopAndWait()
            await cameraEngine?.shutdownAndWait()
            completion()
        }
    }

    private func stopUI(_ presentation: UUID? = nil) {
        let keys = presentation.map { [$0] } ?? Array(uiScenes.keys)
        for key in keys {
            guard let scene = uiScenes.removeValue(forKey: key) else { continue }
            scene.settings?.stop()
            scene.chrome?.stop()
            scene.client?.invalidate()
        }
        if presentation == nil || selectedPresentation == presentation {
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
            let scene: UIScene
            if location == "settings" {
                scene = UIScene(
                    client: configuration.engineClient,
                    settings: NotchSettingsModel(client: configuration.engineClient), chrome: nil)
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
                scene = UIScene(client: client, settings: nil, chrome: chrome)
            } else {
                return ["ok": false] as NSDictionary
            }
            stopUI(presentation)
            uiScenes[presentation] = scene
            selectedPresentation = presentation
        case "stopUI":
            stopUI((input["presentationID"] as? String).flatMap(UUID.init(uuidString:)))
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let context = SurfaceHostContext.current
            else { return ["ok": false] as NSDictionary }
            startRequested = true
            startAttachedController(context)
        case "view":
            guard
                let key = (input["presentationID"] as? String).flatMap(UUID.init(uuidString:))
                    ?? selectedPresentation,
                let scene = uiScenes[key]
            else { return ["ok": false] as NSDictionary }
            if let chrome = scene.chrome {
                return NSHostingController(
                    rootView: ExtensionPageHost { NotchPanelPage(client: chrome) })
            }
            guard let model = scene.settings else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { NotchSettingsPage(model: model) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": controller?.synchronize()
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": controller != nil] as NSDictionary
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
