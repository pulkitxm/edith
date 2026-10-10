import AppKit
import DatabaseCore
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor @objc(EdithDatabaseExtensionRuntime)
final class ExtensionRuntime: NSObject {
    private var session: DatabasePageSession?
    private var surface: DatabaseSurface?
    private var uiCommands: DatabaseUICommands?
    private var uiSessions: [UUID: (DatabaseUIClient, DatabasePageSession)] = [:]
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc(prepareUIToClose:completion:)
    func prepareUIToClose(_ presentationID: NSString, completion: @escaping (NSString?) -> Void) {
        guard let id = UUID(uuidString: presentationID as String), let (client, _) = uiSessions[id]
        else {
            completion(nil)
            return
        }
        Task {
            do { try await client.flushColumns(); completion(nil) } catch {
                completion("Database preferences are not saved.")
            }
        }
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.session != nil else { throw ExtensionPeerError.unavailable }
            if command == "database.cli.catalog" {
                return try DatabaseCLIExecution.catalog(payload)
            }
            if command.hasPrefix("database.cli.stream.") {
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try DatabaseCLIEnvironment.$resources.withValue(
                    DatabaseCLIResources(
                        sender: DatabaseWorkerClient(),
                        credentials: { try DatabaseWorkerClient.credentialStore() },
                        runMCP: {
                            throw CLIFailure.unavailable(
                                "database MCP input streaming is unavailable")
                        })
                ) {
                    try streams.invoke(
                        DatabaseCommand.self, operation: command,
                        prefix: "database.cli.stream", payload: payload)
                }
            }
            if command == "database.cli" {
                let request = try JSONDecoder().decode(ExtensionCLIRequest.self, from: payload)
                let reply = try await DatabaseCLIExecution.run(
                    request, sender: DatabaseWorkerClient(),
                    credentials: { try DatabaseWorkerClient.credentialStore() })
                return try JSONEncoder().encode(reply)
            }
            if let result = try await self.uiCommands?.invoke(command, payload: payload) {
                return result
            }
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
        cliStreams?.stop()
        DatabasePrivacy.shutdown()
        session?.shutdown()
        surface?.shutdown()
        surface = nil
        uiCommands = nil
        session = nil
        Task {
            await cliStreams?.stopAndWait()
            cliStreams = nil
            await commands.shutdownAndWait()
            await DatabaseWorkerClient.shutdown()
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
            cliStreams = try? ExtensionCLIStreams(owner: "database")
            DatabaseWorkerClient.start(
                root: ExtensionData.root,
                keychainService: (ProcessInfo.processInfo.environment[
                    "EDITH_APPLICATION_IDENTIFIER"] ?? "edith.extension.fixture")
                    + ".database.secrets")
            DatabasePrivacy.start()
            uiCommands = DatabaseUICommands(
                sender: DatabaseWorkerClient(),
                readColumns: { SharedDefaults.store.data(forKey: "database.columns.layouts.v1") },
                writeColumns: {
                    SharedDefaults.store.set($0, forKey: "database.columns.layouts.v1")
                },
                privateContent: { DatabasePrivacy.hidden },
                credentials: { try DatabaseWorkerClient.credentialStore() },
                prepare: { try await DatabaseMachineForwardRouter.prepare($0) },
                repair: { try await DatabaseWorkerClient.restart() })
            let session = DatabasePageSession()
            self.session = session
            surface = DatabaseSurface(session: session)
        case "view":
            if let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                let (client, session) = uiSessions[id]
            {
                return NSHostingController(
                    rootView: ExtensionPageHost {
                        DatabaseRemotePage(client: client, session: session)
                    })
            }
            guard let session else { return ["ok": false] as NSDictionary }
            return NSHostingController(
                rootView: ExtensionPageHost { DatabasePage(session: session) })
        case "configureUI":
            guard let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == "database", !configuration.uiOnly,
                input["location"] as? String == "main", input["section"] as? String == "database",
                let client = configuration.engineClient,
                uiSessions.count < 16 || uiSessions[client.presentationID] != nil
            else { return ["ok": false] as NSDictionary }
            if uiSessions[client.presentationID] == nil {
                let facade = DatabaseUIClient(engine: client)
                uiSessions[client.presentationID] = (facade, facade.makeSession())
            }
        case "releaseUI":
            if let value = input["presentationID"] as? String, let id = UUID(uuidString: value),
                let (client, session) = uiSessions.removeValue(forKey: id)
            {
                session.shutdown()
                client.shutdown()
            }
        case "stopUI":
            for (client, session) in uiSessions.values {
                session.shutdown()
                client.shutdown()
            }
            uiSessions.removeAll()
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
