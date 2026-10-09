import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithCompanionExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: CompanionWorker?
    private var surface: CompanionSurface?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        let worker = worker
        Task {
            await worker?.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "companion", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            let worker = CompanionWorker()
            self.worker = worker
            surface = CompanionSurface(
                monitor: worker.monitor,
                isStopped: { [weak worker] in worker?.isStopped != false },
                open: { [weak worker] id in worker?.openEpisode(id) })
            worker.start()
            TextEditingCommands.install()
        case "view":
            guard let worker, !worker.isStopped else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { CompanionPage(session: worker.workspace) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": IPC.post(IPC.Name.settingsChanged)
        case "stop":
            commands.shutdown()
            let worker = worker
            self.worker = nil
            surface = nil
            TextEditingCommands.shutdown()
            Task { await worker?.shutdown() }
        case "status": return ["ok": true, "running": worker?.isStopped == false] as NSDictionary
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
