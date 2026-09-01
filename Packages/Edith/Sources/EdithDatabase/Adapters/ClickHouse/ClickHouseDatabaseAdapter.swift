import Foundation

struct ClickHouseDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "clickhouse"
    let products: Set<DatabaseProduct> = [.clickHouse]
    private let connector: ClickHouseDatabaseClientConnector

    init(
        connector: @escaping ClickHouseDatabaseClientConnector = { plan in
            try await URLSessionClickHouseDatabaseClient.connect(plan)
        }
    ) {
        self.connector = connector
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await ClickHouseDatabaseAdapterSupport.check(context)
        let plan = try ClickHouseDatabaseAdapterSupport.connectionPlan(
            connection,
            context: context)
        let established = try await ClickHouseDatabaseAdapterSupport.establish(
            plan: plan,
            connector: connector,
            context: context)
        return ClickHouseDatabaseAdapterSession(
            connection: connection.definition,
            productIdentity: established.identity,
            client: established.client)
    }
}

actor ClickHouseDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any ClickHouseDatabaseClient)?
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: ClickHouseDatabaseAdapterActiveOperation?
    private var descriptions: [String: ClickHouseDatabaseTableDescription] = [:]

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any ClickHouseDatabaseClient
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.client = client
    }

    func lifecycleState() -> DatabaseAdapterSessionState {
        state
    }

    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        let identity: DatabaseProductIdentity = try await perform(
            context: context,
            fallback: ClickHouseDatabaseAdapterSupport.connectionFailed
        ) { client in
            try await client.discoverIdentity()
        }
        guard
            ClickHouseDatabaseStableIdentity(identity)
                == ClickHouseDatabaseStableIdentity(productIdentity)
        else {
            await failAndClose()
            throw ClickHouseDatabaseAdapterSupport.connectionFailed
        }
        let report = ClickHouseDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try validateConnection(request.target)
        if let table = try ClickHouseDatabaseReadCompiler.targetTable(request.target) {
            return try await browse(
                request,
                database: table.database,
                table: table.table,
                context: context)
        }
        let startedAt = ContinuousClock.now
        let plan = try ClickHouseDatabaseReadCompiler.compileMetadata(
            request,
            sessionID: id)
        do {
            let response: ClickHouseDatabaseHTTPResponse = try await perform(
                context: context,
                fallback: ClickHouseDatabaseAdapterSupport.invalidResponse
            ) { client in
                try await client.execute(
                    query: plan.query,
                    maximumResponseBytes: DatabaseAdapterBounds.maximumPageBytes,
                    parameters: plan.parameters)
            }
            let page = try ClickHouseDatabaseReadCompiler.metadataPage(
                response: response,
                plan: plan,
                request: request,
                sessionID: id,
                startedAt: startedAt)
            try page.validate(for: request)
            return page
        } catch let failure {
            guard ClickHouseDatabaseAdapterSupport.isPermissionDenied(failure) else {
                throw failure
            }
            let degraded = try ClickHouseDatabaseReadCompiler.degradedMetadataPage(
                request: request,
                startedAt: startedAt)
            try degraded.validate(for: request)
            return degraded
        }
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try validateConnection(request.source.target)
        let plan = try ClickHouseDatabaseReadCompiler.compileQuery(request)
        let startedAt = ContinuousClock.now
        let response: ClickHouseDatabaseHTTPResponse = try await perform(
            context: context,
            fallback: ClickHouseDatabaseAdapterSupport.invalidResponse
        ) { client in
            try await client.execute(
                query: plan.query,
                maximumResponseBytes: DatabaseAdapterBounds.maximumPageBytes,
                parameters: plan.parameters)
        }
        let page = try ClickHouseDatabaseReadCompiler.queryPage(
            response: response,
            request: request.source,
            startedAt: startedAt)
        try page.validate(for: request.source)
        return page
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        throw ClickHouseDatabaseAdapterSupport.readOnlyViolation
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        try await requireAvailableContext(context)
        throw ClickHouseDatabaseAdapterSupport.readOnlyViolation
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        switch request.source {
        case let .browse(source):
            try validateConnection(source.target)
            guard try ClickHouseDatabaseReadCompiler.targetTable(source.target) != nil else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
        case let .query(source):
            try validateConnection(source.source.target)
            _ = try ClickHouseDatabaseReadCompiler.compileQuery(source)
        }
        return ClickHouseDatabaseRecordStream(
            session: self,
            request: request,
            context: context)
    }

    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult {
        guard let activeOperation, activeOperation.operationID == operationID else {
            return DatabaseAdapterCancellationResult(
                support: .serverSide,
                disposition: .alreadyFinished)
        }
        await activeOperation.cancellation.cancel(.userRequested)
        await interrupt(operationID: operationID)
        return DatabaseAdapterCancellationResult(
            support: .serverSide,
            disposition: .accepted)
    }

    func disconnect() async {
        guard state == .connected || state == .failed else { return }
        state = .disconnecting
        if let activeOperation {
            await activeOperation.cancellation.cancel(.sessionDisconnected)
        }
        let client = self.client
        self.client = nil
        activeOperation = nil
        descriptions.removeAll()
        await client?.disconnect()
        state = .disconnected
    }

    func resourceIsOpen() -> Bool {
        client != nil
    }

    private func browse(
        _ request: DatabaseAdapterPageRequest,
        database: String,
        table: String,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = ContinuousClock.now
        let cacheKey = "\(database)\0\(table)"
        let description: ClickHouseDatabaseTableDescription
        if let cached = descriptions[cacheKey] {
            description = cached
        } else {
            let query = try ClickHouseDatabaseReadCompiler.descriptionQuery(
                database: database,
                table: table)
            let response: ClickHouseDatabaseHTTPResponse = try await perform(
                context: context,
                fallback: ClickHouseDatabaseAdapterSupport.invalidResponse
            ) { client in
                try await client.execute(
                    query: query,
                    maximumResponseBytes: 1_048_576,
                    parameters: [
                        ClickHouseDatabaseHTTPParameter(
                            name: "_edith_database",
                            value: database),
                        ClickHouseDatabaseHTTPParameter(
                            name: "_edith_table",
                            value: table),
                    ])
            }
            description = try ClickHouseDatabaseReadCompiler.tableDescription(
                response: response,
                database: database,
                table: table)
            if descriptions.count >= 32, let oldest = descriptions.keys.sorted().first {
                descriptions.removeValue(forKey: oldest)
            }
            descriptions[cacheKey] = description
        }
        let plan = try ClickHouseDatabaseReadCompiler.compileBrowse(
            request,
            description: description,
            sessionID: id)
        let response: ClickHouseDatabaseHTTPResponse = try await perform(
            context: context,
            fallback: ClickHouseDatabaseAdapterSupport.invalidResponse
        ) { client in
            try await client.execute(
                query: plan.query,
                maximumResponseBytes: DatabaseAdapterBounds.maximumPageBytes,
                parameters: plan.parameters)
        }
        let page = try ClickHouseDatabaseReadCompiler.browsePage(
            response: response,
            plan: plan,
            request: request,
            sessionID: id,
            startedAt: startedAt)
        try page.validate(for: request)
        return page
    }

    private func validateConnection(
        _ target: DatabaseTargetIdentifier
    ) throws(DatabaseAdapterFailure) {
        guard target.connectionID == connection.id else {
            throw ClickHouseDatabaseAdapterSupport.invalidTarget
        }
    }

    private func connectedClient() throws(DatabaseAdapterFailure)
        -> any ClickHouseDatabaseClient
    {
        guard state == .connected, let client else {
            throw ClickHouseDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await ClickHouseDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await ClickHouseDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body: @escaping @Sendable (any ClickHouseDatabaseClient) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await ClickHouseDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw ClickHouseDatabaseAdapterSupport.operationBusy
        }
        activeOperation = ClickHouseDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)
        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = ClickHouseDatabaseAdapterSupport.deadlineTask(context: context)
        defer {
            cancellationTask.cancel()
            deadlineTask?.cancel()
            if activeOperation?.operationID == context.operationID {
                activeOperation = nil
            }
        }
        do {
            let output = try await withTaskCancellationHandler {
                try await body(client)
            } onCancel: {
                Task {
                    await context.cancellation.cancel(.userRequested)
                    await self.interrupt(operationID: context.operationID)
                }
            }
            try await ClickHouseDatabaseAdapterSupport.check(context)
            return output
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded:
                await interrupt(operationID: context.operationID)
                throw ClickHouseDatabaseAdapterSupport.deadlineExceeded
            case .userRequested, .sessionDisconnected:
                await interrupt(operationID: context.operationID)
                throw .cancelled
            case nil:
                break
            }
            if error is CancellationError || Task.isCancelled {
                await context.cancellation.cancel(.userRequested)
                await interrupt(operationID: context.operationID)
                throw .cancelled
            }
            if let failure = error as? DatabaseAdapterFailure {
                throw failure
            }
            if let failure = error as? ClickHouseDatabaseValueCodecFailure {
                switch failure {
                case .invalidResponse:
                    throw ClickHouseDatabaseAdapterSupport.invalidResponse
                case .responseTooLarge:
                    throw ClickHouseDatabaseAdapterSupport.resourceLimit
                }
            }
            if let driverFailure = error as? ClickHouseDatabaseDriverFailure {
                if ClickHouseDatabaseAdapterSupport.breaksSession(driverFailure) {
                    await failAndClose()
                }
                throw ClickHouseDatabaseAdapterSupport.map(
                    driverFailure,
                    fallback: fallback)
            }
            throw fallback
        }
    }

    private func interrupt(operationID: DatabaseOperationID) async {
        guard activeOperation?.operationID == operationID else { return }
        await failAndClose()
    }

    private func failAndClose() async {
        let client = self.client
        self.client = nil
        descriptions.removeAll()
        state = .failed
        await client?.disconnect()
    }
}

actor ClickHouseDatabaseRecordStream: DatabaseAdapterRecordStream {
    private let session: ClickHouseDatabaseAdapterSession
    private let request: DatabaseAdapterStreamRequest
    private let context: DatabaseAdapterOperationContext
    private var continuation: DatabaseAdapterContinuation?
    private var emitted: UInt64 = 0
    private var finished = false

    init(
        session: ClickHouseDatabaseAdapterSession,
        request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) {
        self.session = session
        self.request = request
        self.context = context
        switch request.source {
        case let .browse(source): continuation = source.continuation
        case let .query(source): continuation = source.source.continuation
        }
    }

    func nextBatch() async throws(DatabaseAdapterFailure) -> DatabaseAdapterRecordBatch? {
        guard !finished else { return nil }
        let page: DatabaseAdapterPage
        switch request.source {
        case let .browse(source):
            let batchRequest = try pageRequest(source, continuation: continuation)
            page = try await session.readPage(batchRequest, context: context)
        case let .query(source):
            guard continuation == nil else {
                throw ClickHouseDatabaseAdapterSupport.invalidContinuation
            }
            let batchRequest = try queryRequest(source)
            page = try await session.query(batchRequest, context: context)
            finished = true
        }
        continuation = page.nextContinuation
        if continuation == nil { finished = true }
        emitted += UInt64(page.records.count)
        let batch = try DatabaseAdapterRecordBatch(
            records: page.records,
            fields: page.fields,
            progress: DatabaseOperationProgress(
                kind: .indeterminate,
                completed: emitted,
                unit: .records),
            bytesReceived: page.metadata.bytesReceived,
            warnings: page.metadata.warnings,
            partialFailures: page.metadata.partialFailures)
        try batch.validate(for: request)
        return batch
    }

    func close() async {
        finished = true
        continuation = nil
    }

    private func pageRequest(
        _ source: DatabaseAdapterPageRequest,
        continuation: DatabaseAdapterContinuation?
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPageRequest {
        let pageSize: DatabasePageSize
        do {
            pageSize = try DatabasePageSize(request.batchSize.value)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let page = DatabasePageRequest(
            pageSize: pageSize,
            projection: source.projection,
            filter: source.filter,
            sorts: source.sorts,
            consistency: source.consistency)
        return try DatabaseAdapterPageRequest(
            target: source.target,
            page: page,
            continuation: continuation)
    }

    private func queryRequest(
        _ source: DatabaseAdapterQueryRequest
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterQueryRequest {
        let pageSize: DatabasePageSize
        do {
            pageSize = try DatabasePageSize(request.batchSize.value)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let page = DatabasePageRequest(
            pageSize: pageSize,
            projection: source.source.projection,
            filter: source.source.filter,
            sorts: source.source.sorts,
            consistency: source.source.consistency)
        return try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: source.source.target,
                language: source.language,
                command: source.command,
                parameters: source.parameters,
                body: source.body,
                page: page),
            continuation: nil)
    }
}

private struct ClickHouseDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

struct ClickHouseDatabaseEstablishedClient: Sendable {
    let client: any ClickHouseDatabaseClient
    let identity: DatabaseProductIdentity
}

private struct ClickHouseDatabaseStableIdentity: Equatable {
    let product: DatabaseProduct
    let version: DatabaseVersion?
    let distribution: String?
    let serverIdentifier: String?

    init(_ identity: DatabaseProductIdentity) {
        product = identity.product
        version = identity.version
        distribution = identity.distribution
        serverIdentifier = identity.serverIdentifier
    }
}

enum ClickHouseDatabaseAdapterSupport {
    static let connectionFailed = failure(
        category: .connectionFailed,
        message: "The ClickHouse server could not be reached.",
        code: "clickhouse.connection.failed",
        retry: .reconnect)
    static let authenticationFailed = failure(
        category: .authenticationFailed,
        message: "ClickHouse authentication failed.",
        code: "clickhouse.authentication.failed",
        retry: .reauthenticate)
    static let tlsFailed = failure(
        category: .tlsFailed,
        message: "The ClickHouse TLS connection failed.",
        code: "clickhouse.tls.failed",
        retry: .userDecision)
    static let disconnected = failure(
        category: .connectionFailed,
        message: "The ClickHouse session is disconnected.",
        code: "clickhouse.session.disconnected",
        retry: .reconnect)
    static let invalidConnection = failure(
        category: .invalidRequest,
        message: "The ClickHouse connection configuration is invalid.",
        code: "clickhouse.connection.invalid")
    static let deadlineExceeded = failure(
        category: .timeout,
        message: "The ClickHouse operation deadline was exceeded.",
        code: "clickhouse.deadline_exceeded",
        retry: .retry)
    static let invalidRequest = failure(
        category: .invalidRequest,
        message: "The ClickHouse read request is invalid.",
        code: "clickhouse.request.invalid")
    static let unsafeRequest = failure(
        category: .readOnlyViolation,
        message: "The ClickHouse statement is not allowed by the read-only adapter.",
        code: "clickhouse.request.unsafe")
    static let invalidTarget = failure(
        category: .invalidRequest,
        message: "The ClickHouse target is invalid.",
        code: "clickhouse.target.invalid")
    static let invalidContinuation = failure(
        category: .conflict,
        message: "The ClickHouse continuation is invalid or expired.",
        code: "clickhouse.continuation.invalid",
        retry: .createNewPreview)
    static let invalidResponse = failure(
        category: .decoding,
        message: "ClickHouse returned an invalid bounded response.",
        code: "clickhouse.response.invalid",
        retry: .retry)
    static let unstableTarget = failure(
        category: .unsupported,
        message: "The ClickHouse target does not expose a stable non-null sorting key.",
        code: "clickhouse.pagination.unstable")
    static let operationBusy = failure(
        category: .conflict,
        message: "The ClickHouse session already has an active operation.",
        code: "clickhouse.operation.busy",
        retry: .retry)
    static let readOnlyViolation = failure(
        category: .readOnlyViolation,
        message: "The ClickHouse adapter does not permit mutations.",
        code: "clickhouse.read_only")
    static let resourceLimit = failure(
        category: .resourceLimit,
        message: "The bounded ClickHouse response exceeded a resource limit.",
        code: "clickhouse.resource_limit",
        retry: .userDecision)

    static func connectionPlan(
        _ resolved: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseConnectionPlan {
        let definition = resolved.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .clickHouse,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.namespaces.catalog == nil,
            definition.namespaces.schema == nil,
            definition.namespaces.logicalDatabase == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil,
            definition.tls.serverName == nil,
            [.automatic, .standalone, .cluster, .distributed].contains(
                definition.deploymentMode),
            definition.readOnlyPolicy != .disabled
                || definition.productionPolicy == .prohibitMutations,
            case let .network(endpoints) = definition.location,
            endpoints.count == 1,
            let endpoint = endpoints.first,
            [.primary, .readReplica, .seed, .router, .node].contains(endpoint.role),
            validHost(endpoint.host),
            let username = definition.username,
            validCredential(username)
        else {
            throw invalidConnection
        }
        let database = try optionalName(definition.namespaces.database)
        let password = try password(
            authentication: definition.authentication,
            resolvedSecrets: resolved.secrets)
        let tls: ClickHouseDatabaseTLSPlan
        switch (definition.tls.mode, definition.tls.verification) {
        case (.disabled, .none): tls = .disabled
        case (.required, .full): tls = .required
        default: throw invalidConnection
        }
        let timeout = try effectiveTimeout(
            configured: definition.limits.operationTimeout.milliseconds,
            deadline: context.deadline)
        return ClickHouseDatabaseConnectionPlan(
            host: endpoint.host,
            port: endpoint.port.value,
            username: username,
            password: password,
            database: database,
            tls: tls,
            requestTimeoutMilliseconds: timeout,
            readOnly: true)
    }

    static func establish(
        plan: ClickHouseDatabaseConnectionPlan,
        connector: @escaping ClickHouseDatabaseClientConnector,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> ClickHouseDatabaseEstablishedClient {
        let establishmentTask = Task {
            let client = try await connector(plan)
            do {
                let identity = try await client.discoverIdentity()
                guard identity.product == .clickHouse,
                    identity.distribution == "ClickHouse"
                else {
                    throw connectionFailed
                }
                return ClickHouseDatabaseEstablishedClient(client: client, identity: identity)
            } catch {
                await client.disconnect()
                throw error
            }
        }
        let cancellationTask = Task {
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                establishmentTask.cancel()
                return
            }
        }
        let deadlineTask = deadlineTask(context: context)
        defer {
            cancellationTask.cancel()
            deadlineTask?.cancel()
        }
        do {
            let established = try await withTaskCancellationHandler {
                try await establishmentTask.value
            } onCancel: {
                establishmentTask.cancel()
            }
            do {
                try await check(context)
            } catch {
                await established.client.disconnect()
                throw error
            }
            return established
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded: throw deadlineExceeded
            case .userRequested, .sessionDisconnected: throw .cancelled
            case nil: break
            }
            if error is CancellationError || Task.isCancelled { throw .cancelled }
            if let failure = error as? DatabaseAdapterFailure { throw failure }
            if let failure = error as? ClickHouseDatabaseDriverFailure {
                throw map(failure, fallback: connectionFailed)
            }
            throw connectionFailed
        }
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity,
        discoveredAt: Date = Date()
    ) -> DatabaseCapabilityReport {
        let metadataReason = DatabaseCapabilityUnavailableReason(
            category: .permission,
            message: "ClickHouse metadata is discovered lazily and may be permission limited.",
            missingPermissions: ["SELECT on system.databases, system.tables, system.columns"])
        let unsafeReason = DatabaseCapabilityUnavailableReason(
            category: .unsafe,
            message: "The ClickHouse adapter is strictly read-only.")
        let unavailableReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is outside the bounded ClickHouse reading slice.")
        let productReason = DatabaseCapabilityUnavailableReason(
            category: .product,
            message: "ClickHouse does not provide transactional row editing semantics.")
        let limits = [
            DatabaseCapabilityLimit(
                name: "pageRecords",
                value: UInt64(DatabasePageSize.range.upperBound),
                unit: "records"),
            DatabaseCapabilityLimit(
                name: "pageBytes",
                value: UInt64(DatabaseAdapterBounds.maximumPageBytes),
                unit: "bytes"),
            DatabaseCapabilityLimit(
                name: "streamBatchRecords",
                value: UInt64(DatabaseAdapterBounds.maximumStreamBatchRecords),
                unit: "records"),
            DatabaseCapabilityLimit(name: "continuationLifetime", value: 60, unit: "seconds"),
        ]
        let available: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.connectionTest, .sharedRequired),
            (.query, .familyRequired),
            (.queryCancellation, .sharedRequired),
            (.explain, .familyRequired),
            (.browse, .sharedRequired),
        ]
        let metadata: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.objectDiscovery, .sharedRequired),
            (.objectDescription, .sharedRequired),
        ]
        let unsafe: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.insert, .sharedRequired),
            (.update, .sharedRequired),
            (.delete, .sharedRequired),
            (.bulkMutation, .sharedRequired),
            (.importData, .sharedRequired),
            (.schemaMutation, .familyRequired),
            (.administration, .productRequired),
        ]
        let unavailable: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.exportData, .sharedRequired),
            (.monitoring, .productRequired),
        ]
        let capabilities =
            available.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .available,
                    limits: limits)
            }
            + metadata.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .degraded,
                    reason: metadataReason,
                    limits: limits)
            }
            + unsafe.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .unavailable,
                    reason: unsafeReason)
            }
            + unavailable.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .unavailable,
                    reason: unavailableReason)
            } + [
                DatabaseCapabilityStatus(
                    id: .transactions,
                    requirement: .familyRequired,
                    availability: .unavailable,
                    reason: productReason)
            ]
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            permissions: [
                DatabasePermissionStatus(name: "read data", granted: true),
                DatabasePermissionStatus(name: "read system metadata", granted: nil),
                DatabasePermissionStatus(name: "kill own query", granted: nil),
            ],
            pagingModes: [.keyset, .streamed],
            mutationModes: [.unsupported],
            transactionModes: [.none],
            cancellationModes: [.serverOperation],
            explainModes: [.logical, .physical, .pipeline, .indexes],
            safetyLimitations: [
                "Only SELECT, WITH SELECT, and EXPLAIN statements are accepted.",
                "Interactive browsing requires a non-null MergeTree sorting key.",
                "Continuation tokens expire after 60 seconds and remain session-bound.",
                "ClickHouse primary keys are ordering keys and do not enforce uniqueness.",
                "Response bodies and pull-stream batches are hard bounded.",
            ],
            discoveredAt: discoveredAt,
            expiresAt: discoveredAt.addingTimeInterval(300))
    }

    static func check(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        switch await context.cancellation.reason() {
        case .deadlineExceeded: throw deadlineExceeded
        case .userRequested, .sessionDisconnected: throw .cancelled
        case nil: break
        }
        if Task.isCancelled { throw .cancelled }
        guard let deadline = context.deadline else { return }
        guard deadline.timeIntervalSinceReferenceDate.isFinite, deadline > Date() else {
            throw deadlineExceeded
        }
    }

    static func deadlineTask(
        context: DatabaseAdapterOperationContext
    ) -> Task<Void, Never>? {
        context.deadline.map { deadline in
            Task {
                let delay = max(0, deadline.timeIntervalSinceNow)
                let nanoseconds = UInt64(
                    min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
            }
        }
    }

    static func map(
        _ failure: ClickHouseDatabaseDriverFailure,
        fallback: DatabaseAdapterFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication: return authenticationFailed
        case .configuration: return invalidConnection
        case .connection: return connectionFailed
        case .decoding: return invalidResponse
        case let .permission(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .permissionDenied,
                    message: "ClickHouse denied the requested read operation.",
                    productCode: code.map { "clickhouse.exception.\($0)" },
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case let .resourceLimit(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .resourceLimit,
                    message: "ClickHouse stopped the request at a configured resource limit.",
                    productCode: code.map { "clickhouse.exception.\($0)" },
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case let .server(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .server,
                    message: "ClickHouse could not complete the requested read operation.",
                    productCode: code.map { "clickhouse.exception.\($0)" },
                    retry: DatabaseRetryGuidance(action: .retry)))
        case .timeout: return deadlineExceeded
        case .tls: return tlsFailed
        }
    }

    static func isPermissionDenied(_ failure: DatabaseAdapterFailure) -> Bool {
        if case let .reported(envelope) = failure {
            return envelope.category == .permissionDenied
        }
        return false
    }

    static func breaksSession(_ failure: ClickHouseDatabaseDriverFailure) -> Bool {
        switch failure {
        case .connection, .tls: true
        case .authentication, .configuration, .decoding, .permission, .resourceLimit, .server,
            .timeout:
            false
        }
    }

    private static func password(
        authentication: DatabaseAuthentication,
        resolvedSecrets: [DatabaseSecretReference: Data]
    ) throws(DatabaseAdapterFailure) -> String? {
        switch authentication.kind {
        case .none:
            guard authentication.secretReferences.isEmpty,
                authentication.source == nil,
                resolvedSecrets.isEmpty
            else {
                throw invalidConnection
            }
            return nil
        case .password, .usernameAndPassword:
            guard authentication.source == nil,
                authentication.secretReferences.count == 1,
                let reference = authentication.secretReferences.first,
                reference.purpose == .password,
                resolvedSecrets.count == 1,
                let data = resolvedSecrets[reference],
                let password = String(data: data, encoding: .utf8),
                validCredential(password)
            else {
                throw invalidConnection
            }
            return password
        case .token, .apiKey, .scram, .x509, .cloudIdentity:
            throw invalidConnection
        }
    }

    private static func optionalName(
        _ value: String?
    ) throws(DatabaseAdapterFailure) -> String? {
        guard let value else { return nil }
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw invalidConnection
        }
        return value
    }

    private static func effectiveTimeout(
        configured: UInt64,
        deadline: Date?
    ) throws(DatabaseAdapterFailure) -> UInt64 {
        guard configured > 0 else { throw invalidConnection }
        guard let deadline else { return configured }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else { throw deadlineExceeded }
        return min(configured, UInt64(max(1, floor(remaining * 1_000))))
    }

    private static func validHost(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
            })
            && !value.contains("/") && !value.contains("?") && !value.contains("#")
            && !value.contains("@")
    }

    private static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 16_384 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private static func failure(
        category: DatabaseErrorCategory,
        message: String,
        code: String,
        retry: DatabaseRetryAction = .none
    ) -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: category,
                message: message,
                productCode: code,
                retry: DatabaseRetryGuidance(action: retry)))
    }
}
