import AppKit
import DatabaseCore
import DatabaseEngine
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
    private var commandDrain: Task<Void, Never>?
    private var resourceStop: Task<Void, Never>?
    private var commandsSuspended = false
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let uiWork = DatabaseTaskOwner()
    private let commands = ExtensionCommandRegistry()
    private var cliStreams: ExtensionCLIStreams?

    @objc(prepareUIToClose:completion:)
    func prepareUIToClose(_ presentationID: NSString, completion: @escaping (NSString?) -> Void) {
        guard !commandsSuspended, let id = UUID(uuidString: presentationID as String),
            let (client, _) = uiSessions[id]
        else {
            completion(nil)
            return
        }
        guard
            uiWork.launch({
                await client.flushColumns()
                completion(nil)
            }) != nil
        else { completion("Database is stopping."); return }
    }

    @objc func invoke(_ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.session != nil else { throw ExtensionPeerError.unavailable }
            if command == "database.cli.catalog" {
                return try DatabaseCLIExecution.catalog(payload)
            }
            if command.hasPrefix("database.cli.stream.") {
                guard let streams = self.cliStreams else { throw ExtensionPeerError.unavailable }
                return try await DatabaseCLIEnvironment.$resources.withValue(
                    DatabaseCLIResources(
                        sender: DatabaseWorkerClient(),
                        credentials: { try DatabaseWorkerClient.credentialStore() },
                        runMCP: {
                            try await DatabaseCLIMCP.run()
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

    @objc(suspendCommandsWithCompletion:)
    func suspendCommands(completion: @escaping () -> Void) {
        let drain = beginCommandDrain()
        Task { [self] in
            await drain.value
            await resourceStop?.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginCommandDrain() -> Task<Void, Never> {
        let owner = session
        let uiOwners = Array(uiSessions.values)
        let engine = DatabaseWorkerClient.suspend()
        let streams = cliStreams
        commandsSuspended = true
        _ = commands.suspend()
        if let commandDrain { return commandDrain }
        owner?.cancelPendingCommands()
        uiWork.cancel()
        for (client, owner) in uiOwners {
            client.cancelPendingCommands(); owner.cancelPendingCommands()
        }
        streams?.stop()
        if let commandDrain { return commandDrain }
        let task = Task { [self] in
            await engine?.cancelPendingRequests()
            _ = await commands.suspendAndWait()
            await streams?.stopAndWait()
            await owner?.cancelAndWait()
            for (client, owner) in uiOwners {
                await client.cancelAndWait(); await owner.cancelAndWait()
            }
            await uiWork.drain()
            while let task = uiDrains.values.first { await task.value }
            await engine?.cancelAndWait()
        }
        commandDrain = task
        return task
    }

    @objc(prepareToStopWithCompletion:)
    func prepareToStop(completion: @escaping () -> Void) {
        let stop = beginResourceStop()
        Task { [self] in
            await stop.value
            withExtendedLifetime(self) { completion() }
        }
    }

    private func beginResourceStop() -> Task<Void, Never> {
        if let resourceStop { return resourceStop }
        let owner = session
        let originalSurface = surface
        let drain = beginCommandDrain()
        if let resourceStop { return resourceStop }
        for (client, owner) in uiSessions.values { retireUI(client, owner) }
        uiSessions.removeAll()
        session = nil; surface = nil; uiCommands = nil; cliStreams = nil
        let task = Task { [self] in
            await drain.value
            await commands.shutdownAndWait()
            await DatabaseWorkerClient.shutdown()
            DatabasePrivacy.shutdown()
            owner?.shutdown()
            originalSurface?.shutdown()
        }
        resourceStop = task
        return task
    }

    private func retireUI(_ client: DatabaseUIClient, _ owner: DatabasePageSession) {
        client.cancelPendingCommands()
        owner.cancelPendingCommands()
        let id = UUID()
        uiDrains[id] = Task { [self, client, owner] in
            defer { uiDrains[id] = nil }
            await client.cancelAndWait()
            await owner.cancelAndWait()
            client.shutdown(); owner.shutdown()
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
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            guard let suite = input["defaultsSuite"] as? String,
                suite == ExtensionEnvironment.values["EDITH_SHARED_DEFAULTS_SUITE"]
            else { return ["ok": false] as NSDictionary }
            guard session == nil else { return ["ok": true] as NSDictionary }
            cliStreams = try? ExtensionCLIStreams(owner: "database")
            DatabaseWorkerClient.start(
                root: ExtensionData.root,
                keychainService: DatabaseKeychainSecretStore.service(
                    applicationIdentifier: ExtensionEnvironment.values[
                        "EDITH_APPLICATION_IDENTIFIER"] ?? "edith.extension.fixture",
                    isolatedSuffix: "database.secrets"))
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
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
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
            guard !commandsSuspended, uiDrains.count < 16 else {
                return ["ok": false] as NSDictionary
            }
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
                retireUI(client, session)
            }
        case "stopUI":
            for (client, session) in uiSessions.values { retireUI(client, session) }
            uiSessions.removeAll()
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "synchronize":
            guard !commandsSuspended else { return ["ok": false] as NSDictionary }
            DatabasePrivacy.refresh()
        case "stop":
            _ = beginResourceStop()
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
