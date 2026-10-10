import AppKit
import DatabaseCore
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithDatabaseExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var session: DatabasePageSession?
    private var surface: DatabaseSurface?
    private let commands = ExtensionCommandRegistry()

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.session != nil else { throw ExtensionPeerError.unavailable }
            if command == "database.execute" {
                let request = try JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self, from: payload)
                let result = try await DatabaseWorkerClient().send(request)
                return try JSONEncoder().encode(result)
            }
            guard let surface = self.surface else { throw ExtensionPeerError.unavailable }
            return try await surface.execute(command, payload: payload)
        }
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        commands.shutdown()
        DatabasePrivacy.shutdown()
        session?.shutdown()
        surface?.shutdown()
        surface = nil
        session = nil
        Task {
            await DatabaseWorkerClient.shutdown()
            await commands.shutdownAndWait()
            completion()
        }
    }

    @objc func execute(_ input: NSDictionary) -> NSObject {
        switch input["operation"] as? String {
        case "describe":
            let bundle = Bundle(for: ExtensionRuntime.self)
            return [
                "id": "database", "role": "app",
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard let suite = input["defaultsSuite"] as? String,
                suite == ProcessInfo.processInfo.environment["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard session == nil else { return ["ok": true] as NSDictionary }
            DatabaseWorkerClient.start(
                root: ExtensionData.root,
                keychainService: (ProcessInfo.processInfo.environment[
                    "EDITH_APPLICATION_IDENTIFIER"] ?? "edith.extension.fixture")
                    + ".database.secrets")
            DatabasePrivacy.start()
            let session = DatabasePageSession()
            self.session = session
            surface = DatabaseSurface(session: session)
        case "view":
            guard let session else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { DatabasePage(session: session) })
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize": DatabasePrivacy.refresh()
        case "stop": prepareToStop(completion: {})
        case "status": return ["ok": true, "running": session != nil] as NSDictionary
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
