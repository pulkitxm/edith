import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor
@objc(EdithSystemExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var model: RunningAppsModel?
    private var presentation: SystemPresentationState?
    private let operations = RunningAppOperationCenter()
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.model != nil else { throw ExtensionPeerError.unavailable }
            if command == "surface.snapshot" || command == "surface.perform" {
                return try await SurfaceCommandService.execute(
                    providerID: "system", command: command, payload: payload,
                    snapshot: { tile in
                        SystemSurface.snapshot(apps: self.operations.list(), tile: tile)
                    },
                    perform: { action in
                        guard
                            let app = self.operations.list().first(where: {
                                "activate:" + $0.pid.description == action
                            }), let running = NSRunningApplication(processIdentifier: app.pid),
                            running.bundleIdentifier == app.bundleID
                        else { throw ExtensionPeerError.invalidRequest }
                        guard running.activate() else {
                            throw ExtensionPeerError.rejected("The app could not open.")
                        }
                    })
            }
            switch command {
            case "apps.list":
                return try JSONSerialization.data(
                    withJSONObject: self.operations.list().map(Self.encode))
            case "apps.quit":
                let input = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
                let selection: RunningAppSelection
                if input?["all"] as? Bool == true {
                    selection = .all
                } else if let pid = input?["pid"] as? Int, pid > 0, pid <= Int(Int32.max) {
                    selection = .pid(Int32(pid))
                } else if let query = input?["query"] as? String, !query.isEmpty {
                    selection = .query(query)
                } else {
                    throw ExtensionPeerError.invalidRequest
                }
                let plan = try self.operations.plan(
                    selection, force: input?["force"] as? Bool ?? false)
                let outcome = self.operations.apply(
                    plan, confirmed: input?["confirmed"] as? Bool ?? false)
                return try JSONSerialization.data(withJSONObject: [
                    "applied": outcome.applied, "changed": outcome.changed,
                    "targets": plan.targets.map(Self.encode),
                ])
            default: throw ExtensionPeerError.rejected("System does not support this command.")
            }
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "system", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if model == nil { model = RunningAppsModel(operations: operations) }
            if presentation == nil { presentation = SystemPresentationState() }
        case "view":
            guard let model, let presentation else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { SystemPage(model: model, presentation: presentation) }
            )
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown()
            model?.shutdown()
            model = nil
            presentation?.shutdown()
            presentation = nil
        case "status": return ["ok": true, "running": model != nil] as NSDictionary
        default: return ["ok": false] as NSDictionary
        }
        return ["ok": true] as NSDictionary
    }

    private static func encode(_ snapshot: RunningAppSnapshot) -> [String: Any] {
        [
            "pid": snapshot.pid, "name": snapshot.name, "bundleID": snapshot.bundleID ?? "",
            "active": snapshot.active,
        ]
    }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(ExtensionRuntime()).toOpaque())
        })
}
