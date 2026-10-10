import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var stopping = false
    private var store: CalendarStore?
    private var presentation: CalendarPresentationState?
    private var surface: CalendarSurface?
    private var uiEngine: CalendarUIEngine?
    private let commands = ExtensionCommandRegistry()
    private var uiPresentations: [UUID: CalendarUIPresentation] = [:]

    override init() { super.init() }

    init(store: CalendarStore, presentation: CalendarPresentationState, uiEngine: CalendarUIEngine)
    {
        self.store = store
        self.presentation = presentation
        self.uiEngine = uiEngine
        super.init()
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        guard !stopping else {
            completion(nil, "The Calendar extension is stopping.")
            return
        }
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command == "calendar.cli.catalog" {
                guard self?.store != nil, payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.unavailable
                }
                return try CalendarCLICatalog.encoded(payload)
            }
            if command.hasPrefix("calendar.ui.") {
                guard let engine = self?.uiEngine else { throw ExtensionPeerError.unavailable }
                return try await engine.execute(command, payload: payload)
            }
            if command == "calendar.cli" {
                guard let store = self?.store else { throw ExtensionPeerError.unavailable }
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await CalendarCLIExecution.run(request) { query in
                    store.refreshAuthStatus()
                    guard store.authStatus == .fullAccess else {
                        throw CLIFailure.unavailable(
                            "macOS has not granted Edith calendar access",
                            hint: "run `ed permissions request calendar`")
                    }
                    return await store.events(query)
                }
                return try CalendarCLIExecution.encoded(reply)
            }
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        stopping = true
        commands.shutdown()
        uiEngine?.shutdown()
        store?.shutdown()
        CalendarPermission.shutdown()
        Task {
            await commands.shutdownAndWait()
            await uiEngine?.stopAndWait()
            await store?.stopAndWait()
            await CalendarPermission.stopAndWait()
            presentation?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "calendar", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard !stopping, Bundle.main.bundleURL.pathExtension != "appex",
                uiPresentations.isEmpty,
                let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if store == nil { store = CalendarStore(startImmediately: false) }
            if presentation == nil { presentation = CalendarPresentationState() }
            if let store, let presentation, surface == nil {
                surface = CalendarSurface(store: store, presentation: presentation)
                uiEngine = CalendarUIEngine(store: store, presentation: presentation)
                store.start()
            }
        case "configureUI":
            uiPresentations = uiPresentations.filter { $0.value.isRetained }
            guard store == nil, let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "calendar", let client = configuration.engineClient,
                let scene = CalendarUIPresentation(client: client, context: input),
                uiPresentations.count < 8 || uiPresentations[client.presentationID] != nil
            else { return ["ok": false] as NSDictionary }
            uiPresentations[client.presentationID]?.shutdown()
            uiPresentations[client.presentationID] = scene
        case "view":
            guard let value = input["presentationID"] as? String,
                let id = UUID(uuidString: value), let scene = uiPresentations[id],
                scene.matches(input)
            else { return ["ok": false] as NSDictionary }
            return scene.controller() ?? (["ok": false] as NSDictionary)
        case "stopUI":
            for scene in uiPresentations.values { scene.shutdown() }
            uiPresentations.removeAll()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": store?.refreshAuthStatus()
        case "stop":
            stopping = true
            for scene in uiPresentations.values { scene.shutdown() }
            uiPresentations.removeAll()
            commands.shutdown()
            uiEngine?.shutdown()
            uiEngine = nil
            surface = nil
            store?.shutdown()
            store = nil
            presentation?.shutdown()
            presentation = nil
            CalendarPermission.shutdown()
        case "status": return ["ok": true, "running": store != nil] as NSDictionary
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
