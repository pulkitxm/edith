import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithExtensionCommands
import Foundation
import SwiftUI

@MainActor
final class ExtensionRuntime: NSObject {
    private var store: CalendarStore?
    private var presentation: CalendarPresentationState?
    private var surface: CalendarSurface?
    private var uiEngine: CalendarUIEngine?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            if command == "calendar.cli.catalog" {
                guard self?.store != nil, payload == Data("{}".utf8) else {
                    throw ExtensionPeerError.unavailable
                }
                return try JSONSerialization.data(withJSONObject: [
                    "version": 1, "owner": "calendar",
                    "commands": [
                        [
                            "route": ["calendar"], "operation": "calendar.cli",
                            "summary": "Read and open your schedule.", "destructive": false,
                            "timeout": 30,
                        ]
                    ],
                ])
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
                return try JSONEncoder().encode(reply)
            }
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        uiEngine?.shutdown()
        store?.shutdown()
        Task {
            await commands.shutdownAndWait()
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
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if store == nil { store = CalendarStore(startImmediately: false) }
            if presentation == nil { presentation = CalendarPresentationState() }
            if let store, let presentation, surface == nil {
                surface = CalendarSurface(store: store, presentation: presentation)
                uiEngine = CalendarUIEngine(store: store, presentation: presentation)
                store.start()
            }
        case "view":
            guard let store, let presentation else { return ["ok": false] as NSDictionary }
            if input["location"] as? String == "home" {
                guard input["section"] as? String == "calendar",
                    let data = input["tile"] as? Data, data.count <= 65_536,
                    let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                    tile.widget == .calendar
                else { return ["ok": false] as NSDictionary }
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        CalendarHomeScene(tile: tile, store: store, presentation: presentation)
                    })
            }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    CalendarPage(store: store, presentation: presentation)
                })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": store?.refreshAuthStatus()
        case "stop":
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
