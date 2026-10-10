import Darwin
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import GhosttyTerminal
import SwiftUI

@MainActor @objc(EdithQuinjetExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var worker: QuinjetWorker?
    private var surface: QuinjetSurface?
    private var startup: Task<Void, Never>?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, let worker = self.worker else { throw ExtensionPeerError.unavailable }
            await self.startup?.value
            if command.hasPrefix("surface.") {
                guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
                return try await surface.execute(command, payload: payload)
            }
            return try await worker.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        startup?.cancel()
        commands.shutdown()
        Task {
            await commands.shutdownAndWait()
            await startup?.value
            await worker?.shutdown()
            worker = nil
            surface = nil
            startup = nil
            GhosttyRuntime.shared.shutdown()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "quinjet", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard worker == nil else { return ["ok": true] as NSDictionary }
            let created = QuinjetWorker()
            worker = created
            surface = QuinjetSurface(worker: created)
            startup = Task { await created.start() }
        case "view":
            guard let worker else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost {
                    QuinjetPage(model: worker.model)
                        .environment(\.automaticViewActionsEnabled, worker.automaticActions)
                        .environment(\.terminalLaunchEnabled, worker.automaticActions)
                })
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
                to: URL(fileURLWithPath: root).appendingPathComponent("quinjet-native-receipt.json")
            )
        }
        try QuinjetPTYBridgeCommand.run(
            encoded: Data(bytes: bytes, count: Int(count)).base64EncodedString())
        return 0
    } catch let error as QuinjetPTYBridgeExit { return error.status } catch {
        FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
        return 1
    }
}
