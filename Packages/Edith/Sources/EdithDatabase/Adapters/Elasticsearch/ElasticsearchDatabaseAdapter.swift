import Foundation

struct ElasticsearchDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "elasticsearch"
    let products: Set<DatabaseProduct> = [.elasticsearch]
    private let connector: ElasticsearchDatabaseClientConnector

    init(
        connector: @escaping ElasticsearchDatabaseClientConnector = { plan in
            try await URLSessionElasticsearchDatabaseClient.connect(plan)
        }
    ) {
        self.connector = connector
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await ElasticsearchDatabaseAdapterSupport.check(context)
        let plan = try ElasticsearchDatabaseAdapterSupport.connectionPlan(
            connection,
            context: context)
        let established = try await ElasticsearchDatabaseAdapterSupport.establish(
            plan: plan,
            connector: connector,
            context: context)
        return ElasticsearchDatabaseAdapterSession(
            connection: connection.definition,
            productIdentity: established.identity,
            client: established.client,
            requestTimeoutMilliseconds: plan.requestTimeoutMilliseconds)
    }
}

actor ElasticsearchDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any ElasticsearchDatabaseClient)?
    private let requestTimeoutMilliseconds: UInt64
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: ElasticsearchDatabaseAdapterActiveOperation?
    private var mappingCache: [String: [DatabaseFieldDescriptor]] = [:]

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any ElasticsearchDatabaseClient,
        requestTimeoutMilliseconds: UInt64
    ) {
        self.connection = connection
        self.productIdentity = productIdentity
        self.client = client
        self.requestTimeoutMilliseconds = requestTimeoutMilliseconds
    }

    func lifecycleState() -> DatabaseAdapterSessionState {
        state
    }

    func discoverCapabilities(
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseCapabilityReport {
        let identity: DatabaseProductIdentity = try await perform(
            context: context,
            fallback: ElasticsearchDatabaseAdapterSupport.connectionFailed
        ) { client in
            try await client.discoverIdentity()
        }
        guard
            ElasticsearchDatabaseStableIdentity(identity)
                == ElasticsearchDatabaseStableIdentity(productIdentity)
        else {
            await failAndClose()
            throw ElasticsearchDatabaseAdapterSupport.connectionFailed
        }
        let report = ElasticsearchDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try validateConnection(request.target)
        if ElasticsearchDatabaseReadCompiler.isDiscoveryTarget(request.target) {
            return try await discoverPage(request, context: context)
        }
        let plan = try ElasticsearchDatabaseReadCompiler.compileBrowse(
            request,
            sessionID: id,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds)
        return try await executeSearch(
            plan,
            request: request,
            context: context)
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try validateConnection(request.source.target)
        let plan = try ElasticsearchDatabaseReadCompiler.compileQuery(
            request,
            sessionID: id,
            requestTimeoutMilliseconds: requestTimeoutMilliseconds)
        return try await executeSearch(
            plan,
            request: request.source,
            context: context)
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        throw ElasticsearchDatabaseAdapterSupport.readOnlyViolation
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        try await requireAvailableContext(context)
        throw ElasticsearchDatabaseAdapterSupport.readOnlyViolation
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw ElasticsearchDatabaseAdapterSupport.streamUnavailable
    }

    func cancel(_ operationID: DatabaseOperationID) async -> DatabaseAdapterCancellationResult {
        guard let activeOperation, activeOperation.operationID == operationID else {
            return DatabaseAdapterCancellationResult(
                support: .cooperative,
                disposition: .alreadyFinished)
        }
        await activeOperation.cancellation.cancel(.userRequested)
        await interrupt(operationID: operationID)
        return DatabaseAdapterCancellationResult(
            support: .cooperative,
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
        mappingCache.removeAll()
        await client?.disconnect()
        state = .disconnected
    }

    func resourceIsOpen() -> Bool {
        client != nil
    }

    private func discoverPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        guard request.continuation == nil,
            request.projection == nil,
            request.filter == nil,
            request.sorts.isEmpty,
            request.consistency != .strong
        else {
            throw ElasticsearchDatabaseAdapterSupport.invalidRequest
        }
        let startedAt = ContinuousClock.now
        do {
            let response: ElasticsearchDatabaseResolveResponse = try await perform(
                context: context,
                fallback: ElasticsearchDatabaseAdapterSupport.invalidResponse
            ) { client in
                try await client.resolveIndexes()
            }
            let page = try ElasticsearchDatabaseReadCompiler.discoveryPage(
                response: response,
                request: request,
                startedAt: startedAt)
            try page.validate(for: request)
            return page
        } catch let failure {
            guard ElasticsearchDatabaseAdapterSupport.isPermissionDenied(failure) else {
                throw failure
            }
            return try ElasticsearchDatabaseReadCompiler.permissionDegradedDiscoveryPage(
                request: request,
                startedAt: startedAt)
        }
    }

    private func executeSearch(
        _ plan: ElasticsearchDatabaseSearchPlan,
        request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = ContinuousClock.now
        let cachedFields = mappingCache[plan.target]
        let execution: ElasticsearchDatabaseSearchExecution = try await perform(
            context: context,
            fallback: ElasticsearchDatabaseAdapterSupport.invalidResponse
        ) { client in
            let mapping: ElasticsearchDatabaseMappingResponse?
            let metadataPermissionDenied: Bool
            if cachedFields == nil {
                do {
                    mapping = try await client.mapping(target: plan.target)
                    metadataPermissionDenied = false
                } catch ElasticsearchDatabaseDriverFailure.permission {
                    mapping = nil
                    metadataPermissionDenied = true
                }
            } else {
                mapping = nil
                metadataPermissionDenied = false
            }
            let pointInTimeID: String
            if let continuation = plan.continuation {
                pointInTimeID = continuation.pointInTimeID
            } else {
                pointInTimeID = try await client.openPointInTime(
                    target: plan.target,
                    keepAlive: "60s")
            }
            do {
                let response = try await client.search(
                    body: plan.body,
                    pointInTimeID: pointInTimeID)
                return ElasticsearchDatabaseSearchExecution(
                    response: response,
                    openedPointInTimeID: pointInTimeID,
                    mapping: mapping,
                    metadataPermissionDenied: metadataPermissionDenied)
            } catch ElasticsearchDatabaseDriverFailure.server(404) {
                try? await client.closePointInTime(pointInTimeID)
                throw ElasticsearchDatabaseAdapterSupport.invalidContinuation
            } catch {
                try? await client.closePointInTime(pointInTimeID)
                throw error
            }
        }
        let fields: [DatabaseFieldDescriptor]
        if let cachedFields {
            fields = cachedFields
        } else if let mapping = execution.mapping {
            fields = try ElasticsearchDatabaseReadCompiler.fieldDescriptors(mapping)
            if mappingCache.count >= 32, let first = mappingCache.keys.sorted().first {
                mappingCache.removeValue(forKey: first)
            }
            mappingCache[plan.target] = fields
        } else {
            fields = []
        }
        let activePointInTimeID =
            execution.response.pointInTimeID
            ?? execution.openedPointInTimeID
        do {
            let page = try ElasticsearchDatabaseAdapterSupport.page(
                response: execution.response,
                fields: fields,
                metadataPermissionDenied: execution.metadataPermissionDenied,
                request: request,
                requestDigest: plan.requestDigest,
                sessionID: id,
                pointInTimeID: activePointInTimeID,
                aggregationOnly: plan.aggregationOnly,
                startedAt: startedAt)
            try page.validate(for: request)
            if page.nextContinuation == nil, let client {
                try? await client.closePointInTime(activePointInTimeID)
            }
            return page
        } catch {
            if let client {
                try? await client.closePointInTime(activePointInTimeID)
            }
            throw error
        }
    }

    private func validateConnection(
        _ target: DatabaseTargetIdentifier
    ) throws(DatabaseAdapterFailure) {
        guard target.connectionID == connection.id else {
            throw ElasticsearchDatabaseAdapterSupport.invalidTarget
        }
    }

    private func connectedClient() throws(DatabaseAdapterFailure)
        -> any ElasticsearchDatabaseClient
    {
        guard state == .connected, let client else {
            throw ElasticsearchDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await ElasticsearchDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await ElasticsearchDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body: @escaping @Sendable (any ElasticsearchDatabaseClient) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await ElasticsearchDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw ElasticsearchDatabaseAdapterSupport.operationBusy
        }
        activeOperation = ElasticsearchDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)
        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = ElasticsearchDatabaseAdapterSupport.deadlineTask(context: context)
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
            try await ElasticsearchDatabaseAdapterSupport.check(context)
            return output
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded:
                await interrupt(operationID: context.operationID)
                throw ElasticsearchDatabaseAdapterSupport.deadlineExceeded
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
            if let driverFailure = error as? ElasticsearchDatabaseDriverFailure {
                if ElasticsearchDatabaseAdapterSupport.breaksSession(driverFailure) {
                    await failAndClose()
                }
                throw ElasticsearchDatabaseAdapterSupport.map(
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
        mappingCache.removeAll()
        state = .failed
        await client?.disconnect()
    }
}

private struct ElasticsearchDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

private struct ElasticsearchDatabaseSearchExecution: Sendable {
    let response: ElasticsearchDatabaseSearchResponse
    let openedPointInTimeID: String
    let mapping: ElasticsearchDatabaseMappingResponse?
    let metadataPermissionDenied: Bool
}

struct ElasticsearchDatabaseEstablishedClient: Sendable {
    let client: any ElasticsearchDatabaseClient
    let identity: DatabaseProductIdentity
}

private struct ElasticsearchDatabaseStableIdentity: Equatable {
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

enum ElasticsearchDatabaseAdapterSupport {
    static let connectionFailed = failure(
        category: .connectionFailed,
        message: "The Elasticsearch server could not be reached.",
        code: "elasticsearch.connection.failed",
        retry: .reconnect)
    static let authenticationFailed = failure(
        category: .authenticationFailed,
        message: "Elasticsearch authentication failed.",
        code: "elasticsearch.authentication.failed",
        retry: .reauthenticate)
    static let tlsFailed = failure(
        category: .tlsFailed,
        message: "The Elasticsearch TLS connection failed.",
        code: "elasticsearch.tls.failed",
        retry: .userDecision)
    static let disconnected = failure(
        category: .connectionFailed,
        message: "The Elasticsearch session is disconnected.",
        code: "elasticsearch.session.disconnected",
        retry: .reconnect)
    static let invalidConnection = failure(
        category: .invalidRequest,
        message: "The Elasticsearch connection configuration is invalid.",
        code: "elasticsearch.connection.invalid")
    static let deadlineExceeded = failure(
        category: .timeout,
        message: "The Elasticsearch operation deadline was exceeded.",
        code: "elasticsearch.deadline_exceeded",
        retry: .retry)
    static let invalidRequest = failure(
        category: .invalidRequest,
        message: "The Elasticsearch read request is invalid.",
        code: "elasticsearch.request.invalid")
    static let unsafeRequest = failure(
        category: .readOnlyViolation,
        message: "The Elasticsearch request is not allowed by the read-only adapter.",
        code: "elasticsearch.request.unsafe")
    static let invalidTarget = failure(
        category: .invalidRequest,
        message: "The Elasticsearch target is invalid.",
        code: "elasticsearch.target.invalid")
    static let invalidContinuation = failure(
        category: .conflict,
        message: "The Elasticsearch continuation is invalid or expired.",
        code: "elasticsearch.continuation.invalid",
        retry: .createNewPreview)
    static let invalidResponse = failure(
        category: .decoding,
        message: "Elasticsearch returned an invalid bounded response.",
        code: "elasticsearch.response.invalid",
        retry: .retry)
    static let operationBusy = failure(
        category: .conflict,
        message: "The Elasticsearch session already has an active operation.",
        code: "elasticsearch.operation.busy",
        retry: .retry)
    static let readOnlyViolation = failure(
        category: .readOnlyViolation,
        message: "The Elasticsearch adapter does not permit mutations.",
        code: "elasticsearch.read_only")
    static let streamUnavailable = failure(
        category: .unsupported,
        message: "Elasticsearch streaming is unavailable; use bounded PIT pages.",
        code: "elasticsearch.stream.unavailable")

    static func connectionPlan(
        _ resolved: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseConnectionPlan {
        let definition = resolved.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .elasticsearch,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.namespaces.catalog == nil,
            definition.namespaces.schema == nil,
            definition.namespaces.database == nil,
            definition.namespaces.logicalDatabase == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil,
            definition.tls.serverName == nil,
            [.automatic, .standalone, .cluster].contains(definition.deploymentMode),
            definition.readOnlyPolicy != .disabled
                || definition.productionPolicy == .prohibitMutations,
            case let .network(endpoints) = definition.location,
            endpoints.count == 1,
            let endpoint = endpoints.first,
            [.primary, .seed, .node].contains(endpoint.role),
            validHost(endpoint.host)
        else {
            throw invalidConnection
        }
        let scheme: String
        switch (definition.tls.mode, definition.tls.verification) {
        case (.disabled, .none):
            scheme = "http"
        case (.required, .full):
            scheme = "https"
        default:
            throw invalidConnection
        }
        let authorization = try authorization(
            definition: definition,
            secrets: resolved.secrets)
        var components = URLComponents()
        components.scheme = scheme
        components.host = endpoint.host
        components.port = endpoint.port.value
        guard let url = components.url else { throw invalidConnection }
        let connectTimeout = try effectiveConnectTimeout(
            configured: definition.limits.connectionTimeout.milliseconds,
            deadline: context.deadline)
        return ElasticsearchDatabaseConnectionPlan(
            endpoint: url,
            authorization: authorization,
            connectTimeoutMilliseconds: connectTimeout,
            requestTimeoutMilliseconds: definition.limits.operationTimeout.milliseconds,
            maximumResponseBytes: ElasticsearchDatabaseTransport.maximumResponseBytes)
    }

    static func establish(
        plan: ElasticsearchDatabaseConnectionPlan,
        connector: @escaping ElasticsearchDatabaseClientConnector,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseEstablishedClient {
        let establishmentTask = Task {
            let client = try await connector(plan)
            do {
                let identity = try await client.discoverIdentity()
                guard identity.product == .elasticsearch,
                    identity.distribution == "Elasticsearch"
                else {
                    throw connectionFailed
                }
                return ElasticsearchDatabaseEstablishedClient(
                    client: client,
                    identity: identity)
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
            case .deadlineExceeded:
                throw deadlineExceeded
            case .userRequested, .sessionDisconnected:
                throw .cancelled
            case nil:
                break
            }
            if error is CancellationError || Task.isCancelled {
                throw .cancelled
            }
            if let failure = error as? DatabaseAdapterFailure {
                throw failure
            }
            if let driverFailure = error as? ElasticsearchDatabaseDriverFailure {
                throw map(driverFailure, fallback: connectionFailed)
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
            message: "Index metadata is discovered lazily and may be permission limited.",
            missingPermissions: ["view_index_metadata"])
        let unsafeReason = DatabaseCapabilityUnavailableReason(
            category: .unsafe,
            message: "The Elasticsearch adapter is strictly read-only.")
        let unavailableReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is not provided by the bounded Elasticsearch reader.")
        let available: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.connectionTest, .sharedRequired),
            (.query, .familyRequired),
            (.queryCancellation, .sharedRequired),
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
            (.explain, .familyRequired),
            (.exportData, .sharedRequired),
            (.transactions, .familyRequired),
            (.monitoring, .productRequired),
        ]
        let limits = [
            DatabaseCapabilityLimit(
                name: "pageRecords",
                value: UInt64(DatabasePageSize.range.upperBound),
                unit: "records"),
            DatabaseCapabilityLimit(
                name: "pageBytes",
                value: UInt64(DatabaseAdapterBounds.maximumPageBytes),
                unit: "bytes"),
            DatabaseCapabilityLimit(name: "pitKeepAlive", value: 60, unit: "seconds"),
        ]
        let statuses =
            available.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .available,
                    limits: identifier == .browse || identifier == .query ? limits : [])
            }
            + metadata.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .degraded,
                    reason: metadataReason)
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
            }
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: statuses,
            permissions: [
                DatabasePermissionStatus(name: "read", granted: nil, scope: "selected target"),
                DatabasePermissionStatus(
                    name: "view_index_metadata",
                    granted: nil,
                    scope: "selected target"),
            ],
            pagingModes: [.pointInTime],
            mutationModes: [.unsupported],
            transactionModes: [.none],
            cancellationModes: [.cooperative, .protocolCancellation],
            safetyLimitations: [
                "Only fixed read-only resolve, mapping, PIT, search, and PIT close endpoints are used.",
                "Scroll, deep offsets, scripts, mutation APIs, and arbitrary endpoint paths are rejected.",
                "PIT continuations expire after 60 seconds and bind to one session and request.",
            ],
            discoveredAt: discoveredAt,
            expiresAt: discoveredAt.addingTimeInterval(300))
    }

    static func page(
        response: ElasticsearchDatabaseSearchResponse,
        fields: [DatabaseFieldDescriptor],
        metadataPermissionDenied: Bool,
        request: DatabaseAdapterPageRequest,
        requestDigest: String,
        sessionID: DatabaseAdapterSessionID,
        pointInTimeID: String,
        aggregationOnly: Bool,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let records: [DatabaseRecord]
        let hasMore: Bool
        if aggregationOnly {
            guard response.hits.hits.isEmpty, let aggregations = response.aggregations else {
                throw invalidResponse
            }
            var aggregationFields: [DatabaseObjectField] = []
            aggregationFields.reserveCapacity(aggregations.count)
            for name in aggregations.keys.sorted() {
                guard let value = aggregations[name] else { throw invalidResponse }
                do {
                    aggregationFields.append(
                        DatabaseObjectField(
                            name: name,
                            value: try value.databaseValue()))
                } catch {
                    throw invalidResponse
                }
            }
            records = [DatabaseRecord(fields: aggregationFields)]
            hasMore = false
        } else {
            hasMore = response.hits.hits.count > request.pageSize.value
            records = try response.hits.hits.prefix(request.pageSize.value).map(record)
        }
        let next: DatabaseAdapterContinuation?
        if hasMore {
            guard let sort = response.hits.hits.prefix(request.pageSize.value).last?.sort else {
                throw invalidResponse
            }
            next = try ElasticsearchDatabaseReadCompiler.nextContinuation(
                sessionID: sessionID,
                request: request,
                digest: requestDigest,
                pointInTimeID: pointInTimeID,
                sort: sort)
        } else {
            next = nil
        }
        var warnings: [DatabaseWarning] = []
        if response.hits.total.relation == .greaterThanOrEqual {
            warnings.append(
                DatabaseWarning(
                    code: "elasticsearch.total.lower_bound",
                    message: "Elasticsearch reported a lower bound for total hits.",
                    severity: .information,
                    target: request.target))
        }
        if response.timedOut {
            warnings.append(
                DatabaseWarning(
                    code: "elasticsearch.search.timeout",
                    message: "Elasticsearch returned results before completing the search.",
                    severity: .caution,
                    target: request.target))
        }
        if response.shards.failed > 0 {
            warnings.append(
                DatabaseWarning(
                    code: "elasticsearch.shards.partial",
                    message: "One or more Elasticsearch shards did not return results.",
                    severity: .caution,
                    target: request.target))
        }
        if metadataPermissionDenied {
            warnings.append(
                DatabaseWarning(
                    code: "elasticsearch.mapping.permission",
                    message: "Elasticsearch denied mapping metadata; records remain available.",
                    severity: .information,
                    target: request.target))
        }
        let partialFailures =
            response.shards.failures?.prefix(
                DatabaseAdapterBounds.maximumPartialFailures
            ).map { failure in
                DatabasePartialFailure(
                    target: request.target,
                    error: DatabaseErrorEnvelope(
                        category: .partialFailure,
                        message: "An Elasticsearch shard failed.",
                        productCode: "elasticsearch.shard.failure",
                        target: request.target,
                        retry: DatabaseRetryGuidance(action: .retry),
                        partialResult: DatabaseResultCompleteness(
                            state: .partial,
                            reason: "A shard did not return results."),
                        details: failure.shard.map {
                            [DatabaseErrorDetail(name: "shard", value: String($0))]
                        } ?? []))
            } ?? []
        let completeness: DatabaseResultCompleteness
        if response.timedOut || response.shards.failed > 0 {
            completeness = DatabaseResultCompleteness(
                state: .partial,
                reason: "Elasticsearch returned a partial search result.")
        } else if response.hits.total.relation == .greaterThanOrEqual {
            completeness = DatabaseResultCompleteness(
                state: .estimated,
                reason: "The total hit count is a lower bound.")
        } else {
            completeness = DatabaseResultCompleteness(state: .complete)
        }
        return try DatabaseAdapterPage(
            records: records,
            fields: fields,
            nextContinuation: next,
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(
                    value: response.hits.total.value,
                    accuracy: response.hits.total.relation == .equal ? .exact : .lowerBound),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: ElasticsearchDatabaseReadCompiler.elapsedMilliseconds(
                        since: startedAt),
                    serverDurationMilliseconds: response.took),
                warnings: warnings,
                partialFailures: partialFailures))
    }

    static func check(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        switch await context.cancellation.reason() {
        case .deadlineExceeded:
            throw deadlineExceeded
        case .userRequested, .sessionDisconnected:
            throw .cancelled
        case nil:
            break
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
                let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
            }
        }
    }

    static func map(
        _ failure: ElasticsearchDatabaseDriverFailure,
        fallback: DatabaseAdapterFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication:
            return authenticationFailed
        case .connection:
            return connectionFailed
        case .invalidConfiguration:
            return invalidRequest
        case .invalidResponse:
            return invalidResponse
        case .permission:
            return permissionDenied
        case .responseTooLarge:
            return resourceLimit
        case let .server(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .server,
                    message: "Elasticsearch could not complete the read operation.",
                    productCode: "elasticsearch.http." + String(safeStatus(code)),
                    retry: DatabaseRetryGuidance(action: .retry)))
        case .timeout:
            return deadlineExceeded
        case .tls:
            return tlsFailed
        case .unsupportedProduct:
            return connectionFailed
        }
    }

    static func breaksSession(_ failure: ElasticsearchDatabaseDriverFailure) -> Bool {
        switch failure {
        case .connection, .responseTooLarge, .tls, .unsupportedProduct:
            return true
        case .authentication, .invalidConfiguration, .invalidResponse, .permission, .server,
            .timeout:
            return false
        }
    }

    static func isPermissionDenied(_ failure: DatabaseAdapterFailure) -> Bool {
        guard case let .reported(envelope) = failure else { return false }
        return envelope.category == .permissionDenied
    }

    private static let permissionDenied = failure(
        category: .permissionDenied,
        message: "Elasticsearch denied the requested read operation.",
        code: "elasticsearch.permission.denied",
        retry: .userDecision)
    private static let resourceLimit = failure(
        category: .resourceLimit,
        message: "The Elasticsearch response exceeded the configured bound.",
        code: "elasticsearch.response.too_large",
        retry: .userDecision)

    private static func record(
        _ hit: ElasticsearchDatabaseSearchResponse.Hit
    ) throws(DatabaseAdapterFailure) -> DatabaseRecord {
        let sourceFields: [DatabaseObjectField]
        if let source = hit.source {
            guard case let .object(values) = source else { throw invalidResponse }
            var converted: [DatabaseObjectField] = []
            converted.reserveCapacity(values.count)
            for name in values.keys.sorted() {
                guard let value = values[name] else { throw invalidResponse }
                do {
                    converted.append(
                        DatabaseObjectField(
                            name: name,
                            value: try value.databaseValue()))
                } catch {
                    throw invalidResponse
                }
            }
            sourceFields = converted
        } else {
            sourceFields = []
        }
        var fields = sourceFields
        if let highlight = hit.highlight, !highlight.isEmpty {
            fields.append(
                DatabaseObjectField(
                    name: "_highlight",
                    value: .object(
                        highlight.keys.sorted().compactMap { name in
                            highlight[name].map { fragments in
                                DatabaseObjectField(
                                    name: name,
                                    value: .array(fragments.map(DatabaseValue.string)))
                            }
                        })))
        }
        let identity: DatabaseRecordIdentity?
        if let identifier = hit.identifier {
            var concurrency: [DatabaseIdentityComponent] = []
            if let sequenceNumber = hit.sequenceNumber {
                concurrency.append(
                    DatabaseIdentityComponent(
                        name: "_seq_no",
                        value: .signedInteger(sequenceNumber)))
            }
            if let primaryTerm = hit.primaryTerm {
                concurrency.append(
                    DatabaseIdentityComponent(
                        name: "_primary_term",
                        value: .signedInteger(primaryTerm)))
            }
            identity = DatabaseRecordIdentity(
                kind: .searchDocument,
                components: [
                    DatabaseIdentityComponent(name: "_index", value: .string(hit.index)),
                    DatabaseIdentityComponent(name: "_id", value: .string(identifier)),
                ],
                concurrencyTokens: concurrency)
        } else {
            identity = nil
        }
        return DatabaseRecord(identity: identity, fields: fields)
    }

    private static func authorization(
        definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data]
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseAuthorization {
        let references = definition.authentication.secretReferences
        switch definition.authentication.kind {
        case .none:
            guard definition.username == nil,
                definition.authentication.source == nil,
                references.isEmpty,
                secrets.isEmpty
            else { throw invalidConnection }
            return .none
        case .password, .usernameAndPassword:
            guard let username = definition.username,
                validCredential(username),
                definition.authentication.source == nil,
                references.count == 1,
                references[0].purpose == .password,
                secrets.count == 1,
                let password = secret(references[0], secrets: secrets)
            else { throw invalidConnection }
            return .basic(username: username, password: password)
        case .token:
            guard definition.username == nil,
                definition.authentication.source == nil,
                references.count == 1,
                references[0].purpose == .token,
                secrets.count == 1,
                let token = secret(references[0], secrets: secrets)
            else { throw invalidConnection }
            return .bearer(token: token)
        case .apiKey:
            guard definition.username == nil,
                definition.authentication.source == nil,
                references.count == 2,
                Set(references.map(\.purpose)) == [.apiKeyIdentifier, .apiKeySecret],
                secrets.count == 2,
                let identifierReference = references.first(where: {
                    $0.purpose == .apiKeyIdentifier
                }),
                let secretReference = references.first(where: { $0.purpose == .apiKeySecret }),
                let identifier = secret(identifierReference, secrets: secrets),
                let value = secret(secretReference, secrets: secrets)
            else { throw invalidConnection }
            return .apiKey(identifier: identifier, secret: value)
        case .scram, .x509, .cloudIdentity:
            throw invalidConnection
        }
    }

    private static func secret(
        _ reference: DatabaseSecretReference,
        secrets: [DatabaseSecretReference: Data]
    ) -> String? {
        guard let data = secrets[reference],
            let value = String(data: data, encoding: .utf8),
            validCredential(value)
        else { return nil }
        return value
    }

    private static func effectiveConnectTimeout(
        configured: UInt64,
        deadline: Date?
    ) throws(DatabaseAdapterFailure) -> UInt64 {
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
    }

    private static func validCredential(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_048_576 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func safeStatus(_ value: Int) -> Int {
        (100...599).contains(value) ? value : 500
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
