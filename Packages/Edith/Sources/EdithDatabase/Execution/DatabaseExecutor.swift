import Foundation

public actor DatabaseExecutor {
    static let maximumActiveOperations = 256
    static let maximumBackgroundTasks = 256
    static let defaultMaximumRetainedServerCancellations = 256
    static let defaultManagementDrainTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let historyFinalizationWarning = DatabaseWarning(
        code: "database.operation.history_not_finalized",
        message:
            "The database action completed, but its durable operation history could not be finalized.",
        severity: .caution)

    private let metadataStore: any DatabaseMetadataStore
    private let executorID = UUID()
    private let secretStore: any DatabaseSecretStore
    private let runtimeOwner: DatabaseRuntimeOwnerToken
    private let sessionPool: DatabaseSessionPool
    private let validator: DatabaseExecutionValidator
    private let currentDate: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID
    private let managementDrainTimeoutNanoseconds: UInt64
    private let maximumRetainedServerCancellations: Int
    private var activeOperations: [DatabaseOperationID: DatabaseExecutorActiveOperation] = [:]
    private var backgroundTasks: [UUID: Task<Void, Never>] = [:]
    private var serverCancellationTasks: [DatabaseOperationID: Task<Void, Never>] = [:]
    private var serverCancellationCompletions:
        [DatabaseOperationID: DatabaseExecutorCompletion<Bool>] = [:]
    private var serverCancellationReservations: Set<DatabaseOperationID> = []
    private var mutatingConnectionIDs: Set<DatabaseConnectionID> = []
    private var isShuttingDown = false

    init(
        metadataStore: any DatabaseMetadataStore,
        secretStore: any DatabaseSecretStore,
        runtimeOwner: DatabaseRuntimeOwnerToken,
        adapters: [any DatabaseAdapter],
        currentDate: @escaping @Sendable () -> Date = { Date() },
        makeUUID: @escaping @Sendable () -> UUID = { UUID() },
        managementDrainTimeoutNanoseconds: UInt64 =
            DatabaseExecutor.defaultManagementDrainTimeoutNanoseconds,
        maximumRetainedServerCancellations: Int =
            DatabaseExecutor.defaultMaximumRetainedServerCancellations
    ) throws(DatabaseAdapterFailure) {
        let registry = try DatabaseAdapterRegistry(adapters: adapters)
        self.metadataStore = metadataStore
        self.secretStore = secretStore
        self.runtimeOwner = runtimeOwner
        sessionPool = DatabaseSessionPool(
            registry: registry,
            secretStore: secretStore,
            currentDate: currentDate)
        validator = DatabaseExecutionValidator(currentDate: currentDate)
        self.currentDate = currentDate
        self.makeUUID = makeUUID
        self.managementDrainTimeoutNanoseconds = max(1, managementDrainTimeoutNanoseconds)
        self.maximumRetainedServerCancellations = max(
            1,
            min(
                Self.defaultMaximumRetainedServerCancellations,
                maximumRetainedServerCancellations))
    }

    public func connect(
        _ request: DatabaseConnectRequest
    ) async -> DatabaseCommandResult<DatabaseConnectResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseConnect,
                definition: definition,
                timeout: definition.limits.connectionTimeout,
                cancellationSupport: .serverSide,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [self, sessionPool, currentDate] context, mapper in
                let lease = try await sessionPool.lease(
                    for: definition,
                    context: context)
                await attachSession(lease.session, to: context.operationID)
                return DatabaseConnectResult(
                    connection: mapper.sanitize(definition.identity),
                    productIdentity: lease.report.productIdentity,
                    capabilities: lease.report,
                    connectedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func disconnect(
        _ request: DatabaseDisconnectRequest
    ) async -> DatabaseCommandResult<DatabaseDisconnectResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseDisconnect,
                definition: definition,
                timeout: definition.limits.operationTimeout,
                cancellationSupport: .cooperative,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [self, sessionPool, currentDate] context, mapper in
                await cancelOtherOperations(
                    connectionID: request.connectionID,
                    excluding: context.operationID)
                try await context.checkCancellation()
                let disconnected = await sessionPool.disconnect(
                    connectionID: request.connectionID)
                try await context.checkCancellation()
                return DatabaseDisconnectResult(
                    connection: mapper.sanitize(definition.identity),
                    disconnected: disconnected,
                    disconnectedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func testConnection(
        _ request: DatabaseConnectionTestRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionTestResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let started = DispatchTime.now().uptimeNanoseconds
            return await execute(
                operation: request.operation,
                kind: .databaseConnectionTest,
                definition: request.connection,
                requiresSavedConnection: false,
                timeout: request.connection.limits.connectionTimeout,
                cancellationSupport: .cooperative,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [sessionPool, currentDate] context, mapper in
                let tested = try await sessionPool.testConnection(
                    definition: request.connection,
                    context: context)
                let finished = DispatchTime.now().uptimeNanoseconds
                let elapsed = finished >= started ? finished - started : 0
                return DatabaseConnectionTestResult(
                    connection: mapper.sanitize(request.connection.identity),
                    productIdentity: tested.productIdentity,
                    capabilities: tested.report,
                    latencyMilliseconds: elapsed / 1_000_000,
                    testedAt: currentDate())
            }
        } catch {
            return failure(error)
        }
    }

    public func capabilities(
        _ request: DatabaseCapabilitiesRequest
    ) async -> DatabaseCommandResult<DatabaseCapabilitiesResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let definition = try await connection(id: request.connectionID)
            return await execute(
                operation: request.operation,
                kind: .databaseCapabilities,
                definition: definition,
                timeout: definition.limits.operationTimeout,
                cancellationSupport: .cooperative,
                retryClassification: .safeIdempotent,
                terminalProgress: .determinate(completed: 1, total: 1, unit: .steps)
            ) { [sessionPool] context, _ in
                let cached = try await sessionPool.lease(
                    for: definition,
                    context: context)
                let lease: DatabaseSessionLease
                if request.resolution == .refresh {
                    lease = try await sessionPool.lease(
                        for: definition,
                        resolution: .refresh,
                        context: context)
                } else {
                    lease = cached
                }
                return DatabaseCapabilitiesResult(
                    report: lease.report,
                    source: lease.reportSource)
            }
        } catch {
            return failure(error)
        }
    }

    public func connections(
        _ request: DatabaseConnectionListRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionListResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let connections = try await metadataStore.connections(matching: request.search)
            try validator.validate(connections: connections, limit: request.search.limit)
            return .success(
                DatabaseConnectionListResult(connections: connections),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func connection(
        _ request: DatabaseConnectionGetRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionGetResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let connection = try await metadataStore.connection(id: request.connectionID)
            if let connection {
                try validator.validateStored(connection)
            }
            return .success(
                DatabaseConnectionGetResult(connection: connection),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func saveConnection(
        _ request: DatabaseConnectionSaveRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionSaveResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard try await metadataStore.connection(id: request.connection.id) == nil else {
                throw DatabaseExecutionValidationError.identifierAlreadyExists(
                    "connection identifier")
            }
            let now = currentDate()
            let connection = managementConnection(
                from: request.connection,
                createdAt: now,
                updatedAt: now,
                lastTestedAt: nil,
                lastUsedAt: nil)
            try validator.validate(connection)
            try Task.checkCancellation()
            let result = try await metadataStore.saveConnection(
                connection,
                replacing: nil,
                owner: runtimeOwner)
            try requireCreated(result, name: "connection identifier")
            return DatabaseConnectionSaveResult(connection: connection)
        }
    }

    public func editConnection(
        _ request: DatabaseConnectionEditRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionEditResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard let stored = try await metadataStore.connection(id: request.connectionID) else {
                throw DatabaseMetadataStoreError.connectionNotFound(request.connectionID)
            }
            try validator.validateStored(stored)
            let connection = managementConnection(
                from: request.connection,
                createdAt: stored.createdAt,
                updatedAt: currentDate(),
                lastTestedAt: stored.lastTestedAt,
                lastUsedAt: stored.lastUsedAt)
            try validator.validate(connection)
            try await withExclusiveConnectionMutation(request.connectionID) { _ in
                try Task.checkCancellation()
                let result = try await metadataStore.saveConnection(
                    connection,
                    replacing: stored,
                    owner: runtimeOwner)
                try requireUpdated(result, connectionID: request.connectionID)
            }
            return DatabaseConnectionEditResult(connection: connection)
        }
    }

    public func duplicateConnection(
        _ request: DatabaseConnectionDuplicateRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionDuplicateResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard let source = try await metadataStore.connection(id: request.connectionID) else {
                throw DatabaseMetadataStoreError.connectionNotFound(request.connectionID)
            }
            try validator.validateStored(source)
            let now = currentDate()
            let connection = managementConnection(
                from: source,
                id: try await unusedConnectionID(),
                displayName: request.displayName,
                createdAt: now,
                updatedAt: now,
                lastTestedAt: nil,
                lastUsedAt: nil)
            try validator.validate(connection)
            try Task.checkCancellation()
            let result = try await metadataStore.saveConnection(
                connection,
                replacing: nil,
                owner: runtimeOwner)
            try requireCreated(result, name: "connection identifier")
            let references = credentialReferences(in: connection)
            return DatabaseConnectionDuplicateResult(
                sourceConnectionID: source.id,
                connection: connection,
                sharesCredentials: !references.isEmpty,
                sharedCredentialReferences: references)
        }
    }

    public func renameConnection(
        _ request: DatabaseConnectionRenameRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionRenameResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard let stored = try await metadataStore.connection(id: request.connectionID) else {
                throw DatabaseMetadataStoreError.connectionNotFound(request.connectionID)
            }
            try validator.validateStored(stored)
            let connection = managementConnection(
                from: stored,
                displayName: request.displayName,
                createdAt: stored.createdAt,
                updatedAt: currentDate(),
                lastTestedAt: stored.lastTestedAt,
                lastUsedAt: stored.lastUsedAt)
            try validator.validate(connection)
            try await withExclusiveConnectionMutation(request.connectionID) { _ in
                try Task.checkCancellation()
                let result = try await metadataStore.saveConnection(
                    connection,
                    replacing: stored,
                    owner: runtimeOwner)
                try requireUpdated(result, connectionID: request.connectionID)
            }
            return DatabaseConnectionRenameResult(connection: connection)
        }
    }

    public func deleteConnection(
        _ request: DatabaseConnectionDeleteRequest
    ) async -> DatabaseCommandResult<DatabaseConnectionDeleteResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            try await withExclusiveConnectionMutation(request.connectionID) { disconnected in
                try Task.checkCancellation()
                let result = try await metadataStore.deleteConnection(
                    id: request.connectionID,
                    owner: runtimeOwner)
                let deleted = try requireDeleted(result)
                return DatabaseConnectionDeleteResult(
                    connectionID: request.connectionID,
                    deleted: deleted,
                    disconnected: disconnected)
            }
        }
    }

    public func savedQueries(
        _ request: DatabaseSavedQueryListRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQueryListResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let queries = try await metadataStore.savedQueries(matching: request.search)
            try validator.validate(queries: queries, limit: request.search.limit)
            try await validateStoredSavedQueries(queries)
            return .success(
                DatabaseSavedQueryListResult(queries: queries),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func savedQuery(
        _ request: DatabaseSavedQueryGetRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQueryGetResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let query = try await metadataStore.savedQuery(id: request.queryID)
            if let query {
                try await validateStoredSavedQueries([query])
            }
            return .success(
                DatabaseSavedQueryGetResult(query: query),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func saveSavedQuery(
        _ request: DatabaseSavedQuerySaveRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQuerySaveResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            let stored = try await metadataStore.savedQuery(id: request.query.id)
            if let stored {
                try await validateStoredSavedQueries([stored])
            }
            let now = currentDate()
            let query = managementSavedQuery(
                from: request.query,
                createdAt: stored?.createdAt ?? now,
                updatedAt: now)
            let connection = try await validateSavedQueryConnection(
                query,
                requiresConnection: true)
            try Task.checkCancellation()
            let result = try await metadataStore.saveQuery(
                query,
                replacing: stored,
                validatedAgainst: connection,
                owner: runtimeOwner)
            try requireSavedQueryWrite(
                result,
                creating: stored == nil,
                queryID: query.id,
                connectionID: query.connectionID)
            return DatabaseSavedQuerySaveResult(query: query, created: stored == nil)
        }
    }

    public func duplicateSavedQuery(
        _ request: DatabaseSavedQueryDuplicateRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQueryDuplicateResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard let source = try await metadataStore.savedQuery(id: request.queryID) else {
                throw DatabaseMetadataStoreError.savedQueryNotFound(request.queryID)
            }
            try await validateStoredSavedQueries([source])
            let now = currentDate()
            let query = managementSavedQuery(
                from: source,
                id: try await unusedSavedQueryID(),
                name: request.name,
                createdAt: now,
                updatedAt: now)
            let connection = try await validateSavedQueryConnection(
                query,
                requiresConnection: true)
            try Task.checkCancellation()
            let result = try await metadataStore.saveQuery(
                query,
                replacing: nil,
                validatedAgainst: connection,
                owner: runtimeOwner)
            try requireSavedQueryWrite(
                result,
                creating: true,
                queryID: query.id,
                connectionID: query.connectionID)
            return DatabaseSavedQueryDuplicateResult(
                sourceQueryID: source.id,
                query: query)
        }
    }

    public func renameSavedQuery(
        _ request: DatabaseSavedQueryRenameRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQueryRenameResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            guard let stored = try await metadataStore.savedQuery(id: request.queryID) else {
                throw DatabaseMetadataStoreError.savedQueryNotFound(request.queryID)
            }
            try await validateStoredSavedQueries([stored])
            let query = managementSavedQuery(
                from: stored,
                name: request.name,
                createdAt: stored.createdAt,
                updatedAt: currentDate())
            let connection = try await validateSavedQueryConnection(
                query,
                requiresConnection: true)
            try Task.checkCancellation()
            let result = try await metadataStore.saveQuery(
                query,
                replacing: stored,
                validatedAgainst: connection,
                owner: runtimeOwner)
            try requireSavedQueryWrite(
                result,
                creating: false,
                queryID: query.id,
                connectionID: query.connectionID)
            return DatabaseSavedQueryRenameResult(query: query)
        }
    }

    public func deleteSavedQuery(
        _ request: DatabaseSavedQueryDeleteRequest
    ) async -> DatabaseCommandResult<DatabaseSavedQueryDeleteResult> {
        do {
            try validator.validate(request)
        } catch {
            return failure(error)
        }
        return await performManagementMutation {
            try Task.checkCancellation()
            let result = try await metadataStore.deleteSavedQuery(
                id: request.queryID,
                owner: runtimeOwner)
            let deleted = try requireDeleted(result)
            return DatabaseSavedQueryDeleteResult(queryID: request.queryID, deleted: deleted)
        }
    }

    public func operation(
        _ request: DatabaseOperationGetRequest
    ) async -> DatabaseCommandResult<DatabaseOperationGetResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let operation = try await metadataStore.operation(id: request.operationID)
            return .success(
                DatabaseOperationGetResult(operation: operation),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func operations(
        _ request: DatabaseOperationListRequest
    ) async -> DatabaseCommandResult<DatabaseOperationListResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            let operations = try await metadataStore.operations(matching: request.search)
            return .success(
                DatabaseOperationListResult(operations: operations),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    public func cancel(
        _ request: DatabaseOperationCancelRequest
    ) async -> DatabaseCommandResult<DatabaseOperationCancelResult> {
        do {
            try validator.validate(request)
            try await requireActiveOwner()
            if let cancellation = await cancelActiveOperation(
                request.operationID,
                reason: .userRequested)
            {
                let warning =
                    cancellation.disposition == .accepted && !cancellation.historyFinalized
                    ? Self.historyFinalizationWarning
                    : nil
                return .success(
                    DatabaseOperationCancelResult(
                        operationID: request.operationID,
                        disposition: cancellation.disposition,
                        cancellationSupport: cancellation.cancellationSupport,
                        operation: cancellation.operation),
                    metadata: completeMetadata(warning: warning))
            }
            let operation = try await metadataStore.operation(id: request.operationID)
            let disposition: DatabaseOperationCancellationDisposition
            if let operation {
                disposition = Self.isTerminal(operation.state) ? .alreadyFinished : .notActive
            } else {
                disposition = .notFound
            }
            return .success(
                DatabaseOperationCancelResult(
                    operationID: request.operationID,
                    disposition: disposition,
                    cancellationSupport: operation?.cancellationSupport ?? .unavailable,
                    operation: operation),
                metadata: completeMetadata())
        } catch {
            return failure(error)
        }
    }

    func disconnectAll() async {
        guard !isShuttingDown else { return }
        isShuttingDown = true
        let operationIDs = Array(activeOperations.keys)
        for operationID in operationIDs {
            _ = beginActiveCancellation(
                operationID,
                reason: .sessionDisconnected)
        }
        let deadline = Self.deadline(
            after: managementDrainTimeoutNanoseconds)
        for operationID in operationIDs {
            await waitForServerCancellation(operationID, until: deadline)
        }
        let disconnectionCompletion = DatabaseExecutorCompletion<Bool>()
        let disconnectionTask = Task { [sessionPool] in
            await sessionPool.disconnectAll()
            await disconnectionCompletion.resolve(true)
        }
        _ = await waitForCompletion(disconnectionCompletion, until: deadline)
        await DatabaseManagementMutationCoordinator.shared.unregisterExecutor(
            owner: runtimeOwner,
            executorID: executorID)
        disconnectionTask.cancel()
        for task in backgroundTasks.values {
            task.cancel()
        }
        for task in serverCancellationTasks.values {
            task.cancel()
        }
    }

    func activeOperationCount() -> Int {
        activeOperations.count
    }

    func backgroundTaskCount() -> Int {
        backgroundTasks.count + serverCancellationTasks.count
    }

    func retainedServerCancellationCount() -> Int {
        serverCancellationReservations.count
    }

    func managementMutationWaiterCount() async -> Int {
        await DatabaseManagementMutationCoordinator.shared.waiterCount(runtimeOwner)
    }

    func managementRetainedCoordinationCount() async -> Int {
        await DatabaseManagementMutationCoordinator.shared.retainedCoordinationCount(
            runtimeOwner)
    }

    func managementRetainedCallbackCount(
        connectionID: DatabaseConnectionID
    ) async -> Int {
        await DatabaseManagementMutationCoordinator.shared.retainedCallbackCount(
            owner: runtimeOwner,
            connectionID: connectionID)
    }

    func managementDisconnectionCompleted(
        connectionID: DatabaseConnectionID
    ) async -> Bool {
        await DatabaseManagementMutationCoordinator.shared.disconnectionCompleted(
            owner: runtimeOwner,
            connectionID: connectionID)
    }

    static func retireRuntimeOwnerCoordination(
        _ owner: DatabaseRuntimeOwnerToken
    ) async {
        await DatabaseManagementMutationCoordinator.shared.retireOwner(owner)
    }

    private func requireActiveOwner() async throws {
        guard let owner = try await metadataStore.runtimeOwner(),
            owner.token == runtimeOwner,
            owner.isReady
        else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
    }

    private func connection(
        id: DatabaseConnectionID
    ) async throws -> DatabaseConnectionDefinition {
        let globallyMutating =
            await DatabaseManagementMutationCoordinator.shared.isExclusivelyMutating(
                owner: runtimeOwner,
                connectionID: id)
        guard !mutatingConnectionIDs.contains(id), !globallyMutating else {
            throw DatabaseExecutionValidationError.connectionDefinitionChanged(id)
        }
        guard let definition = try await metadataStore.connection(id: id) else {
            _ = await sessionPool.disconnect(connectionID: id)
            throw DatabaseMetadataStoreError.connectionNotFound(id)
        }
        return definition
    }

    private func disconnectConnectionSession(
        _ connectionID: DatabaseConnectionID
    ) async -> Bool {
        await sessionPool.disconnect(connectionID: connectionID)
    }

    private func performManagementMutation<Payload: Sendable>(
        _ body: () async throws -> Payload
    ) async -> DatabaseCommandResult<Payload> {
        do {
            try await requireActiveOwner()
            try await DatabaseManagementMutationCoordinator.shared.acquire(runtimeOwner)
        } catch {
            return failure(error)
        }
        do {
            try Task.checkCancellation()
            try await requireActiveOwner()
            try Task.checkCancellation()
            let payload = try await body()
            await DatabaseManagementMutationCoordinator.shared.release(runtimeOwner)
            return .success(payload, metadata: completeMetadata())
        } catch {
            await DatabaseManagementMutationCoordinator.shared.release(runtimeOwner)
            return failure(error)
        }
    }

    private func withExclusiveConnectionMutation<Payload: Sendable>(
        _ connectionID: DatabaseConnectionID,
        _ body: (Bool) async throws -> Payload
    ) async throws -> Payload {
        guard mutatingConnectionIDs.insert(connectionID).inserted else {
            throw DatabaseExecutionValidationError.connectionDefinitionChanged(connectionID)
        }
        var coordinationPrepared = false
        do {
            try Task.checkCancellation()
            let disconnected = try await DatabaseManagementMutationCoordinator.shared
                .beginExclusiveConnectionMutation(
                    owner: runtimeOwner,
                    connectionID: connectionID,
                    timeoutNanoseconds: managementDrainTimeoutNanoseconds)
            coordinationPrepared = true
            try Task.checkCancellation()
            let payload = try await body(disconnected)
            mutatingConnectionIDs.remove(connectionID)
            await DatabaseManagementMutationCoordinator.shared.endExclusiveConnectionMutation(
                owner: runtimeOwner,
                connectionID: connectionID,
                discardCoordination: true)
            return payload
        } catch {
            mutatingConnectionIDs.remove(connectionID)
            await DatabaseManagementMutationCoordinator.shared.endExclusiveConnectionMutation(
                owner: runtimeOwner,
                connectionID: connectionID,
                discardCoordination: coordinationPrepared)
            throw error
        }
    }

    private func requireCreated(
        _ result: DatabaseOwnedMetadataWriteResult,
        name: String
    ) throws {
        switch result {
        case .saved:
            return
        case .identifierExists, .resourceChanged:
            throw DatabaseExecutionValidationError.identifierAlreadyExists(name)
        case .runtimeOwnerNotActive:
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        case .resourceMissing, .incompatibleSavedQueries,
            .referencedConnectionChangedOrMissing:
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an invalid create result.")
        }
    }

    private func requireUpdated(
        _ result: DatabaseOwnedMetadataWriteResult,
        connectionID: DatabaseConnectionID
    ) throws {
        switch result {
        case .saved:
            return
        case .resourceMissing:
            throw DatabaseMetadataStoreError.connectionNotFound(connectionID)
        case .resourceChanged:
            throw DatabaseExecutionValidationError.connectionDefinitionChanged(connectionID)
        case .incompatibleSavedQueries:
            throw DatabaseExecutionValidationError.invalidDefinition(
                "The connection product is incompatible with a linked saved query.")
        case .runtimeOwnerNotActive:
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        case .identifierExists, .referencedConnectionChangedOrMissing:
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an invalid update result.")
        }
    }

    private func requireSavedQueryWrite(
        _ result: DatabaseOwnedMetadataWriteResult,
        creating: Bool,
        queryID: DatabaseSavedQueryID,
        connectionID: DatabaseConnectionID? = nil
    ) throws {
        switch result {
        case .saved:
            return
        case .identifierExists where creating:
            throw DatabaseExecutionValidationError.identifierAlreadyExists(
                "saved query identifier")
        case .resourceMissing where !creating:
            throw DatabaseMetadataStoreError.savedQueryNotFound(queryID)
        case .resourceChanged where !creating:
            throw DatabaseExecutionValidationError.savedQueryDefinitionChanged(queryID)
        case .referencedConnectionChangedOrMissing:
            if let connectionID {
                throw DatabaseExecutionValidationError.connectionDefinitionChanged(connectionID)
            }
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store rejected an unbound saved query.")
        case .runtimeOwnerNotActive:
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        case .identifierExists, .resourceMissing, .resourceChanged,
            .incompatibleSavedQueries:
            throw DatabaseExecutionValidationError.invalidAdapterResult(
                "The metadata store returned an invalid saved query result.")
        }
    }

    private func requireDeleted(
        _ result: DatabaseOwnedMetadataDeleteResult
    ) throws -> Bool {
        switch result {
        case .deleted:
            true
        case .notFound:
            false
        case .runtimeOwnerNotActive:
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
    }

    private func validateSavedQueryConnection(
        _ query: DatabaseSavedQuery,
        requiresConnection: Bool
    ) async throws -> DatabaseConnectionDefinition? {
        guard let connectionID = query.connectionID else {
            try validator.validate(query, connection: nil)
            return nil
        }
        let connection = try await metadataStore.connection(id: connectionID)
        if requiresConnection, connection == nil {
            throw DatabaseMetadataStoreError.connectionNotFound(connectionID)
        }
        if let connection {
            try validator.validateStored(connection)
        }
        try validator.validate(query, connection: connection)
        return connection
    }

    private func validateStoredSavedQueries(
        _ queries: [DatabaseSavedQuery]
    ) async throws {
        let connectionIDs = Set(queries.compactMap(\.connectionID))
        var connections: [DatabaseConnectionID: DatabaseConnectionDefinition] = [:]
        for connectionID in connectionIDs {
            if let connection = try await metadataStore.connection(id: connectionID) {
                try validator.validateStored(connection)
                connections[connectionID] = connection
            }
        }
        for query in queries {
            try validator.validateStored(
                query,
                connection: query.connectionID.flatMap { connections[$0] })
        }
    }

    private func unusedConnectionID() async throws -> DatabaseConnectionID {
        for _ in 0..<16 {
            let identifier = DatabaseConnectionID(rawValue: makeUUID())
            if identifier.rawValue != Self.zeroUUID,
                try await metadataStore.connection(id: identifier) == nil
            {
                return identifier
            }
        }
        throw DatabaseExecutionValidationError.identifierAlreadyExists(
            "connection identifier")
    }

    private func unusedSavedQueryID() async throws -> DatabaseSavedQueryID {
        for _ in 0..<16 {
            let identifier = DatabaseSavedQueryID(rawValue: makeUUID())
            if identifier.rawValue != Self.zeroUUID,
                try await metadataStore.savedQuery(id: identifier) == nil
            {
                return identifier
            }
        }
        throw DatabaseExecutionValidationError.identifierAlreadyExists(
            "saved query identifier")
    }

    private func managementConnection(
        from source: DatabaseConnectionDefinition,
        id: DatabaseConnectionID? = nil,
        displayName: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastTestedAt: Date?,
        lastUsedAt: Date?
    ) -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id ?? source.id,
            displayName: displayName ?? source.displayName,
            productHint: source.productHint,
            location: source.location,
            username: source.username,
            namespaces: source.namespaces,
            deploymentMode: source.deploymentMode,
            authentication: source.authentication,
            tls: source.tls,
            tunnel: source.tunnel,
            limits: source.limits,
            readOnlyPolicy: source.readOnlyPolicy,
            productionPolicy: source.productionPolicy,
            environment: source.environment,
            group: source.group,
            tags: source.tags,
            color: source.color,
            isFavorite: source.isFavorite,
            options: source.options,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastTestedAt: lastTestedAt,
            lastUsedAt: lastUsedAt)
    }

    private func managementSavedQuery(
        from source: DatabaseSavedQuery,
        id: DatabaseSavedQueryID? = nil,
        name: String? = nil,
        createdAt: Date,
        updatedAt: Date
    ) -> DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: id ?? source.id,
            connectionID: source.connectionID,
            name: name ?? source.name,
            language: source.language,
            text: source.text,
            tags: source.tags,
            isFavorite: source.isFavorite,
            createdAt: createdAt,
            updatedAt: updatedAt)
    }

    private func credentialReferences(
        in connection: DatabaseConnectionDefinition
    ) -> [DatabaseSecretReference] {
        connection.authentication.secretReferences
            + [connection.tls.clientPrivateKey].compactMap { $0 }
    }

    private func execute<Payload: Sendable>(
        operation: DatabaseOperationContext,
        kind: DatabaseOperationKind,
        definition: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier? = nil,
        requiresSavedConnection: Bool = true,
        timeout: DatabaseTimeout,
        cancellationSupport: DatabaseCancellationSupport,
        retryClassification: DatabaseRetryClassification,
        terminalProgress: DatabaseOperationProgress?,
        body:
            @escaping @Sendable (
                DatabaseAdapterOperationContext,
                DatabaseExecutionErrorMapper
            ) async throws -> Payload
    ) async -> DatabaseCommandResult<Payload> {
        let reservationMapper = DatabaseExecutionErrorMapper()
        let permitID = UUID()
        let admission = DatabaseExecutorOperationAdmission()
        let admitted = await DatabaseManagementMutationCoordinator.shared.reserveOperation(
            owner: runtimeOwner,
            connectionID: definition.id,
            permitID: permitID,
            executorID: executorID,
            cancel: { await admission.cancel() },
            disconnect: { [weak self] in
                await self?.disconnectConnectionSession(definition.id) ?? false
            })
        guard admitted else {
            return .failure(
                reservationMapper.map(
                    DatabaseExecutionValidationError.connectionDefinitionChanged(definition.id),
                    target: target),
                metadata: completeMetadata())
        }
        let result = await executeAdmitted(
            operation: operation,
            kind: kind,
            definition: definition,
            target: target,
            requiresSavedConnection: requiresSavedConnection,
            timeout: timeout,
            cancellationSupport: cancellationSupport,
            retryClassification: retryClassification,
            terminalProgress: terminalProgress,
            admission: admission,
            body: body)
        await DatabaseManagementMutationCoordinator.shared.releaseOperation(
            owner: runtimeOwner,
            connectionID: definition.id,
            permitID: permitID)
        return result
    }

    private func executeAdmitted<Payload: Sendable>(
        operation: DatabaseOperationContext,
        kind: DatabaseOperationKind,
        definition: DatabaseConnectionDefinition,
        target: DatabaseTargetIdentifier?,
        requiresSavedConnection: Bool,
        timeout: DatabaseTimeout,
        cancellationSupport: DatabaseCancellationSupport,
        retryClassification: DatabaseRetryClassification,
        terminalProgress: DatabaseOperationProgress?,
        admission: DatabaseExecutorOperationAdmission,
        body:
            @escaping @Sendable (
                DatabaseAdapterOperationContext,
                DatabaseExecutionErrorMapper
            ) async throws -> Payload
    ) async -> DatabaseCommandResult<Payload> {
        let reservationMapper = DatabaseExecutionErrorMapper()
        let startedAt = currentDate()
        let effectiveOperation = effectiveOperation(
            operation,
            timeout: timeout,
            startedAt: startedAt)
        let reservedRunning = DatabaseOperationRecordSummary(
            id: effectiveOperation.operationID,
            kind: kind,
            state: .running,
            connection: reservationMapper.sanitize(definition.identity),
            target: reservationMapper.sanitize(target),
            startedAt: startedAt,
            deadline: effectiveOperation.deadline,
            progress: .indeterminate(),
            cancellationSupport: cancellationSupport,
            retryClassification: retryClassification)
        let cancellation = DatabaseAdapterCancellationSignal()
        do {
            try registerActiveOperation(
                reservedRunning,
                cancellation: cancellation)
        } catch {
            return .failure(
                reservationMapper.map(error, target: target),
                metadata: completeMetadata())
        }
        await admission.attach { [weak self] in
            _ = await self?.cancelActiveOperation(
                effectiveOperation.operationID,
                reason: .sessionDisconnected)
            await self?.waitForServerCancellation(effectiveOperation.operationID)
        }
        do {
            let reservation =
                if requiresSavedConnection {
                    try await metadataStore.reserveOperation(
                        reservedRunning,
                        for: definition,
                        owner: runtimeOwner)
                } else {
                    try await metadataStore.reserveEphemeralOperation(
                        reservedRunning,
                        owner: runtimeOwner)
                }
            switch reservation {
            case .reserved:
                markOperationReserved(effectiveOperation.operationID)
            case .operationIdentifierExists:
                throw DatabaseExecutionValidationError.operationIdentifierAlreadyExists(
                    effectiveOperation.operationID)
            case .connectionChangedOrMissing:
                throw DatabaseExecutionValidationError.connectionDefinitionChanged(
                    definition.id)
            case .runtimeOwnerNotActive:
                throw DatabaseExecutionValidationError.runtimeOwnerNotActive
            }
        } catch {
            await finishActiveOperation(effectiveOperation.operationID)
            return .failure(
                reservationMapper.map(error, target: target),
                metadata: completeMetadata())
        }

        beginDeadline(
            operationID: effectiveOperation.operationID,
            deadline: effectiveOperation.deadline)
        let context = DatabaseAdapterOperationContext(
            operation: effectiveOperation,
            cancellation: cancellation)

        var mapper = reservationMapper
        var running = reservedRunning
        do {
            try await checkControl(context)
            mapper = try await controlledErrorMapper(
                for: definition,
                context: context)
            try await checkControl(context)
            running = DatabaseOperationRecordSummary(
                id: reservedRunning.id,
                kind: reservedRunning.kind,
                state: reservedRunning.state,
                connection: mapper.sanitize(definition.identity),
                target: mapper.sanitize(target),
                startedAt: reservedRunning.startedAt,
                deadline: reservedRunning.deadline,
                progress: reservedRunning.progress,
                cancellationSupport: reservedRunning.cancellationSupport,
                retryClassification: reservedRunning.retryClassification)
            replaceActiveRunning(running)
            guard
                try await metadataStore.transitionOperation(
                    running,
                    from: [.running],
                    owner: runtimeOwner)
            else {
                if let reason = await cancellation.reason() {
                    throw DatabaseExecutorControlFailure(reason)
                }
                throw DatabaseExecutionValidationError.runtimeOwnerNotActive
            }
        } catch {
            return await failureResult(
                error,
                mapper: mapper,
                target: target,
                running: running,
                terminalProgress: terminalProgress,
                cancellation: cancellation)
        }

        do {
            try await checkControl(context)
            let bodyTask = Task {
                try await body(context, mapper)
            }
            await attachExecutionCancellation(
                { bodyTask.cancel() },
                to: effectiveOperation.operationID)
            let payload = try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: { [weak self] in
                bodyTask.cancel()
                Task {
                    _ = await self?.cancelActiveOperation(
                        effectiveOperation.operationID,
                        reason: .userRequested)
                }
            }
            try await checkControl(context)
            let terminal = terminalSummary(
                from: running,
                state: .succeeded,
                progress: terminalProgress,
                error: nil)
            let finalized = await finalizeOperation(terminal, from: [.running])
            if !finalized, let reason = await cancellation.reason() {
                throw DatabaseExecutorControlFailure(reason)
            }
            await finishActiveOperation(effectiveOperation.operationID)
            let reported =
                finalized
                ? terminal
                : terminalSummary(
                    from: running,
                    state: .succeeded,
                    progress: terminalProgress,
                    warnings: [Self.historyFinalizationWarning],
                    error: nil)
            return .success(
                payload,
                metadata: DatabaseResultMetadata(
                    operation: reported,
                    completeness: DatabaseResultCompleteness(state: .complete),
                    warnings: finalized ? [] : [Self.historyFinalizationWarning]))
        } catch {
            return await failureResult(
                error,
                mapper: mapper,
                target: target,
                running: running,
                terminalProgress: terminalProgress,
                cancellation: cancellation)
        }
    }

    private func failureResult<Payload: Sendable>(
        _ error: any Error,
        mapper: DatabaseExecutionErrorMapper,
        target: DatabaseTargetIdentifier?,
        running: DatabaseOperationRecordSummary,
        terminalProgress: DatabaseOperationProgress?,
        cancellation: DatabaseAdapterCancellationSignal
    ) async -> DatabaseCommandResult<Payload> {
        var reason = await cancellation.reason()
        var envelope =
            reason.map {
                controlEnvelope($0, mapper: mapper, target: target)
            } ?? mapper.map(error, target: target)
        var state: DatabaseOperationState =
            envelope.category == .cancelled
            ? .cancelled
            : .failed
        var terminal = terminalSummary(
            from: running,
            state: state,
            progress: terminalProgress,
            error: envelope)
        var finalized = await finalizeOperation(
            terminal,
            from: reason == nil ? [.running] : [.running, .cancelling])
        if !finalized, reason == nil, let lateReason = await cancellation.reason() {
            reason = lateReason
            envelope = controlEnvelope(lateReason, mapper: mapper, target: target)
            state = envelope.category == .cancelled ? .cancelled : .failed
            terminal = terminalSummary(
                from: running,
                state: state,
                progress: terminalProgress,
                error: envelope)
            finalized = await finalizeOperation(
                terminal,
                from: [.running, .cancelling])
        }
        await finishActiveOperation(running.id)
        let reported =
            finalized
            ? terminal
            : terminalSummary(
                from: running,
                state: state,
                progress: terminalProgress,
                warnings: [Self.historyFinalizationWarning],
                error: envelope)
        return .failure(
            envelope,
            metadata: DatabaseResultMetadata(
                operation: reported,
                completeness: DatabaseResultCompleteness(state: .complete),
                warnings: finalized ? [] : [Self.historyFinalizationWarning]))
    }

    private func effectiveOperation(
        _ operation: DatabaseOperationContext,
        timeout: DatabaseTimeout,
        startedAt: Date
    ) -> DatabaseOperationContext {
        let configuredDeadline = startedAt.addingTimeInterval(
            Double(timeout.milliseconds) / 1_000)
        let deadline =
            operation.deadline.map { min($0, configuredDeadline) }
            ?? configuredDeadline
        return DatabaseOperationContext(
            operationID: operation.operationID,
            deadline: deadline)
    }

    private func registerActiveOperation(
        _ running: DatabaseOperationRecordSummary,
        cancellation: DatabaseAdapterCancellationSignal
    ) throws {
        guard !isShuttingDown else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
        guard activeOperations[running.id] == nil else {
            throw DatabaseExecutionValidationError.operationIdentifierAlreadyExists(running.id)
        }
        guard !serverCancellationReservations.contains(running.id) else {
            throw DatabaseExecutionValidationError.operationIdentifierAlreadyExists(running.id)
        }
        guard activeOperations.count < Self.maximumActiveOperations else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "active database operations",
                actual: activeOperations.count + 1,
                maximum: Self.maximumActiveOperations)
        }
        if running.cancellationSupport == .serverSide {
            guard
                serverCancellationReservations.count < maximumRetainedServerCancellations
            else {
                throw DatabaseExecutionValidationError.limitExceeded(
                    name: "retained server cancellations",
                    actual: serverCancellationReservations.count + 1,
                    maximum: maximumRetainedServerCancellations)
            }
            serverCancellationReservations.insert(running.id)
        }
        activeOperations[running.id] = DatabaseExecutorActiveOperation(
            running: running,
            cancellation: cancellation)
    }

    private func markOperationReserved(_ operationID: DatabaseOperationID) {
        guard var active = activeOperations[operationID] else { return }
        active.reservationState = .owned
        activeOperations[operationID] = active
    }

    private func replaceActiveRunning(_ running: DatabaseOperationRecordSummary) {
        guard var active = activeOperations[running.id] else { return }
        active.running = running
        activeOperations[running.id] = active
    }

    private func beginDeadline(
        operationID: DatabaseOperationID,
        deadline: Date?
    ) {
        guard var active = activeOperations[operationID], let deadline else { return }
        let delay = max(0, deadline.timeIntervalSince(currentDate()))
        let maximumDelay = Double(UInt64.max - 1_000_000) / 1_000_000_000
        let nanoseconds =
            delay >= maximumDelay
            ? UInt64.max - 1_000_000
            : UInt64(delay * 1_000_000_000)
        let task = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            _ = await self?.cancelActiveOperation(
                operationID,
                reason: .deadlineExceeded)
        }
        active.deadlineTask = task
        activeOperations[operationID] = active
    }

    private func attachSession(
        _ session: any DatabaseAdapterSession,
        to operationID: DatabaseOperationID
    ) async {
        guard var active = activeOperations[operationID] else { return }
        if active.session == nil {
            active.session = session
        }
        activeOperations[operationID] = active
        if active.cancellationAccepted {
            _ = scheduleServerCancellation(operationID)
        }
    }

    private func attachExecutionCancellation(
        _ cancellation: @escaping @Sendable () -> Void,
        to operationID: DatabaseOperationID
    ) async {
        guard var active = activeOperations[operationID] else {
            cancellation()
            return
        }
        active.executionCancellation = cancellation
        let shouldCancel = active.cancellationReason != nil
        activeOperations[operationID] = active
        if shouldCancel {
            cancellation()
        }
    }

    private func cancelOtherOperations(
        connectionID: DatabaseConnectionID,
        excluding excludedOperationID: DatabaseOperationID
    ) async {
        await cancelOperations(
            connectionID: connectionID,
            excluding: excludedOperationID)
    }

    private func cancelOperations(
        connectionID: DatabaseConnectionID,
        excluding excludedOperationID: DatabaseOperationID? = nil
    ) async {
        let operationIDs = activeOperations.values.compactMap { active in
            active.running.id != excludedOperationID
                && active.running.connection.id == connectionID
                ? active.running.id
                : nil
        }
        for operationID in operationIDs {
            _ = await cancelActiveOperation(
                operationID,
                reason: .sessionDisconnected)
            await waitForServerCancellation(operationID)
        }
    }

    private func cancelActiveOperation(
        _ operationID: DatabaseOperationID,
        reason: DatabaseAdapterCancellationReason
    ) async -> DatabaseExecutorActiveCancellation? {
        switch beginActiveCancellation(operationID, reason: reason) {
        case let .owned(task):
            return await task.value
        case let .pending(task):
            await task.value
            return nil
        case .unavailable:
            return nil
        }
    }

    private func beginActiveCancellation(
        _ operationID: DatabaseOperationID,
        reason: DatabaseAdapterCancellationReason
    ) -> DatabaseExecutorCancellationWork {
        guard var active = activeOperations[operationID] else { return .unavailable }
        if let cancellationTask = active.cancellationTask {
            return .owned(cancellationTask)
        }
        if active.cancellationReason != nil {
            if active.reservationState == .owned {
                _ = acceptCancellationAndSchedule(operationID)
            }
            return .unavailable
        }
        active.cancellationReason = reason
        let cancellationSignal = active.cancellation
        let executionCancellation = active.executionCancellation
        activeOperations[operationID] = active
        guard active.reservationState == .owned else {
            return .pending(
                Task {
                    await cancellationSignal.cancel(reason)
                    executionCancellation?()
                })
        }
        let support = acceptCancellationAndSchedule(operationID)
        let metadataStore = metadataStore
        let runtimeOwner = runtimeOwner
        let cancelling = operationSummary(
            from: active.running,
            state: .cancelling,
            finishedAt: nil,
            progress: active.running.progress,
            warnings: active.running.warnings,
            error: nil)
        let cancellationSupport = active.running.cancellationSupport
        let cancellationWork = Task {
            await cancellationSignal.cancel(reason)
            executionCancellation?()
            var stored: DatabaseOperationRecordSummary?
            var transitioned = false
            do {
                transitioned = try await metadataStore.transitionOperation(
                    cancelling,
                    from: [.running],
                    owner: runtimeOwner)
                if !transitioned {
                    stored = try await metadataStore.operation(id: operationID)
                } else {
                    stored = nil
                }
            } catch {
                transitioned = false
                stored = nil
            }

            if !transitioned {
                if let stored, Self.isTerminal(stored.state) {
                    return DatabaseExecutorActiveCancellation(
                        disposition: .alreadyFinished,
                        operation: stored,
                        cancellationSupport: stored.cancellationSupport,
                        historyFinalized: true)
                }
                return DatabaseExecutorActiveCancellation(
                    disposition: .accepted,
                    operation: stored,
                    cancellationSupport: cancellationSupport,
                    historyFinalized: false)
            }
            return DatabaseExecutorActiveCancellation(
                disposition: .accepted,
                operation: cancelling,
                cancellationSupport: support,
                historyFinalized: transitioned)
        }
        if var scheduled = activeOperations[operationID] {
            scheduled.cancellationTask = cancellationWork
            activeOperations[operationID] = scheduled
        }
        return .owned(cancellationWork)
    }

    private func scheduleServerCancellation(
        _ operationID: DatabaseOperationID
    ) -> DatabaseCancellationSupport {
        guard var active = activeOperations[operationID] else { return .unavailable }
        guard active.running.cancellationSupport == .serverSide else {
            return active.running.cancellationSupport
        }
        guard let session = active.session else { return .cooperative }
        guard !active.serverCancellationInvoked else { return .cooperative }
        active.serverCancellationInvoked = true
        activeOperations[operationID] = active
        let invocation = Task {
            await session.cancel(operationID)
        }
        let task = Task { [weak self] in
            _ = await invocation.value
            await self?.finishServerCancellation(operationID)
        }
        serverCancellationTasks[operationID] = task
        return .cooperative
    }

    private func acceptCancellationAndSchedule(
        _ operationID: DatabaseOperationID
    ) -> DatabaseCancellationSupport {
        guard var active = activeOperations[operationID] else { return .unavailable }
        active.cancellationAccepted = true
        activeOperations[operationID] = active
        if active.running.cancellationSupport == .serverSide,
            serverCancellationCompletions[operationID] == nil
        {
            serverCancellationCompletions[operationID] = DatabaseExecutorCompletion<Bool>()
        }
        return scheduleServerCancellation(operationID)
    }

    private func checkControl(
        _ context: DatabaseAdapterOperationContext
    ) async throws {
        if Task.isCancelled {
            _ = await cancelActiveOperation(
                context.operationID,
                reason: .userRequested)
        } else if let deadline = context.deadline, deadline <= currentDate() {
            _ = await cancelActiveOperation(
                context.operationID,
                reason: .deadlineExceeded)
        }
        if let reason = await context.cancellation.reason() {
            throw DatabaseExecutorControlFailure(reason)
        }
    }

    private func finalizeOperation(
        _ terminal: DatabaseOperationRecordSummary,
        from expectedStates: Set<DatabaseOperationState>
    ) async -> Bool {
        do {
            return try await metadataStore.transitionOperation(
                terminal,
                from: expectedStates,
                owner: runtimeOwner)
        } catch {
            return false
        }
    }

    private func finishActiveOperation(_ operationID: DatabaseOperationID) async {
        let active = activeOperations.removeValue(forKey: operationID)
        active?.deadlineTask?.cancel()
        guard serverCancellationTasks[operationID] == nil else { return }
        let completion = serverCancellationCompletions.removeValue(forKey: operationID)
        serverCancellationReservations.remove(operationID)
        await completion?.resolve(false)
    }

    private func finishBackgroundTask(_ identifier: UUID) {
        backgroundTasks.removeValue(forKey: identifier)
    }

    private func waitForServerCancellation(_ operationID: DatabaseOperationID) async {
        if activeOperations[operationID]?.reservationState == .pending {
            return
        }
        if let completion = serverCancellationCompletions[operationID] {
            let events = await completion.events()
            var iterator = events.makeAsyncIterator()
            _ = await iterator.next()
        } else if let task = serverCancellationTasks[operationID] {
            await task.value
        }
    }

    private func waitForServerCancellation(
        _ operationID: DatabaseOperationID,
        until deadline: UInt64
    ) async {
        while let active = activeOperations[operationID],
            active.cancellationReason == nil,
            Self.remainingNanoseconds(until: deadline) > 0
        {
            await Task.yield()
        }
        if activeOperations[operationID]?.reservationState == .pending {
            return
        }
        if let completion = serverCancellationCompletions[operationID] {
            _ = await waitForCompletion(completion, until: deadline)
        }
    }

    private func waitForCompletion<Value: Sendable>(
        _ completion: DatabaseExecutorCompletion<Value>,
        until deadline: UInt64
    ) async -> Value? {
        let events = await completion.events()
        let remaining = Self.remainingNanoseconds(until: deadline)
        return await withTaskGroup(of: Value?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                guard remaining > 0 else { return nil }
                do {
                    try await Task.sleep(nanoseconds: remaining)
                } catch {
                    return nil
                }
                return nil
            }
            let value = await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private func finishServerCancellation(_ operationID: DatabaseOperationID) async {
        let completion = serverCancellationCompletions.removeValue(forKey: operationID)
        serverCancellationTasks.removeValue(forKey: operationID)
        serverCancellationReservations.remove(operationID)
        await completion?.resolve(true)
    }

    private func terminalSummary(
        from running: DatabaseOperationRecordSummary,
        state: DatabaseOperationState,
        progress: DatabaseOperationProgress?,
        warnings: [DatabaseWarning] = [],
        error: DatabaseErrorEnvelope?
    ) -> DatabaseOperationRecordSummary {
        let observedAt = currentDate()
        let finishedAt = running.startedAt.map { max($0, observedAt) } ?? observedAt
        return operationSummary(
            from: running,
            state: state,
            finishedAt: finishedAt,
            progress: progress,
            warnings: warnings,
            error: error)
    }

    private func operationSummary(
        from running: DatabaseOperationRecordSummary,
        state: DatabaseOperationState,
        finishedAt: Date?,
        progress: DatabaseOperationProgress?,
        warnings: [DatabaseWarning],
        error: DatabaseErrorEnvelope?
    ) -> DatabaseOperationRecordSummary {
        DatabaseOperationRecordSummary(
            id: running.id,
            kind: running.kind,
            state: state,
            connection: running.connection,
            target: running.target,
            startedAt: running.startedAt,
            finishedAt: finishedAt,
            deadline: running.deadline,
            progress: progress,
            cancellationSupport: running.cancellationSupport,
            retryClassification: running.retryClassification,
            pageCount: running.pageCount,
            recordCount: running.recordCount,
            byteCount: running.byteCount,
            warnings: warnings,
            partialFailures: running.partialFailures,
            error: error)
    }

    private func controlledErrorMapper(
        for definition: DatabaseConnectionDefinition,
        context: DatabaseAdapterOperationContext
    ) async throws -> DatabaseExecutionErrorMapper {
        guard backgroundTasks.count < Self.maximumBackgroundTasks else {
            return DatabaseExecutionErrorMapper()
        }
        let completion = DatabaseExecutorCompletion<DatabaseExecutionErrorMapper>()
        let identifier = UUID()
        let secretStore = secretStore
        let task = Task { [weak self] in
            let mapper = await Self.errorMapper(
                for: definition,
                secretStore: secretStore)
            await completion.resolve(mapper)
            await self?.finishBackgroundTask(identifier)
        }
        backgroundTasks[identifier] = task
        await attachExecutionCancellation(
            { task.cancel() },
            to: context.operationID)
        let outcome = await withTaskCancellationHandler {
            await waitForMapper(
                completion: completion,
                cancellation: context.cancellation)
        } onCancel: { [weak self] in
            task.cancel()
            Task {
                _ = await self?.cancelActiveOperation(
                    context.operationID,
                    reason: .userRequested)
            }
        }
        switch outcome {
        case let .resolved(mapper):
            return mapper
        case let .cancelled(reason):
            task.cancel()
            throw DatabaseExecutorControlFailure(reason)
        }
    }

    private func waitForMapper(
        completion: DatabaseExecutorCompletion<DatabaseExecutionErrorMapper>,
        cancellation: DatabaseAdapterCancellationSignal
    ) async -> DatabaseExecutorMapperOutcome {
        let completionEvents = await completion.events()
        let cancellationEvents = await cancellation.events()
        return await withTaskGroup(of: DatabaseExecutorMapperOutcome?.self) { group in
            group.addTask {
                var iterator = completionEvents.makeAsyncIterator()
                return await iterator.next().map(DatabaseExecutorMapperOutcome.resolved)
            }
            group.addTask {
                var iterator = cancellationEvents.makeAsyncIterator()
                return await iterator.next().map(DatabaseExecutorMapperOutcome.cancelled)
            }
            while let candidate = await group.next() {
                if let candidate {
                    group.cancelAll()
                    return candidate
                }
            }
            return .cancelled(.userRequested)
        }
    }

    private static func errorMapper(
        for definition: DatabaseConnectionDefinition,
        secretStore: any DatabaseSecretStore
    ) async -> DatabaseExecutionErrorMapper {
        var references = definition.authentication.secretReferences
        if let privateKey = definition.tls.clientPrivateKey {
            references.append(privateKey)
        }
        references = references.filter {
            $0.purpose != .confirmationSigningKey
                && $0.purpose != .continuationSigningKey
        }
        guard
            let redactor = try? await DatabaseSecretRedactor(
                store: secretStore,
                references: references)
        else {
            return DatabaseExecutionErrorMapper()
        }
        return DatabaseExecutionErrorMapper(redactor: redactor)
    }

    private func controlEnvelope(
        _ reason: DatabaseAdapterCancellationReason,
        mapper: DatabaseExecutionErrorMapper,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseErrorEnvelope {
        let envelope: DatabaseErrorEnvelope
        switch reason {
        case .userRequested:
            envelope = DatabaseErrorEnvelope(
                category: .cancelled,
                message: "The database operation was cancelled.",
                target: target)
        case .deadlineExceeded:
            envelope = DatabaseErrorEnvelope(
                category: .timeout,
                message: "The database operation exceeded its deadline.",
                target: target,
                retry: DatabaseRetryGuidance(
                    action: .retry,
                    message: "Retry with a longer deadline if the operation is still safe."))
        case .sessionDisconnected:
            envelope = DatabaseErrorEnvelope(
                category: .connectionFailed,
                message: "The database session disconnected during the operation.",
                target: target,
                retry: DatabaseRetryGuidance(
                    action: .reconnect,
                    message: "Reconnect before retrying the operation."))
        }
        return mapper.map(envelope, target: target)
    }

    private func completeMetadata(
        warning: DatabaseWarning? = nil
    ) -> DatabaseResultMetadata {
        DatabaseResultMetadata(
            completeness: DatabaseResultCompleteness(state: .complete),
            warnings: warning.map { [$0] } ?? [])
    }

    private func failure<Payload: Sendable>(
        _ error: any Error
    ) -> DatabaseCommandResult<Payload> {
        .failure(
            DatabaseExecutionErrorMapper().map(error),
            metadata: completeMetadata())
    }

    private static func isTerminal(_ state: DatabaseOperationState) -> Bool {
        switch state {
        case .succeeded, .failed, .cancelled, .partiallySucceeded:
            true
        case .queued, .running, .cancelling:
            false
        }
    }

    private static let zeroUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private static func deadline(after timeoutNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private static func remainingNanoseconds(until deadline: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }
}

private struct DatabaseExecutorActiveOperation: Sendable {
    var running: DatabaseOperationRecordSummary
    let cancellation: DatabaseAdapterCancellationSignal
    var reservationState: DatabaseExecutorReservationState
    var cancellationReason: DatabaseAdapterCancellationReason?
    var cancellationAccepted: Bool
    var session: (any DatabaseAdapterSession)?
    var serverCancellationInvoked: Bool
    var executionCancellation: (@Sendable () -> Void)?
    var deadlineTask: Task<Void, Never>?
    var cancellationTask: Task<DatabaseExecutorActiveCancellation, Never>?

    init(
        running: DatabaseOperationRecordSummary,
        cancellation: DatabaseAdapterCancellationSignal
    ) {
        self.running = running
        self.cancellation = cancellation
        reservationState = .pending
        cancellationReason = nil
        cancellationAccepted = false
        session = nil
        serverCancellationInvoked = false
        executionCancellation = nil
        deadlineTask = nil
        cancellationTask = nil
    }
}

private struct DatabaseExecutorActiveCancellation: Sendable {
    let disposition: DatabaseOperationCancellationDisposition
    let operation: DatabaseOperationRecordSummary?
    let cancellationSupport: DatabaseCancellationSupport
    let historyFinalized: Bool
}

private enum DatabaseExecutorCancellationWork: Sendable {
    case owned(Task<DatabaseExecutorActiveCancellation, Never>)
    case pending(Task<Void, Never>)
    case unavailable
}

private enum DatabaseExecutorReservationState: Sendable {
    case pending
    case owned
}

private struct DatabaseExecutorControlFailure: Error, Sendable {
    let reason: DatabaseAdapterCancellationReason

    init(_ reason: DatabaseAdapterCancellationReason) {
        self.reason = reason
    }
}

private enum DatabaseExecutorMapperOutcome: Sendable {
    case resolved(DatabaseExecutionErrorMapper)
    case cancelled(DatabaseAdapterCancellationReason)
}

private actor DatabaseManagementMutationCoordinator {
    static let shared = DatabaseManagementMutationCoordinator()
    private static let maximumRetainedCoordinations = 128
    private static let maximumConnectionCancellationCallbacks = 256
    private static let maximumRetainedCancellationCallbacks = 4_096
    private static let maximumConnectionDisconnectionCallbacks = 64
    private static let maximumRetainedDisconnectionCallbacks = 1_024
    private static let maximumCompletedDisconnections = 128

    private struct ConnectionKey: Hashable, Sendable {
        let owner: DatabaseRuntimeOwnerToken
        let connectionID: DatabaseConnectionID
    }

    typealias Cancellation = @Sendable () async -> Void
    typealias Disconnection = @Sendable () async -> Bool

    private struct MutationWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct OperationPermit {
        let cancellation: Cancellation
    }

    private struct ConnectionCoordination {
        let id: UUID
        let cancellationCompletion: DatabaseExecutorCompletion<Bool>
        let disconnectionCompletion: DatabaseExecutorCompletion<Bool>
        let cancellationCount: Int
        let disconnections: [Disconnection]
        var disconnectionStarted: Bool
    }

    private var activeOwners: Set<DatabaseRuntimeOwnerToken> = []
    private var waiters: [DatabaseRuntimeOwnerToken: [MutationWaiter]] = [:]
    private var exclusiveConnections: Set<ConnectionKey> = []
    private var operationPermits: [ConnectionKey: [UUID: OperationPermit]] = [:]
    private var disconnectors: [ConnectionKey: [UUID: Disconnection]] = [:]
    private var coordinations: [ConnectionKey: ConnectionCoordination] = [:]
    private var drainWaiters: [ConnectionKey: [UUID: DatabaseExecutorCompletion<Bool>]] = [:]
    private var completedDisconnections: [ConnectionKey: Bool] = [:]
    private var completedDisconnectionOrder: [ConnectionKey] = []
    func acquire(_ owner: DatabaseRuntimeOwnerToken) async throws {
        try Task.checkCancellation()
        guard activeOwners.contains(owner) else {
            activeOwners.insert(owner)
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters[owner, default: []].append(
                        MutationWaiter(id: id, continuation: continuation))
                }
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(owner: owner, id: id)
            }
        }
    }

    func release(_ owner: DatabaseRuntimeOwnerToken) {
        guard var ownerWaiters = waiters[owner], !ownerWaiters.isEmpty else {
            activeOwners.remove(owner)
            waiters.removeValue(forKey: owner)
            return
        }
        ownerWaiters.removeFirst().continuation.resume()
        waiters[owner] = ownerWaiters.isEmpty ? nil : ownerWaiters
    }

    func waiterCount(_ owner: DatabaseRuntimeOwnerToken) -> Int {
        waiters[owner]?.count ?? 0
    }

    private func cancelWaiter(owner: DatabaseRuntimeOwnerToken, id: UUID) {
        guard var ownerWaiters = waiters[owner],
            let index = ownerWaiters.firstIndex(where: { $0.id == id })
        else {
            return
        }
        let waiter = ownerWaiters.remove(at: index)
        waiters[owner] = ownerWaiters.isEmpty ? nil : ownerWaiters
        waiter.continuation.resume(throwing: CancellationError())
    }

    func reserveOperation(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID,
        permitID: UUID,
        executorID: UUID,
        cancel: @escaping Cancellation,
        disconnect: @escaping Disconnection
    ) async -> Bool {
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        guard !exclusiveConnections.contains(key), coordinations[key] == nil else {
            return false
        }
        let connectionPermitCount = operationPermits[key]?.count ?? 0
        let globalPermitCount = operationPermits.values.reduce(0) { $0 + $1.count }
        guard connectionPermitCount < Self.maximumConnectionCancellationCallbacks,
            globalPermitCount < Self.maximumRetainedCancellationCallbacks,
            operationPermits[key]?[permitID] == nil
        else {
            return false
        }
        if disconnectors[key]?[executorID] == nil {
            let connectionDisconnectorCount = disconnectors[key]?.count ?? 0
            let globalDisconnectorCount = disconnectors.values.reduce(0) { $0 + $1.count }
            guard
                connectionDisconnectorCount < Self.maximumConnectionDisconnectionCallbacks,
                globalDisconnectorCount < Self.maximumRetainedDisconnectionCallbacks
            else {
                return false
            }
        }
        operationPermits[key, default: [:]][permitID] = OperationPermit(
            cancellation: cancel)
        disconnectors[key, default: [:]][executorID] = disconnect
        return true
    }

    func releaseOperation(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID,
        permitID: UUID
    ) async {
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        operationPermits[key]?.removeValue(forKey: permitID)
        guard operationPermits[key]?.isEmpty == true else { return }
        operationPermits.removeValue(forKey: key)
        let pending = drainWaiters.removeValue(forKey: key).map { Array($0.values) } ?? []
        for completion in pending {
            await completion.resolve(true)
        }
        await reapCoordinationIfFinished(key)
    }

    func beginExclusiveConnectionMutation(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID,
        timeoutNanoseconds: UInt64
    ) async throws -> Bool {
        try Task.checkCancellation()
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        guard exclusiveConnections.insert(key).inserted else {
            throw DatabaseExecutionValidationError.connectionDefinitionChanged(connectionID)
        }
        let deadline = Self.deadline(after: timeoutNanoseconds)
        let coordination = try await createCoordinationIfNeeded(key: key)
        _ = try await waitForCompletion(
            coordination.cancellationCompletion,
            until: deadline)
        guard exclusiveConnections.contains(key),
            coordinations[key]?.id == coordination.id
        else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
        startDisconnectionsIfNeeded(key: key)
        guard let current = coordinations[key], current.id == coordination.id else {
            throw DatabaseExecutionValidationError.connectionDefinitionChanged(connectionID)
        }
        let disconnected = try await waitForCompletion(
            current.disconnectionCompletion,
            until: deadline)
        guard exclusiveConnections.contains(key),
            coordinations[key]?.id == coordination.id
        else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
        if operationPermits[key]?.isEmpty == false {
            let id = UUID()
            let completion = DatabaseExecutorCompletion<Bool>()
            drainWaiters[key, default: [:]][id] = completion
            do {
                _ = try await waitForCompletion(completion, until: deadline)
                drainWaiters[key]?.removeValue(forKey: id)
                if drainWaiters[key]?.isEmpty == true {
                    drainWaiters.removeValue(forKey: key)
                }
                guard exclusiveConnections.contains(key),
                    coordinations[key]?.id == coordination.id
                else {
                    throw DatabaseExecutionValidationError.runtimeOwnerNotActive
                }
            } catch {
                drainWaiters[key]?.removeValue(forKey: id)
                if drainWaiters[key]?.isEmpty == true {
                    drainWaiters.removeValue(forKey: key)
                }
                throw error
            }
        }
        try Task.checkCancellation()
        return disconnected
    }

    func endExclusiveConnectionMutation(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID,
        discardCoordination: Bool
    ) async {
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        exclusiveConnections.remove(key)
        if discardCoordination {
            coordinations.removeValue(forKey: key)
            disconnectors.removeValue(forKey: key)
        } else {
            await reapCoordinationIfFinished(key)
        }
    }

    func isExclusivelyMutating(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID
    ) -> Bool {
        exclusiveConnections.contains(ConnectionKey(owner: owner, connectionID: connectionID))
    }

    func retainedCoordinationCount(_ owner: DatabaseRuntimeOwnerToken) -> Int {
        return coordinations.keys.filter { $0.owner == owner }.count
    }

    func retainedCallbackCount(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID
    ) -> Int {
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        guard let coordination = coordinations[key] else { return 0 }
        return coordination.cancellationCount + coordination.disconnections.count
    }

    func disconnectionCompleted(
        owner: DatabaseRuntimeOwnerToken,
        connectionID: DatabaseConnectionID
    ) async -> Bool {
        let key = ConnectionKey(owner: owner, connectionID: connectionID)
        guard let coordination = coordinations[key] else {
            return completedDisconnections[key] != nil
        }
        return await coordination.disconnectionCompletion.isResolved()
    }

    func unregisterExecutor(
        owner: DatabaseRuntimeOwnerToken,
        executorID: UUID
    ) {
        let keys = disconnectors.keys.filter { $0.owner == owner }
        keys.forEach { key in
            disconnectors[key]?.removeValue(forKey: executorID)
            if disconnectors[key]?.isEmpty == true {
                disconnectors.removeValue(forKey: key)
            }
        }
    }

    private func createCoordinationIfNeeded(
        key: ConnectionKey
    ) async throws -> ConnectionCoordination {
        await reapFinishedCoordinations()
        guard exclusiveConnections.contains(key) else {
            throw DatabaseExecutionValidationError.runtimeOwnerNotActive
        }
        if let coordination = coordinations[key] {
            return coordination
        }
        if let disconnected = completedDisconnections.removeValue(forKey: key) {
            completedDisconnectionOrder.removeAll { $0 == key }
            let cancellationCompletion = DatabaseExecutorCompletion<Bool>()
            let disconnectionCompletion = DatabaseExecutorCompletion<Bool>()
            await cancellationCompletion.resolve(true)
            await disconnectionCompletion.resolve(disconnected)
            let coordination = ConnectionCoordination(
                id: UUID(),
                cancellationCompletion: cancellationCompletion,
                disconnectionCompletion: disconnectionCompletion,
                cancellationCount: 0,
                disconnections: [],
                disconnectionStarted: true)
            coordinations[key] = coordination
            return coordination
        }
        let cancellations =
            operationPermits[key].map {
                $0.values.map(\.cancellation)
            } ?? []
        let disconnections = disconnectors[key].map { Array($0.values) } ?? []
        let retainedCancellationCount = coordinations.values.reduce(0) {
            $0 + $1.cancellationCount
        }
        let retainedDisconnectionCount = coordinations.values.reduce(0) {
            $0 + $1.disconnections.count
        }
        guard coordinations.count < Self.maximumRetainedCoordinations,
            cancellations.count <= Self.maximumConnectionCancellationCallbacks,
            retainedCancellationCount + cancellations.count
                <= Self.maximumRetainedCancellationCallbacks,
            disconnections.count <= Self.maximumConnectionDisconnectionCallbacks,
            retainedDisconnectionCount + disconnections.count
                <= Self.maximumRetainedDisconnectionCallbacks
        else {
            throw DatabaseExecutionValidationError.limitExceeded(
                name: "retained connection coordination",
                actual: coordinations.count + 1,
                maximum: Self.maximumRetainedCoordinations)
        }
        let cancellationCompletion = DatabaseExecutorCompletion<Bool>()
        let coordination = ConnectionCoordination(
            id: UUID(),
            cancellationCompletion: cancellationCompletion,
            disconnectionCompletion: DatabaseExecutorCompletion<Bool>(),
            cancellationCount: cancellations.count,
            disconnections: disconnections,
            disconnectionStarted: false)
        coordinations[key] = coordination
        Task {
            await withTaskGroup(of: Void.self) { group in
                for cancellation in cancellations.prefix(
                    Self.maximumConnectionCancellationCallbacks)
                {
                    group.addTask {
                        await cancellation()
                    }
                }
            }
            await cancellationCompletion.resolve(true)
            await self.finishCancellations(key)
        }
        return coordination
    }

    private func startDisconnectionsIfNeeded(key: ConnectionKey) {
        guard var coordination = coordinations[key], !coordination.disconnectionStarted else {
            return
        }
        coordination.disconnectionStarted = true
        coordinations[key] = coordination
        let disconnections = coordination.disconnections
        let completion = coordination.disconnectionCompletion
        Task {
            let disconnected = await withTaskGroup(of: Bool.self) { group in
                for disconnection in disconnections.prefix(
                    Self.maximumConnectionDisconnectionCallbacks)
                {
                    group.addTask {
                        await disconnection()
                    }
                }
                var result = false
                for await value in group {
                    result = value || result
                }
                return result
            }
            await completion.resolve(disconnected)
            await self.finishDisconnections(key)
        }
    }

    private func finishCancellations(_ key: ConnectionKey) async {
        startDisconnectionsIfNeeded(key: key)
        await reapCoordinationIfFinished(key)
    }

    private func finishDisconnections(_ key: ConnectionKey) async {
        await reapCoordinationIfFinished(key)
    }

    private func reapFinishedCoordinations() async {
        for key in Array(coordinations.keys) {
            await reapCoordinationIfFinished(key)
        }
    }

    private func reapCoordinationIfFinished(_ key: ConnectionKey) async {
        guard !exclusiveConnections.contains(key),
            operationPermits[key]?.isEmpty != false,
            let coordination = coordinations[key]
        else {
            return
        }
        guard await coordination.cancellationCompletion.isResolved(),
            let disconnected = await coordination.disconnectionCompletion.resolvedValue(),
            !exclusiveConnections.contains(key),
            operationPermits[key]?.isEmpty != false,
            coordinations[key]?.id == coordination.id
        else {
            return
        }
        coordinations.removeValue(forKey: key)
        disconnectors.removeValue(forKey: key)
        completedDisconnections[key] = disconnected
        completedDisconnectionOrder.removeAll { $0 == key }
        completedDisconnectionOrder.append(key)
        if completedDisconnectionOrder.count > Self.maximumCompletedDisconnections {
            let evicted = completedDisconnectionOrder.removeFirst()
            completedDisconnections.removeValue(forKey: evicted)
        }
    }

    func retireOwner(_ owner: DatabaseRuntimeOwnerToken) async {
        let staleWaiters = waiters.removeValue(forKey: owner) ?? []
        for waiter in staleWaiters {
            waiter.continuation.resume(
                throwing: DatabaseExecutionValidationError.runtimeOwnerNotActive)
        }
        activeOwners.remove(owner)
        exclusiveConnections = exclusiveConnections.filter { $0.owner != owner }
        operationPermits = operationPermits.filter { $0.key.owner != owner }
        disconnectors = disconnectors.filter { $0.key.owner != owner }
        coordinations = coordinations.filter { $0.key.owner != owner }
        completedDisconnections = completedDisconnections.filter { $0.key.owner != owner }
        completedDisconnectionOrder.removeAll { $0.owner == owner }
        let staleDrainWaiters = drainWaiters.filter { $0.key.owner == owner }.flatMap {
            $0.value.values
        }
        drainWaiters = drainWaiters.filter { $0.key.owner != owner }
        for completion in staleDrainWaiters {
            await completion.resolve(false)
        }
    }

    private func waitForCompletion<Value: Sendable>(
        _ completion: DatabaseExecutorCompletion<Value>,
        until deadline: UInt64
    ) async throws -> Value {
        let events = await completion.events()
        let remaining = Self.remainingNanoseconds(until: deadline)
        let outcome = await withTaskGroup(
            of: DatabaseManagementWaitOutcome<Value>.self
        ) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                guard let value = await iterator.next() else { return .cancelled }
                return .completed(value)
            }
            group.addTask {
                guard remaining > 0 else { return .timedOut }
                do {
                    try await Task.sleep(nanoseconds: remaining)
                } catch {
                    return .cancelled
                }
                return Task.isCancelled ? .cancelled : .timedOut
            }
            let result = await group.next() ?? .cancelled
            group.cancelAll()
            return result
        }
        switch outcome {
        case let .completed(value):
            try Task.checkCancellation()
            return value
        case .timedOut:
            throw DatabaseExecutionValidationError.deadlineExceeded
        case .cancelled:
            throw CancellationError()
        }
    }

    private static func deadline(after timeoutNanoseconds: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let (deadline, overflow) = now.addingReportingOverflow(timeoutNanoseconds)
        return overflow ? UInt64.max : deadline
    }

    private static func remainingNanoseconds(until deadline: UInt64) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        return deadline > now ? deadline - now : 0
    }
}

private enum DatabaseManagementWaitOutcome<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
    case cancelled
}

private actor DatabaseExecutorOperationAdmission {
    private var cancellation: (@Sendable () async -> Void)?
    private var cancellationTask: Task<Void, Never>?
    private var isCancelled = false

    func attach(_ cancellation: @escaping @Sendable () async -> Void) async {
        self.cancellation = cancellation
        guard isCancelled else { return }
        let task = Task { await cancellation() }
        cancellationTask = task
        await task.value
    }

    func cancel() async {
        if let cancellationTask {
            await cancellationTask.value
            return
        }
        guard !isCancelled else { return }
        isCancelled = true
        guard let cancellation else { return }
        let task = Task { await cancellation() }
        cancellationTask = task
        await task.value
    }
}

private actor DatabaseExecutorCompletion<Value: Sendable> {
    private var value: Value?
    private var continuations: [UUID: AsyncStream<Value>.Continuation] = [:]

    func resolve(_ value: Value) {
        guard self.value == nil else { return }
        self.value = value
        let pending = continuations.values
        continuations.removeAll()
        for continuation in pending {
            continuation.yield(value)
            continuation.finish()
        }
    }

    func events() -> AsyncStream<Value> {
        let identifier = UUID()
        let pair = AsyncStream<Value>.makeStream(bufferingPolicy: .bufferingNewest(1))
        if let value {
            pair.continuation.yield(value)
            pair.continuation.finish()
        } else {
            pair.continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeContinuation(identifier)
                }
            }
            continuations[identifier] = pair.continuation
        }
        return pair.stream
    }

    func isResolved() -> Bool {
        value != nil
    }

    func resolvedValue() -> Value? {
        value
    }

    private func removeContinuation(_ identifier: UUID) {
        continuations.removeValue(forKey: identifier)
    }
}
