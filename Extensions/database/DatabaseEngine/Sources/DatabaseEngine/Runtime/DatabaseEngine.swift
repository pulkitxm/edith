import DatabaseCore
import Foundation

public enum DatabaseEngineError: Error, Equatable, Sendable {
    case stopped
    case invalidStorage
}

public actor DatabaseEngine: DatabaseBrokerCommandSending {
    private struct Resources: Sendable {
        let metadataStore: SQLiteDatabaseMetadataStore
        let executor: DatabaseExecutor
        let dispatcher: DatabaseBrokerCommandDispatcher
        let owner: DatabaseRuntimeOwnerToken
    }

    public nonisolated let metadataFile: URL
    private let secretStore: @Sendable () throws -> any DatabaseSecretStore
    private let adapters: @Sendable () -> [any DatabaseAdapter]
    private var resources: Resources?
    private var starting: Task<Resources, Error>?
    private var isStopped = false
    private var sequence: UInt64 = 0

    public init(root: URL, keychainService: String = DatabaseKeychainSecretStore.defaultService) {
        self.init(
            metadataFile: root.appendingPathComponent("metadata.sqlite"),
            secretStore: { try DatabaseKeychainSecretStore(service: keychainService) },
            adapters: DatabaseEngineAdapters.live)
    }

    init(
        metadataFile: URL,
        secretStore: @escaping @Sendable () throws -> any DatabaseSecretStore,
        adapters: @escaping @Sendable () -> [any DatabaseAdapter]
    ) {
        self.metadataFile = metadataFile
        self.secretStore = secretStore
        self.adapters = adapters
    }

    public var isRunning: Bool { resources != nil }

    public func send(_ request: DatabaseBrokerCommandRequest) async throws
        -> DatabaseBrokerCommandResponse
    {
        let resources = try await start()
        guard !isStopped else { throw DatabaseEngineError.stopped }
        try Task.checkCancellation()
        sequence &+= 1
        let envelope = DatabaseBrokerEnvelope(
            requestID: UUID(), operationID: request.operationID, sequence: sequence,
            kind: .request, payload: request)
        return try await resources.dispatcher.dispatch(envelope, responseSequence: 0).payload
    }

    public func shutdown() async {
        isStopped = true
        starting?.cancel()
        let pending = starting
        starting = nil
        let started = try? await pending?.value
        guard let current = resources ?? started else { return }
        resources = nil
        await current.executor.disconnectAll()
        _ = try? await current.metadataStore.releaseRuntimeOwner(current.owner, releasedAt: Date())
    }

    private func start() async throws -> Resources {
        guard !isStopped else { throw DatabaseEngineError.stopped }
        if let resources { return resources }
        if let starting { return try await starting.value }
        let metadataFile = metadataFile
        let secretStore = secretStore
        let adapters = adapters
        let task = Task.detached(priority: .userInitiated) { () throws -> Resources in
            guard metadataFile.isFileURL, !metadataFile.path.utf8.contains(0) else {
                throw DatabaseEngineError.invalidStorage
            }
            try FileManager.default.createDirectory(
                at: metadataFile.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let store = try SQLiteDatabaseMetadataStore(path: metadataFile.path)
            let claim = try await DatabaseRuntimeOwnerFactory.claimReadyOwner(
                from: store, claimedAt: Date())
            do {
                try Task.checkCancellation()
                let executor = try DatabaseExecutor(
                    metadataStore: store, secretStore: try secretStore(),
                    runtimeOwner: claim.owner.token, adapters: adapters())
                let dispatcher = try DatabaseBrokerCommandDispatcher(
                    handler: DatabaseBrokerExecutorHandler(executor: executor))
                return Resources(
                    metadataStore: store, executor: executor, dispatcher: dispatcher,
                    owner: claim.owner.token)
            } catch {
                _ = try? await store.releaseRuntimeOwner(claim.owner.token, releasedAt: Date())
                throw error
            }
        }
        starting = task
        do {
            let started = try await task.value
            starting = nil
            guard !isStopped else {
                await started.executor.disconnectAll()
                _ = try? await started.metadataStore.releaseRuntimeOwner(
                    started.owner, releasedAt: Date())
                throw DatabaseEngineError.stopped
            }
            resources = started
            return started
        } catch {
            starting = nil
            throw error
        }
    }
}

enum DatabaseEngineAdapters {
    @Sendable static func live() -> [any DatabaseAdapter] {
        [
            SQLiteDatabaseAdapter(),
            RedisValkeyDatabaseAdapter(),
            MongoDBDatabaseAdapter(),
            ElasticsearchDatabaseAdapter(),
            OpenSearchDatabaseAdapter(),
            ClickHouseDatabaseAdapter(),
            MySQLDatabaseAdapter(),
            PostgreSQLDatabaseAdapter(),
        ]
    }
}
