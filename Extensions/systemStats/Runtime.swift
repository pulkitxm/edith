import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import Foundation

@MainActor
final class ExtensionRuntime: NSObject {
    private var service: SystemStatsStatusItem?

    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let service = self.service else { throw ExtensionPeerError.unavailable }
            return try await SurfaceCommandService.execute(
                providerID: "systemStats", command: command, payload: payload,
                snapshot: { _ in
                    SystemStatsSurface.snapshot(
                        cpu: service.snapshot.cpu, memory: service.snapshot.memory,
                        freeDiskBytes: try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
                            .volumeAvailableCapacityForImportantUsageKey
                        ]).volumeAvailableCapacityForImportantUsage)
                },
                perform: { action in
                    throw ExtensionPeerError.invalidRequest
                })
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "systemStats", "role": "helper",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            if service == nil { service = SystemStatsStatusItem() }
        case "view":
            guard let service else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    PageWorkspace {
                        PageHeader("System Stats")
                    } content: {
                        Form {
                            Section("Usage") { SystemMenuReadings(snapshot: service.snapshot) }
                            Section("Menu Bar") {
                                Text(
                                    "CPU and memory readings refresh every two seconds while this extension is enabled."
                                )
                                .settingsCaption()
                            }
                        }.formStyle(.grouped)
                    }
                })
        case "synchronize": break
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop":
            commands.shutdown()
            service?.shutdown()
            service = nil
        case "status": return ["ok": true, "running": service != nil] as NSDictionary
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
