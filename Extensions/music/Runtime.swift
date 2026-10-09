import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithMusicExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: MusicWorker?
    private var surface: MusicSurface?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let surface = self?.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        Task {
            await worker?.shutdown(); completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "music", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"],
                SurfaceHostContext.current != nil
            else { return ["ok": false] as NSDictionary }
            if worker == nil { worker = MusicWorker() }
            if let worker, surface == nil {
                surface = MusicSurface(read: worker.read, perform: worker.perform)
            }
            TextEditingCommands.install()
        case "view":
            guard worker != nil else { return ["ok": false] as NSDictionary }
            return NSHostingController(rootView: ExtensionPageHost { MusicRootView() })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            commands.shutdown(); worker?.stop(); worker = nil; surface = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
        case "status": return ["ok": true, "running": worker != nil] as NSDictionary
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
