import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var controller: NotchShelfController?
    private var uiModel: NotchSettingsModel?
    private var uiClient: ExtensionEngineClient?
    private let commands = ExtensionCommandRegistry()
    private var panelEngine: NotchPanelEngine?
    private let cliStreams = try! ExtensionCLIStreams(owner: "notchShelf")

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("notch.panel.") || command == "notch.chrome.read"
                || command == "notch.chrome.action"
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
                    share: { try controller.shareCLIItems($0) })
                return try ShelfCLIEnvironment.$configuration.withValue(configuration) {
                    try self.cliStreams.invoke(
                        ShelfCommand.self, operation: command, prefix: "notch.cli", payload: payload
                    )
                }
            }
            if command == "notch.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await ShelfCLIExecution.run(
                    request, root: controller.store.root, defaults: controller.context.defaults
                ) { ids in try controller.shareCLIItems(ids) }
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
            guard controller == nil, panelEngine == nil else {
                throw ExtensionPeerError.invalidRequest
            }
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
            return try encoder.encode(batch)
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
        case "notch.panel.detach":
            try engine.detach(decoder.decode(NotchPanelIdentity.self, from: payload))
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

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        cliStreams.stop()
        panelEngine?.stop()
        stopUI()
        controller?.shutdown()
        controller = nil
        NotchPresenterState.shared.privacy = nil
        ShelfThumbnails.clear()
        Task {
            await commands.shutdownAndWait()
            await cliStreams.stopAndWait()
            completion()
        }
    }

    private func stopUI() {
        uiModel?.stop()
        uiModel = nil
        uiClient?.invalidate()
        uiClient = nil
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
                configuration.extensionID == "notchShelf",
                input["location"] as? String == "settings",
                input["tile"] == nil, input["target"] == nil
            else { return ["ok": false] as NSDictionary }
            stopUI()
            uiClient = configuration.engineClient
            uiModel = NotchSettingsModel(client: configuration.engineClient)
        case "stopUI": stopUI()
        case "start":
            guard Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                let context = SurfaceHostContext.current
            else { return ["ok": false] as NSDictionary }
            if controller == nil {
                controller = NotchShelfController(
                    context: context,
                    hostDisplays: panelEngine?.attached == true
                        ? Array(panelEngine!.displays.values) : nil)
                if let controller, panelEngine?.attached == true { panelEngine?.bind(controller) }
                NotchPresenterState.shared.privacy = controller?.privacy
                controller?.synchronize()
            }
        case "view":
            guard let uiModel else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { NotchSettingsPage(model: uiModel) })
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
