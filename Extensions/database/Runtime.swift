import AppKit
import DatabaseCore
import DatabaseEngine
import EdithExtensionCommands
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

@MainActor
final class DatabaseService: ExtensionService {
    private unowned let runtime: ExtensionServiceRuntime
    private var session: DatabasePageSession?
    private var surface: DatabaseSurface?
    private var uiCommands: DatabaseUICommands?
    private var uiSessions: [UUID: (DatabaseUIClient, DatabasePageSession)] = [:]
    private var uiDrains: [UUID: Task<Void, Never>] = [:]
    private let uiWork = DatabaseTaskOwner()
    private var cliStreams: ExtensionCLIStreams?
    private var drainEngine: DatabaseEngine?
    private var drainStreams: ExtensionCLIStreams?
    private var drainOwner: DatabasePageSession?
    private var drainUIOwners: [(DatabaseUIClient, DatabasePageSession)] = []

    init(runtime: ExtensionServiceRuntime) { self.runtime = runtime }

    var allowsUIDuringRetirement: Bool { true }
    var isRunning: Bool { session != nil }
    var preparesUIToClose: Bool { true }

    func start(_ context: ExtensionHostContext) -> Bool {
        guard session == nil else { return true }
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
        return true
    }

    func synchronize(_ context: ExtensionHostContext) -> Bool {
        guard !(runtime.isSuspended || runtime.isStopping) else { return false }
        DatabasePrivacy.refresh()
        return true
    }

    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard session != nil else { throw ExtensionPeerError.unavailable }
        if command == "database.cli.catalog" {
            return try DatabaseCLIExecution.catalog(payload)
        }
        if command.hasPrefix("database.cli.stream.") {
            guard let streams = cliStreams else { throw ExtensionPeerError.unavailable }
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
        if let result = try await uiCommands?.invoke(command, payload: payload) {
            return result
        }
        if command == "database.execute" {
            let request = try JSONDecoder().decode(
                DatabaseBrokerCommandRequest.self, from: payload)
            let result = try await DatabaseWorkerClient().send(request)
            return try JSONEncoder().encode(result)
        }
        guard let surface else { throw ExtensionPeerError.unavailable }
        return try await surface.execute(command, payload: payload)
    }

    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool {
        guard uiDrains.count < 16, !configuration.uiOnly,
            configuration.location == "main", configuration.section == "database",
            let client = configuration.engineClient,
            uiSessions.count < 16 || uiSessions[client.presentationID] != nil
        else { return false }
        if uiSessions[client.presentationID] == nil {
            let facade = DatabaseUIClient(engine: client)
            uiSessions[client.presentationID] = (facade, facade.makeSession())
        }
        return true
    }

    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        guard !(runtime.isSuspended || runtime.isStopping) else { return nil }
        if let (client, session) = uiSessions[presentation] {
            return NSHostingController(
                rootView: ExtensionPageHost {
                    DatabaseRemotePage(client: client, session: session)
                })
        }
        guard let session else { return nil }
        return NSHostingController(rootView: ExtensionPageHost { DatabasePage(session: session) })
    }

    func stopUI(for presentation: UUID?) -> [Task<Void, Never>] {
        let retired = uiSessions.values.map { retireUI($0.0, $0.1) }
        uiSessions.removeAll()
        return retired
    }

    func prepareUIToClose(_ presentation: UUID) async -> String? {
        guard !(runtime.isSuspended || runtime.isStopping),
            let (client, _) = uiSessions[presentation]
        else { return nil }
        return await withCheckedContinuation { continuation in
            let launched = uiWork.launch {
                await client.flushColumns()
                continuation.resume(returning: nil)
            }
            if launched == nil { continuation.resume(returning: "Database is stopping.") }
        }
    }

    func cancelPendingWork() {
        drainOwner = session
        drainUIOwners = Array(uiSessions.values)
        drainEngine = DatabaseWorkerClient.suspend()
        drainStreams = cliStreams
        drainOwner?.cancelPendingCommands()
        uiWork.cancel()
        for (client, owner) in drainUIOwners {
            client.cancelPendingCommands()
            owner.cancelPendingCommands()
        }
        drainStreams?.stop()
    }

    func drain() async {
        let engine = drainEngine
        let streams = drainStreams
        let owner = drainOwner
        let uiOwners = drainUIOwners
        await engine?.cancelPendingRequests()
        await streams?.stopAndWait()
        await owner?.cancelAndWait()
        for (client, owner) in uiOwners {
            await client.cancelAndWait()
            await owner.cancelAndWait()
        }
        await uiWork.drain()
        while let task = uiDrains.values.first { await task.value }
        await engine?.cancelAndWait()
    }

    func teardown() async {
        let owner = session
        let originalSurface = surface
        for (client, owner) in uiSessions.values { _ = retireUI(client, owner) }
        uiSessions.removeAll()
        session = nil
        surface = nil
        uiCommands = nil
        cliStreams = nil
        drainEngine = nil
        drainStreams = nil
        drainOwner = nil
        drainUIOwners = []
        while let task = uiDrains.values.first { await task.value }
        await DatabaseWorkerClient.shutdown()
        DatabasePrivacy.shutdown()
        owner?.shutdown()
        originalSurface?.shutdown()
    }

    func perform(_ operation: String, context: NSDictionary) -> NSObject? {
        guard operation == "releaseUI" else { return nil }
        if let value = context["presentationID"] as? String, let id = UUID(uuidString: value),
            let (client, session) = uiSessions.removeValue(forKey: id)
        {
            _ = retireUI(client, session)
        }
        return ["ok": true] as NSDictionary
    }

    private func retireUI(_ client: DatabaseUIClient, _ owner: DatabasePageSession) -> Task<
        Void, Never
    > {
        client.cancelPendingCommands()
        owner.cancelPendingCommands()
        let id = UUID()
        let task = Task { [self, client, owner] in
            defer { uiDrains[id] = nil }
            await client.cancelAndWait()
            await owner.cancelAndWait()
            client.shutdown()
            owner.shutdown()
        }
        uiDrains[id] = task
        return task
    }
}

@MainActor
func makeDatabaseRuntime() -> ExtensionServiceRuntime {
    final class BundleAnchor {}
    return ExtensionServiceRuntime(
        id: "database", role: "app", bundle: Bundle(for: BundleAnchor.self)
    ) { DatabaseService(runtime: $0) }
}

@_cdecl("edith_extension_create")
public func createExtension() -> UnsafeMutableRawPointer? {
    UnsafeMutableRawPointer(
        bitPattern: MainActor.assumeIsolated {
            UInt(bitPattern: Unmanaged.passRetained(makeDatabaseRuntime()).toOpaque())
        })
}
