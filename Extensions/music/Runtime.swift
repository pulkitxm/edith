import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import SwiftUI

@MainActor @objc(EdithMusicExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: MusicWorker?
    private var surface: MusicSurface?
    private var backup: MusicBackupLifecycle?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.worker != nil else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("backup."), let backup = self.backup {
                return try await backup.execute(command, payload: payload)
            }
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        backup?.beginShutdown()
        Task {
            await backup?.shutdown()
            await commands.shutdownAndWait()
            await worker?.shutdown()
            backup = nil; worker = nil; surface = nil
            TextEditingCommands.shutdown(); InputFocus.uninstall()
            completion()
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
            if worker == nil {
                do { backup = MusicBackupLifecycle(provider: try MusicBackupProvider.live()) } catch
                {
                    return ["ok": false, "error": error.localizedDescription] as NSDictionary
                }
                worker = MusicWorker()
            }
            if let worker, surface == nil {
                surface = MusicSurface(read: worker.read, perform: worker.perform)
            }
            TextEditingCommands.install()
        case "view":
            guard worker != nil else { return ["ok": false] as NSDictionary }
            if input["location"] as? String == "home" {
                guard input["section"] as? String == "music",
                    let data = input["tile"] as? Data, data.count <= 65_536,
                    let tile = try? JSONDecoder().decode(SurfaceTile.self, from: data),
                    tile.widget == .music
                else { return ["ok": false] as NSDictionary }
                return NSHostingController(
                    rootView: ExtensionPageHost { MusicHomeScene(tile: tile) })
            }
            if let controller = MusicAuxiliaryScenes.controller(input) { return controller }
            return NSHostingController(rootView: ExtensionPageHost { MusicRootView() })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": break
        case "stop":
            backup?.beginShutdown()
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
