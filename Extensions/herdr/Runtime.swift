import Darwin
import AppKit
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithHerdrExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var uiClient: ExtensionEngineClient?
    private var sessionSettingsModel: HerdrSessionSettingsModel?
    private var settingsModel: HerdrSettingsModel?
    private var uiStore: HerdrStore?
    private var uiActivity: AgentActivityMonitor?
    private var uiController: NSViewController?
    private var uiLocation: String?
    private var worker: HerdrWorker?
    private var surface: HerdrSurface?
    private var startup: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            if command == "herdr.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                return try JSONEncoder().encode(
                    await HerdrCLIExecution.run(request, worker: worker))
            }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(prepareDisableWithCompletion:)
    func prepareDisable(completion: @escaping (NSError?) -> Void) {
        startup?.cancel()
        commands.shutdown()
        Task {
            await worker?.cancelPendingWork()
            await commands.shutdownAndWait()
            await startup?.value
            do { try await worker?.prepareDisable(); completion(nil) } catch {
                completion(error as NSError)
            }
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
                "id": "herdr", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "configureUI":
            guard worker == nil, let location = input["location"] as? String,
                ["main", "settings", "herdr.agent", "herdr.agent.controls", "herdr.space"].contains(
                    location),
                let configuration = ExtensionUIConfiguration(context: input),
                let origin = input["presentationID"] as? String,
                let presentationID = UUID(uuidString: origin),
                configuration.extensionID == "herdr",
                location == "settings" || configuration.engineClient != nil
            else { return ["ok": false] as NSDictionary }
            let settingsSection = (input["section"] as? String).flatMap(HerdrSettingsSection.init)
            guard location != "settings" || settingsSection != nil else {
                return ["ok": false] as NSDictionary
            }
            if location.hasPrefix("herdr.") {
                guard let target = input["target"] as? String, !target.isEmpty,
                    target.utf8.count <= 4096, !target.utf8.contains(0),
                    let raw = input["herdrPresentationToken"] as? String,
                    UUID(uuidString: raw) != nil
                else { return ["ok": false] as NSDictionary }
            }
            stopUI()
            uiLocation = location
            uiClient = configuration.engineClient
            if location != "settings", let client = configuration.engineClient {
                let facade = HerdrUIClient(client: client)
                let store = HerdrStore(uiClient: facade)
                store.uiPresentationID = presentationID
                store.terminalUI = store.makeTerminalUIPresentation(
                    id: presentationID,
                    location: location, target: input["target"] as? String ?? "",
                    token: (input["herdrPresentationToken"] as? String).flatMap(
                        UUID.init(uuidString:)))
                let activity = AgentActivityMonitor(defaults: store.uiDefaults, uiClient: facade)
                store.uiActivity = activity
                uiStore = store
                uiActivity = activity
                uiController = NSHostingController(
                    rootView: ExtensionPageHost {
                        if location == "main" {
                            HerdrPage(store: store, activity: activity)
                                .environment(\.terminalLaunchEnabled, true)
                        } else {
                            HerdrRemoteScene(
                                store: store, location: location,
                                target: input["target"] as? String ?? "",
                                token: UUID(
                                    uuidString: input["herdrPresentationToken"] as? String ?? "")!
                            )
                            .environment(\.terminalLaunchEnabled, true)
                        }
                    })
                PresenterState.shared.start()
            } else if settingsSection == .agentActivity {
                let facade: HerdrUIClient
                if let client = configuration.engineClient {
                    facade = HerdrUIClient(client: client)
                } else {
                    facade = HerdrUIClient { _, _ in throw ExtensionPeerError.unavailable }
                }
                let store = HerdrStore(uiClient: facade)
                store.uiPresentationID = presentationID
                let activity = AgentActivityMonitor(defaults: store.uiDefaults, uiClient: facade)
                activity.folderPresentationID = presentationID
                store.uiActivity = activity
                uiStore = store
                uiActivity = activity
                uiController = NSHostingController(
                    rootView: ExtensionPageHost {
                        HerdrActivitySettingsPage(store: store, monitor: activity)
                    })
            } else if settingsSection == .extensionSettings {
                let facade: HerdrUIClient
                if let client = configuration.engineClient {
                    facade = HerdrUIClient(client: client)
                } else {
                    facade = HerdrUIClient { _, _ in throw ExtensionPeerError.unavailable }
                }
                let model = HerdrSessionSettingsModel(client: facade)
                sessionSettingsModel = model
                uiController = NSHostingController(
                    rootView: ExtensionPageHost { HerdrExtensionSettingsPage(model: model) })
            } else {
                let model: HerdrSettingsModel
                if let client = configuration.engineClient {
                    model = HerdrSettingsModel(client: client)
                } else {
                    model = HerdrSettingsModel { _, _ in throw ExtensionPeerError.unavailable }
                }
                settingsModel = model
                uiController = NSHostingController(
                    rootView: ExtensionPageHost { HerdrSettingsPage(model: model) })
            }
        case "terminalUI", "terminalUIStatus":
            guard let binding = uiStore?.terminalUI else { return ["ok": false] as NSDictionary }
            return binding.execute(input)
        case "stopUI": stopUI()
        case "start":
            guard uiLocation == nil, Bundle.main.bundleURL.pathExtension != "appex",
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            let navigation = (input["hostNavigation"] as? NSObject).flatMap {
                HerdrHostWindowNavigationClient(bridge: $0)
            }
            let folderChoice = (input["hostNavigation"] as? NSObject).flatMap {
                HerdrHostFolderChoiceClient(bridge: $0)
            }
            let created = HerdrWorker(
                hostWindowNavigation: navigation, hostFolderChoice: folderChoice)
            worker = created
            surface = HerdrSurface(worker: created)
            let recovery =
                input["recoveryOnly"] as? Bool == true
                || ProcessInfo.processInfo.environment["EDITH_EXTENSION_RECOVERY_ONLY"] == "1"
            if !recovery { startup = Task { await created.start() } }
        case "view":
            guard input["location"] as? String == uiLocation, let uiController else {
                return ["ok": false] as NSDictionary
            }
            return uiController
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
    private func stopUI() {
        sessionSettingsModel?.shutdown()
        sessionSettingsModel = nil
        settingsModel?.shutdown()
        settingsModel = nil
        let store = uiStore
        let activity = uiActivity
        store?.stopRendering()
        activity?.cancelFolderChoice()
        uiClient?.invalidate()
        uiClient = nil
        uiStore = nil
        uiActivity = nil
        uiController = nil
        uiLocation = nil
        if store != nil || activity != nil {
            Task {
                await store?.shutdown(); await activity?.shutdown()
            }
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
        if let root = ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"] {
            let receipt = try JSONSerialization.data(withJSONObject: [
                "pid": getpid(), "parent": getppid(), "group": getpgrp(),
                "owner": Int32(
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_NATIVE_PARENT"] ?? "")
                    ?? 0,
                "inputTerminal": isatty(STDIN_FILENO), "bytes": count,
            ])
            try receipt.write(
                to: URL(fileURLWithPath: root).appendingPathComponent("herdr-native-receipt.json"))
        }
        try HerdrBridgeCommand.run(
            encoded: Data(bytes: bytes, count: Int(count)).base64EncodedString())
        return 0
    } catch let error as HerdrBridgeExit { return error.status } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}
