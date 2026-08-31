import Foundation
import MongoCore
import MongoKitten

struct MongoDBDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "mongodb"
    let products: Set<DatabaseProduct> = [.mongoDB]
    private let connector: MongoDBDatabaseClientConnector

    init(
        connector: @escaping MongoDBDatabaseClientConnector = { plan, context in
            try await MongoKittenDatabaseClient.connect(plan, context: context)
        }
    ) {
        self.connector = connector
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await MongoDBDatabaseAdapterSupport.check(context)
        let plan = try MongoDBDatabaseAdapterSupport.connectionPlan(connection)
        var client: (any MongoDBDatabaseClient)?
        do {
            client = try await connector(plan, context)
            guard let client else {
                throw MongoDBDatabaseAdapterSupport.connectionFailed
            }
            let identity = try await client.discoverIdentity()
            guard identity.product == .mongoDB else {
                throw MongoDBDatabaseAdapterSupport.connectionFailed
            }
            try await MongoDBDatabaseAdapterSupport.check(context)
            return MongoDBDatabaseAdapterSession(
                connection: connection.definition,
                productIdentity: identity,
                client: client)
        } catch let failure as DatabaseAdapterFailure {
            throw await Self.close(client, returning: failure)
        } catch is CancellationError {
            throw await Self.close(client, returning: .cancelled)
        } catch let failure as MongoDBDatabaseDriverFailure {
            throw await Self.close(
                client,
                returning: MongoDBDatabaseAdapterSupport.map(
                    failure,
                    fallback: MongoDBDatabaseAdapterSupport.connectionFailed))
        } catch {
            throw await Self.close(
                client,
                returning: MongoDBDatabaseAdapterSupport.connectionFailed)
        }
    }

    private static func close(
        _ client: (any MongoDBDatabaseClient)?,
        returning failure: DatabaseAdapterFailure
    ) async -> DatabaseAdapterFailure {
        do {
            try await client?.disconnect()
            return failure
        } catch {
            return MongoDBDatabaseAdapterSupport.connectionFailed
        }
    }
}

actor MongoDBDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any MongoDBDatabaseClient)?
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: MongoDBDatabaseAdapterActiveOperation?

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any MongoDBDatabaseClient
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
        let identity = try await perform(
            context: context,
            fallback: MongoDBDatabaseAdapterSupport.connectionFailed
        ) { client in
            try await client.discoverIdentity()
        }
        guard identity == productIdentity else {
            await failAndClose()
            throw MongoDBDatabaseAdapterSupport.connectionFailed
        }
        let report = MongoDBDatabaseAdapterSupport.capabilityReport(identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        if MongoDBDatabaseAdapterSupport.isCollectionDiscovery(
            request,
            connectionID: connection.id)
        {
            let prepared = try MongoDBDatabaseAdapterSupport.prepareCollectionDiscovery(
                request,
                connectionID: connection.id,
                maximumTimeMilliseconds:
                    try MongoDBDatabaseAdapterSupport
                    .maximumTimeMilliseconds(
                        connection: connection,
                        context: context))
            let result = try await perform(
                context: context,
                fallback: MongoDBDatabaseAdapterSupport.readFailed
            ) { client in
                try await client.listCollections(prepared.plan)
            }
            let page = try MongoDBDatabaseAdapterSupport.collectionPage(
                result,
                prepared: prepared,
                request: request,
                startedAt: startedAt)
            try page.validate(for: request)
            return page
        }
        let prepared = try MongoDBDatabaseAdapterSupport.prepareBrowse(
            request,
            connectionID: connection.id,
            maximumTimeMilliseconds: try MongoDBDatabaseAdapterSupport.maximumTimeMilliseconds(
                connection: connection,
                context: context))
        let page = try await perform(
            context: context,
            fallback: MongoDBDatabaseAdapterSupport.readFailed
        ) { client in
            let result = try await client.read(prepared.plan)
            return try await MongoDBDatabaseAdapterSupport.page(
                result,
                prepared: prepared,
                request: request,
                startedAt: startedAt,
                context: context)
        }
        try page.validate(for: request)
        return page
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        let prepared = try MongoDBDatabaseAdapterSupport.prepareQuery(
            request,
            connectionID: connection.id,
            maximumTimeMilliseconds: try MongoDBDatabaseAdapterSupport.maximumTimeMilliseconds(
                connection: connection,
                context: context))
        let page = try await perform(
            context: context,
            fallback: MongoDBDatabaseAdapterSupport.queryFailed
        ) { client in
            let result = try await client.read(prepared.plan)
            return try await MongoDBDatabaseAdapterSupport.page(
                result,
                prepared: prepared,
                request: request.source,
                startedAt: startedAt,
                context: context)
        }
        try page.validate(for: request.source)
        return page
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        throw MongoDBDatabaseAdapterSupport.readOnlyViolation
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        try await requireAvailableContext(context)
        throw MongoDBDatabaseAdapterSupport.readOnlyViolation
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw MongoDBDatabaseAdapterSupport.capabilityUnavailable
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
        do {
            try await client?.disconnect()
            state = .disconnected
        } catch {
            self.client = client
            state = .failed
        }
    }

    func resourceIsOpen() -> Bool {
        client != nil
    }

    private func connectedClient() throws(DatabaseAdapterFailure) -> any MongoDBDatabaseClient {
        guard state == .connected, let client else {
            throw MongoDBDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await MongoDBDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await MongoDBDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body: @escaping @Sendable (any MongoDBDatabaseClient) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await MongoDBDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw MongoDBDatabaseAdapterSupport.operationBusy
        }
        activeOperation = MongoDBDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)

        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = context.deadline.map { deadline in
            Task { [weak self] in
                let delay = max(0, deadline.timeIntervalSinceNow)
                let nanoseconds = UInt64(
                    min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
                await self?.interrupt(operationID: context.operationID)
            }
        }
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
            try await MongoDBDatabaseAdapterSupport.check(context)
            return output
        } catch let failure as DatabaseAdapterFailure {
            if await context.cancellation.reason() != nil || Task.isCancelled {
                await failAndClose()
            }
            throw failure
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded:
                await failAndClose()
                throw MongoDBDatabaseAdapterSupport.deadlineExceeded
            case .userRequested, .sessionDisconnected:
                await failAndClose()
                throw .cancelled
            case nil:
                break
            }
            if error is CancellationError || Task.isCancelled {
                await failAndClose()
                throw .cancelled
            }
            if let driverFailure = error as? MongoDBDatabaseDriverFailure {
                if case .connection = driverFailure {
                    await failAndClose()
                }
                throw MongoDBDatabaseAdapterSupport.map(
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
        state = .failed
        guard let client else { return }
        self.client = nil
        do {
            try await client.disconnect()
        } catch {
            self.client = client
            state = .failed
        }
    }
}

private struct MongoDBDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

enum MongoDBDatabaseAdapterReadKind: String, Codable, Sendable {
    case browse
    case query
}

enum MongoDBDatabaseAdapterSortDirection: String, Codable, Sendable {
    case ascending
    case descending
}

struct MongoDBDatabaseAdapterContinuationPayload: Codable, Sendable {
    let version: Int
    let kind: MongoDBDatabaseAdapterReadKind
    let database: String
    let collection: String
    let direction: MongoDBDatabaseAdapterSortDirection
    let objectID: String
}

struct MongoDBDatabaseAdapterPreparedRead: Sendable {
    let plan: MongoDBDatabaseReadPlan
    let kind: MongoDBDatabaseAdapterReadKind
    let stableDirection: MongoDBDatabaseAdapterSortDirection?
    let hidesObjectID: Bool
}

struct MongoDBDatabaseDiscoveryContinuationPayload: Codable, Sendable {
    let version: Int
    let database: String
    let offset: Int
}

struct MongoDBDatabaseAdapterPreparedDiscovery: Sendable {
    let plan: MongoDBDatabaseCollectionPlan
    let offset: Int
}

enum MongoDBDatabaseAdapterSupport {
    static let maximumDiscoveredCollections = 10_000
    static let connectionFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The MongoDB server could not be reached.",
            productCode: "mongodb.connection.failed",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let authenticationFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .authenticationFailed,
            message: "MongoDB authentication failed.",
            productCode: "mongodb.authentication.failed",
            retry: DatabaseRetryGuidance(action: .reauthenticate)))

    static let disconnected = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The MongoDB session is disconnected.",
            productCode: "mongodb.session.disconnected",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let invalidConnection = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MongoDB connection configuration is invalid.",
            productCode: "mongodb.connection.invalid"))

    static let invalidRead = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MongoDB collection page request is invalid.",
            productCode: "mongodb.read.invalid"))

    static let invalidQuery = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MongoDB query request is invalid.",
            productCode: "mongodb.query.invalid"))

    static let invalidContinuation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MongoDB continuation is invalid.",
            productCode: "mongodb.continuation.invalid"))

    static let unsupportedFilter = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "The requested MongoDB filter operation is unavailable.",
            productCode: "mongodb.filter.unsupported"))

    static let readFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "The MongoDB collection page could not be read.",
            productCode: "mongodb.read.failed"))

    static let queryFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "The MongoDB query could not be executed.",
            productCode: "mongodb.query.failed"))

    static let decodingFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .decoding,
            message: "The MongoDB result contains an unsupported BSON value.",
            productCode: "mongodb.result.decoding_failed"))

    static let resultTooLarge = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .resourceLimit,
            message: "The MongoDB result exceeds the bounded page limit.",
            productCode: "mongodb.result.too_large"))

    static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "The MongoDB operation deadline was exceeded.",
            productCode: "mongodb.deadline_exceeded"))

    static let operationBusy = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .conflict,
            message: "The MongoDB session is already executing an operation.",
            productCode: "mongodb.operation.busy",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let capabilityUnavailable = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "The requested MongoDB capability is unavailable.",
            productCode: "mongodb.capability.not_implemented"))

    static let readOnlyViolation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .readOnlyViolation,
            message: "The MongoDB adapter does not expose mutation operations.",
            productCode: "mongodb.read_only"))

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
        if Task.isCancelled {
            throw .cancelled
        }
        guard let deadline = context.deadline else { return }
        guard deadline.timeIntervalSinceReferenceDate.isFinite, deadline > Date() else {
            throw deadlineExceeded
        }
    }

    static func maximumTimeMilliseconds(
        connection: DatabaseConnectionDefinition,
        context: DatabaseAdapterOperationContext
    ) throws(DatabaseAdapterFailure) -> Int32 {
        let configured = connection.limits.operationTimeout.milliseconds
        let boundedConfigured = min(configured, UInt64(Int32.max))
        guard let deadline = context.deadline else {
            return Int32(boundedConfigured)
        }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else {
            throw deadlineExceeded
        }
        let remainingMilliseconds = UInt64(max(1, floor(remaining * 1_000)))
        return Int32(min(boundedConfigured, remainingMilliseconds, UInt64(Int32.max)))
    }

    static func connectionPlan(
        _ resolved: DatabaseResolvedConnection
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseConnectionPlan {
        let definition = resolved.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .mongoDB,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.namespaces.catalog == nil,
            definition.namespaces.schema == nil,
            definition.namespaces.logicalDatabase == nil,
            definition.tls.serverName == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil
        else {
            throw invalidConnection
        }
        guard
            [.automatic, .standalone, .replicaSet, .shardedCluster].contains(
                definition.deploymentMode)
        else {
            throw invalidConnection
        }
        guard case let .network(endpoints) = definition.location,
            !endpoints.isEmpty,
            endpoints.count <= 32
        else {
            throw invalidConnection
        }
        var hosts: [ConnectionSettings.Host] = []
        var seen = Set<String>()
        for endpoint in endpoints {
            guard [.primary, .seed, .router, .node].contains(endpoint.role),
                validHost(endpoint.host)
            else {
                throw invalidConnection
            }
            let key = "\(endpoint.host.lowercased()):\(endpoint.port.value)"
            guard seen.insert(key).inserted else {
                throw invalidConnection
            }
            hosts.append(
                ConnectionSettings.Host(
                    hostname: endpoint.host,
                    port: endpoint.port.value))
        }
        let database = try optionalName(definition.namespaces.database)
        let authentication: ConnectionSettings.Authentication
        let authenticationSource: String?
        switch definition.authentication.kind {
        case .none:
            guard definition.username == nil,
                definition.authentication.secretReferences.isEmpty,
                definition.authentication.source == nil,
                resolved.secrets.isEmpty
            else {
                throw invalidConnection
            }
            authentication = .unauthenticated
            authenticationSource = nil
        case .usernameAndPassword, .scram:
            guard let username = definition.username,
                validCredentialText(username),
                definition.authentication.secretReferences.count == 1,
                let reference = definition.authentication.secretReferences.first,
                reference.purpose == .password,
                resolved.secrets.count == 1,
                let passwordData = resolved.secrets[reference],
                let password = String(data: passwordData, encoding: .utf8),
                validSCRAMPassword(password)
            else {
                throw invalidConnection
            }
            authentication = .scramSha256(username: username, password: password)
            authenticationSource = try optionalName(
                definition.authentication.source ?? database ?? "admin")
        case .password, .token, .apiKey, .x509, .cloudIdentity:
            throw invalidConnection
        }
        let useSSL: Bool
        let verifySSLCertificates: Bool
        switch (definition.tls.mode, definition.tls.verification) {
        case (.disabled, .none):
            useSSL = false
            verifySSLCertificates = true
        case (.required, .full):
            useSSL = true
            verifySSLCertificates = true
        default:
            throw invalidConnection
        }
        let settings = ConnectionSettings(
            authentication: authentication,
            authenticationSource: authenticationSource,
            hosts: hosts,
            targetDatabase: database,
            useSSL: useSSL,
            verifySSLCertificates: verifySSLCertificates,
            maximumNumberOfConnections: min(definition.limits.poolSize.value, 32),
            connectTimeout: TimeInterval(definition.limits.connectionTimeout.milliseconds) / 1_000,
            socketTimeout: TimeInterval(definition.limits.operationTimeout.milliseconds) / 1_000,
            applicationName: "Edith")
        return MongoDBDatabaseConnectionPlan(settings: settings)
    }

    static func prepareBrowse(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        maximumTimeMilliseconds: Int32
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseAdapterPreparedRead {
        let target = try collectionTarget(
            request.target,
            connectionID: connectionID,
            failure: invalidRead)
        return try prepare(
            source: request,
            target: target,
            kind: .browse,
            nativeFilter: Document(),
            maximumTimeMilliseconds: maximumTimeMilliseconds,
            failure: invalidRead)
    }

    static func isCollectionDiscovery(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID
    ) -> Bool {
        guard request.target.connectionID == connectionID,
            request.target.record == nil,
            let object = request.target.object
        else { return false }
        return object.kind == .database
            && object.nativeIdentifier == nil
            && object.path.count == 1
    }

    static func prepareCollectionDiscovery(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        maximumTimeMilliseconds: Int32
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseAdapterPreparedDiscovery {
        try validateConsistency(request.consistency, failure: invalidRead)
        guard isCollectionDiscovery(request, connectionID: connectionID),
            request.projection == nil,
            request.filter == nil,
            request.sorts.isEmpty,
            let database = request.target.object?.path.first,
            validName(database)
        else {
            throw invalidRead
        }
        let offset = try discoveryOffset(
            request.continuation,
            database: database)
        let requestedEnd = offset.addingReportingOverflow(request.pageSize.value + 1)
        guard !requestedEnd.overflow,
            requestedEnd.partialValue <= maximumDiscoveredCollections + 1
        else {
            throw resultTooLarge
        }
        return MongoDBDatabaseAdapterPreparedDiscovery(
            plan: MongoDBDatabaseCollectionPlan(
                database: database,
                limit: requestedEnd.partialValue,
                batchSize: min(requestedEnd.partialValue, 500),
                maximumTimeMilliseconds: maximumTimeMilliseconds),
            offset: offset)
    }

    static func collectionPage(
        _ result: MongoDBDatabaseCollectionResult,
        prepared: MongoDBDatabaseAdapterPreparedDiscovery,
        request: DatabaseAdapterPageRequest,
        startedAt: Date
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let start = min(prepared.offset, result.names.count)
        let end = min(start + request.pageSize.value, result.names.count)
        let names = Array(result.names[start..<end])
        let hasMore = end < result.names.count || result.hasMore
        let endingOffset = prepared.offset + names.count
        let continuation: DatabaseAdapterContinuation?
        if hasMore, !names.isEmpty, endingOffset < maximumDiscoveredCollections {
            let payload: Data
            do {
                payload = try JSONEncoder().encode(
                    MongoDBDatabaseDiscoveryContinuationPayload(
                        version: 1,
                        database: prepared.plan.database,
                        offset: endingOffset))
            } catch {
                throw invalidContinuation
            }
            continuation = try DatabaseAdapterContinuation(
                mode: .offset,
                payload: payload,
                expiresAt: Date().addingTimeInterval(900))
        } else {
            continuation = nil
        }
        let records = names.map { name in
            DatabaseRecord(fields: [
                DatabaseObjectField(name: "name", value: .string(name)),
                DatabaseObjectField(name: "kind", value: .string("collection")),
            ])
        }
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let completeness: DatabaseResultCompleteness
        if hasMore, continuation == nil {
            completeness = DatabaseResultCompleteness(
                state: .truncated,
                reason: "MongoDB collection discovery reached its bounded limit.")
        } else if hasMore {
            completeness = DatabaseResultCompleteness(
                state: .partial,
                reason: "More MongoDB collections are available.")
        } else {
            completeness = DatabaseResultCompleteness(state: .complete)
        }
        return try DatabaseAdapterPage(
            records: records,
            fields: collectionDiscoveryFields,
            nextContinuation: continuation,
            metadata: DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(
                    value: UInt64(endingOffset),
                    accuracy: hasMore ? .lowerBound : .exact),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: UInt64(
                        min(elapsed * 1_000, Double(UInt64.max))))))
    }

    private static func discoveryOffset(
        _ continuation: DatabaseAdapterContinuation?,
        database: String
    ) throws(DatabaseAdapterFailure) -> Int {
        guard let continuation else { return 0 }
        guard continuation.mode == .offset,
            continuation.expiresAt.map({ $0 > Date() }) != false
        else {
            throw invalidContinuation
        }
        let payload: MongoDBDatabaseDiscoveryContinuationPayload
        do {
            payload = try JSONDecoder().decode(
                MongoDBDatabaseDiscoveryContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw invalidContinuation
        }
        guard payload.version == 1,
            payload.database == database,
            payload.offset > 0,
            payload.offset < maximumDiscoveredCollections
        else {
            throw invalidContinuation
        }
        return payload.offset
    }

    private static let collectionDiscoveryFields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("name"),
            displayName: "name",
            typeName: "string",
            isNullable: false,
            isSortable: true,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("kind"),
            displayName: "kind",
            typeName: "string",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
    ]

    static func prepareQuery(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        maximumTimeMilliseconds: Int32
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseAdapterPreparedRead {
        let target = try collectionTarget(
            request.source.target,
            connectionID: connectionID,
            failure: invalidQuery)
        guard request.language == .mongoQuery,
            request.command == "find",
            request.parameters.isEmpty
        else {
            throw invalidQuery
        }
        let nativeFilter: Document
        if let body = request.body {
            do {
                try validateNativeFilter(body)
                nativeFilter = try MongoDBDatabaseValueCodec.queryDocument(body)
            } catch {
                throw invalidQuery
            }
        } else {
            nativeFilter = Document()
        }
        return try prepare(
            source: request.source,
            target: target,
            kind: .query,
            nativeFilter: nativeFilter,
            maximumTimeMilliseconds: maximumTimeMilliseconds,
            failure: invalidQuery)
    }

    static func page(
        _ result: MongoDBDatabaseReadResult,
        prepared: MongoDBDatabaseAdapterPreparedRead,
        request: DatabaseAdapterPageRequest,
        startedAt: Date,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        var converted: [MongoDBDatabaseConvertedRecord] = []
        converted.reserveCapacity(min(request.pageSize.value, result.documents.count))
        var encodedBytes = 0
        var stoppedForBytes = false
        do {
            for document in result.documents.prefix(request.pageSize.value) {
                try await check(context)
                let record = try await MongoDBDatabaseValueCodec.convertedRecord(
                    document,
                    hidesObjectID: prepared.hidesObjectID,
                    cancellationCheck: {
                        try await check(context)
                    })
                try await check(context)
                let byteCount = try JSONEncoder().encode(record.record).count
                guard byteCount <= 12_582_912 else {
                    throw resultTooLarge
                }
                if !converted.isEmpty, byteCount > 12_582_912 - encodedBytes {
                    stoppedForBytes = true
                    break
                }
                converted.append(record)
                encodedBytes += byteCount
            }
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw decodingFailed
        }

        var hasMore =
            result.hasMore
            || result.documents.count > converted.count
            || stoppedForBytes
        while true {
            try await check(context)
            let descriptorOutput = try await fieldDescriptors(
                converted.map(\.record),
                context: context)
            try await check(context)
            let valueTruncated = converted.contains(where: \.truncated)
            var warnings: [DatabaseWarning] = []
            if valueTruncated {
                warnings.append(
                    DatabaseWarning(
                        code: "mongodb.value.preview",
                        message: "Some BSON values were returned as bounded previews.",
                        severity: .information,
                        target: request.target))
            }
            if descriptorOutput.truncated {
                warnings.append(
                    DatabaseWarning(
                        code: "mongodb.fields.truncated",
                        message: "Field descriptors were limited to the bounded field count.",
                        severity: .information,
                        target: request.target))
            }
            let continuation = try nextContinuation(
                converted: converted,
                hasMore: hasMore,
                prepared: prepared)
            let completeness: DatabaseResultCompleteness
            if valueTruncated || descriptorOutput.truncated {
                completeness = DatabaseResultCompleteness(
                    state: .truncated,
                    reason: "Some BSON values or field metadata were bounded.")
            } else if hasMore, continuation != nil {
                completeness = DatabaseResultCompleteness(
                    state: .partial,
                    reason: "More documents are available.")
            } else if hasMore {
                completeness = DatabaseResultCompleteness(
                    state: .truncated,
                    reason: "Stable continuation is unavailable for this result boundary.")
            } else {
                completeness = DatabaseResultCompleteness(state: .complete)
            }
            let elapsed = max(0, Date().timeIntervalSince(startedAt))
            let durationMilliseconds = UInt64(
                min(elapsed * 1_000, Double(UInt64.max)))
            let metadata = DatabasePageMetadata(
                completeness: completeness,
                count: DatabaseCountMetadata(accuracy: .unknown),
                timing: DatabaseQueryTiming(durationMilliseconds: durationMilliseconds),
                bytesReceived: result.bytesReceived,
                warnings: warnings)
            do {
                try await check(context)
                return try DatabaseAdapterPage(
                    records: converted.map(\.record),
                    fields: descriptorOutput.fields,
                    nextContinuation: continuation,
                    metadata: metadata)
            } catch let failure {
                guard case .limitExceeded(limit: .pageBytes, actual: _, maximum: _) = failure,
                    converted.count > 1
                else {
                    throw resultTooLarge
                }
                converted.removeLast()
                hasMore = true
            }
        }
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity
    ) -> DatabaseCapabilityReport {
        let unavailableReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is not implemented by the read-only MongoDB adapter.")
        let mutationReason = DatabaseCapabilityUnavailableReason(
            category: .unsafe,
            message: "The MongoDB adapter intentionally exposes no mutation path.")
        let capabilities = [
            DatabaseCapabilityStatus(
                id: .connectionTest,
                requirement: .sharedRequired,
                availability: .available),
            DatabaseCapabilityStatus(
                id: .browse,
                requirement: .sharedRequired,
                availability: .available,
                limits: [
                    DatabaseCapabilityLimit(
                        name: "pageRecords",
                        value: UInt64(DatabaseAdapterBounds.maximumPageRecords),
                        unit: "records"),
                    DatabaseCapabilityLimit(
                        name: "pageBytes",
                        value: UInt64(DatabaseAdapterBounds.maximumPageBytes),
                        unit: "bytes"),
                ],
                attributes: [
                    DatabaseStringAttribute(name: "operation", value: "find"),
                    DatabaseStringAttribute(name: "readConcern", value: "local"),
                ]),
            DatabaseCapabilityStatus(
                id: .query,
                requirement: .familyRequired,
                availability: .available,
                attributes: [
                    DatabaseStringAttribute(name: "language", value: "mongoQuery"),
                    DatabaseStringAttribute(name: "command", value: "find"),
                ]),
            DatabaseCapabilityStatus(
                id: .queryCancellation,
                requirement: .sharedRequired,
                availability: .available),
            DatabaseCapabilityStatus(
                id: .objectDiscovery,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: unavailableReason),
            DatabaseCapabilityStatus(
                id: .objectDescription,
                requirement: .familyRequired,
                availability: .unavailable,
                reason: unavailableReason),
            DatabaseCapabilityStatus(
                id: .explain,
                requirement: .familyRequired,
                availability: .unavailable,
                reason: unavailableReason),
            DatabaseCapabilityStatus(
                id: .insert,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .update,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .delete,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .bulkMutation,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .importData,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .exportData,
                requirement: .sharedRequired,
                availability: .unavailable,
                reason: unavailableReason),
            DatabaseCapabilityStatus(
                id: .transactions,
                requirement: .familyRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .schemaMutation,
                requirement: .productRequired,
                availability: .unavailable,
                reason: mutationReason),
            DatabaseCapabilityStatus(
                id: .monitoring,
                requirement: .productRequired,
                availability: .unavailable,
                reason: unavailableReason),
            DatabaseCapabilityStatus(
                id: .administration,
                requirement: .productRequired,
                availability: .unavailable,
                reason: mutationReason),
        ]
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: capabilities,
            pagingModes: [.keyset],
            mutationModes: [.unsupported],
            transactionModes: [.none],
            cancellationModes: [.cooperative],
            safetyLimitations: [
                "Only typed find operations are accepted.",
                "Pagination requires an ObjectId _id and either no sort or an _id sort.",
                "Cancelling a request closes the session and requires reconnecting.",
                "Session, snapshot, and strong consistency are unavailable.",
                "Mutation, streaming, discovery, explain, and administration are unavailable.",
                "Custom trust stores, client certificates, tunnels, and connection options are unavailable.",
            ],
            discoveredAt: Date())
    }

    static func map(
        _ failure: MongoDBDatabaseDriverFailure,
        fallback: DatabaseAdapterFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication:
            authenticationFailed
        case .connection:
            connectionFailed
        case let .permission(code):
            .reported(
                DatabaseErrorEnvelope(
                    category: .permissionDenied,
                    message: "MongoDB denied the requested read operation.",
                    productCode: code.map { "mongodb.server.\($0)" },
                    retry: DatabaseRetryGuidance(action: .none)))
        case .timeout:
            deadlineExceeded
        case .responseTooLarge:
            resultTooLarge
        case let .server(code):
            code == nil
                ? fallback
                : .reported(
                    DatabaseErrorEnvelope(
                        category: .server,
                        message: "MongoDB rejected the read operation.",
                        productCode: code.map { "mongodb.server.\($0)" },
                        retry: DatabaseRetryGuidance(action: .none)))
        }
    }

    private static func prepare(
        source: DatabaseAdapterPageRequest,
        target: (database: String, collection: String),
        kind: MongoDBDatabaseAdapterReadKind,
        nativeFilter: Document,
        maximumTimeMilliseconds: Int32,
        failure: DatabaseAdapterFailure
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseAdapterPreparedRead {
        try validateConsistency(source.consistency, failure: failure)
        let projection: (document: Document?, hidesObjectID: Bool)
        let sort: (document: Document, stableDirection: MongoDBDatabaseAdapterSortDirection?)
        do {
            projection = try projectionDocument(source.projection)
            sort = try sortDocument(source.sorts)
        } catch {
            throw failure
        }
        var filters: [Document] = []
        if !nativeFilter.isEmpty {
            filters.append(nativeFilter)
        }
        if let filter = source.filter {
            do {
                filters.append(try filterDocument(filter))
            } catch let adapterFailure as DatabaseAdapterFailure {
                throw adapterFailure
            } catch {
                throw failure
            }
        }
        if let continuation = source.continuation {
            guard let stableDirection = sort.stableDirection else {
                throw invalidContinuation
            }
            filters.append(
                try continuationFilter(
                    continuation,
                    kind: kind,
                    target: target,
                    direction: stableDirection))
        }
        let filter = conjunction(filters)
        let limit = source.pageSize.value + 1
        return MongoDBDatabaseAdapterPreparedRead(
            plan: MongoDBDatabaseReadPlan(
                database: target.database,
                collection: target.collection,
                filter: filter,
                projection: projection.document,
                sort: sort.document,
                limit: limit,
                batchSize: min(limit, 500),
                maximumTimeMilliseconds: maximumTimeMilliseconds),
            kind: kind,
            stableDirection: sort.stableDirection,
            hidesObjectID: projection.hidesObjectID)
    }

    private static func collectionTarget(
        _ target: DatabaseTargetIdentifier,
        connectionID: DatabaseConnectionID,
        failure: DatabaseAdapterFailure
    ) throws(DatabaseAdapterFailure) -> (database: String, collection: String) {
        guard target.connectionID == connectionID,
            target.record == nil,
            let object = target.object,
            object.kind == .collection,
            object.nativeIdentifier == nil,
            object.path.count == 2
        else {
            throw failure
        }
        let database = object.path[0]
        let collection = object.path[1]
        guard validName(database), validName(collection) else {
            throw failure
        }
        return (database, collection)
    }

    private static func projectionDocument(
        _ projection: DatabaseProjection?
    ) throws -> (document: Document?, hidesObjectID: Bool) {
        guard let projection else { return (nil, false) }
        var document = Document()
        var seen = Set<String>()
        var includesObjectID = false
        var excludesObjectID = false
        for field in projection.fields {
            guard field.alias == nil else {
                throw invalidRead
            }
            let path = try fieldPath(field.path)
            guard seen.insert(path).inserted else {
                throw invalidRead
            }
            if path == "_id" {
                includesObjectID = projection.mode == .include
                excludesObjectID = projection.mode == .exclude
                continue
            }
            document[path] = projection.mode == .include ? Int32(1) : Int32(0)
        }
        if projection.mode == .include {
            guard !projection.fields.isEmpty else {
                throw invalidRead
            }
            if includesObjectID {
                document["_id"] = Int32(1)
            }
            return (document, !includesObjectID)
        }
        return (document.isEmpty ? nil : document, excludesObjectID)
    }

    private static func sortDocument(
        _ sorts: [DatabaseSort]
    ) throws -> (document: Document, stableDirection: MongoDBDatabaseAdapterSortDirection?) {
        guard !sorts.isEmpty else {
            var document = Document()
            document["_id"] = Int32(1)
            return (document, .ascending)
        }
        var document = Document()
        var seen = Set<String>()
        for sort in sorts {
            guard sort.nullPlacement == .productDefault else {
                throw invalidRead
            }
            let path = try fieldPath(sort.field)
            guard seen.insert(path).inserted else {
                throw invalidRead
            }
            document[path] = sort.direction == .ascending ? Int32(1) : Int32(-1)
        }
        let stableDirection: MongoDBDatabaseAdapterSortDirection?
        if sorts.count == 1, try fieldPath(sorts[0].field) == "_id" {
            stableDirection = sorts[0].direction == .ascending ? .ascending : .descending
        } else {
            stableDirection = nil
        }
        return (document, stableDirection)
    }

    private static func filterDocument(_ filter: DatabaseFilter) throws -> Document {
        switch filter {
        case let .predicate(predicate):
            return try predicateDocument(predicate)
        case let .all(children):
            guard !children.isEmpty, children.count <= 256 else {
                throw unsupportedFilter
            }
            return operatorArray("$and", documents: try children.map(filterDocument))
        case let .any(children):
            guard !children.isEmpty, children.count <= 256 else {
                throw unsupportedFilter
            }
            return operatorArray("$or", documents: try children.map(filterDocument))
        case let .not(child):
            return operatorArray("$nor", documents: [try filterDocument(child)])
        }
    }

    private static func predicateDocument(
        _ predicate: DatabaseFilterPredicate
    ) throws -> Document {
        let field = try fieldPath(predicate.field)
        let values = try predicate.values.map(MongoDBDatabaseValueCodec.queryPrimitive)
        var condition: Primitive
        switch predicate.operation {
        case .equal:
            guard values.count == 1,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            condition = values[0]
        case .notEqual:
            condition = try comparison("$ne", values: values, predicate: predicate)
        case .greaterThan:
            condition = try comparison("$gt", values: values, predicate: predicate)
        case .greaterThanOrEqual:
            condition = try comparison("$gte", values: values, predicate: predicate)
        case .lessThan:
            condition = try comparison("$lt", values: values, predicate: predicate)
        case .lessThanOrEqual:
            condition = try comparison("$lte", values: values, predicate: predicate)
        case .in, .notIn:
            guard !values.isEmpty,
                values.count <= 256,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            var array = Document(isArray: true)
            for (index, value) in values.enumerated() {
                array[String(index)] = value
            }
            var operators = Document()
            operators[predicate.operation == .in ? "$in" : "$nin"] = array
            condition = operators
        case .between:
            guard values.count == 2,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            var operators = Document()
            operators["$gte"] = values[0]
            operators["$lte"] = values[1]
            condition = operators
        case .isNull:
            guard values.isEmpty,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            var operators = Document()
            operators["$type"] = Int32(10)
            condition = operators
        case .isNotNull:
            guard values.isEmpty,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            var type = Document()
            type["$type"] = Int32(10)
            var operators = Document()
            operators["$exists"] = true
            operators["$not"] = type
            condition = operators
        case .isMissing, .isNotMissing:
            guard values.isEmpty,
                predicate.caseSensitivity == .productDefault
            else {
                throw unsupportedFilter
            }
            var operators = Document()
            operators["$exists"] = predicate.operation == .isNotMissing
            condition = operators
        case .contains, .startsWith, .endsWith:
            guard predicate.values.count == 1,
                case let .string(value) = predicate.values[0],
                value.utf8.count <= 8_192
            else {
                throw unsupportedFilter
            }
            let escaped = NSRegularExpression.escapedPattern(for: value)
            let pattern: String
            switch predicate.operation {
            case .contains:
                pattern = escaped
            case .startsWith:
                pattern = "^\(escaped)"
            case .endsWith:
                pattern = "\(escaped)$"
            default:
                throw unsupportedFilter
            }
            condition = RegularExpression(
                pattern: pattern,
                options: predicate.caseSensitivity == .insensitive ? "i" : "")
        case .regularExpression, .fullText:
            throw unsupportedFilter
        }
        var document = Document()
        document[field] = condition
        return document
    }

    private static func comparison(
        _ name: String,
        values: [Primitive],
        predicate: DatabaseFilterPredicate
    ) throws -> Document {
        guard values.count == 1,
            predicate.caseSensitivity == .productDefault
        else {
            throw unsupportedFilter
        }
        var document = Document()
        document[name] = values[0]
        return document
    }

    private static func continuationFilter(
        _ continuation: DatabaseAdapterContinuation,
        kind: MongoDBDatabaseAdapterReadKind,
        target: (database: String, collection: String),
        direction: MongoDBDatabaseAdapterSortDirection
    ) throws(DatabaseAdapterFailure) -> Document {
        guard continuation.mode == .keyset,
            continuation.expiresAt.map({
                $0.timeIntervalSinceReferenceDate.isFinite && $0 > Date()
            }) != false
        else {
            throw invalidContinuation
        }
        let payload: MongoDBDatabaseAdapterContinuationPayload
        do {
            payload = try JSONDecoder().decode(
                MongoDBDatabaseAdapterContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw invalidContinuation
        }
        guard payload.version == 1,
            payload.kind == kind,
            payload.database == target.database,
            payload.collection == target.collection,
            payload.direction == direction,
            let objectID = ObjectId(payload.objectID)
        else {
            throw invalidContinuation
        }
        var comparison = Document()
        comparison[direction == .ascending ? "$gt" : "$lt"] = objectID
        var filter = Document()
        filter["_id"] = comparison
        return filter
    }

    private static func nextContinuation(
        converted: [MongoDBDatabaseConvertedRecord],
        hasMore: Bool,
        prepared: MongoDBDatabaseAdapterPreparedRead
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterContinuation? {
        guard hasMore,
            let direction = prepared.stableDirection,
            let objectID = converted.last?.objectID
        else {
            return nil
        }
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                MongoDBDatabaseAdapterContinuationPayload(
                    version: 1,
                    kind: prepared.kind,
                    database: prepared.plan.database,
                    collection: prepared.plan.collection,
                    direction: direction,
                    objectID: objectID.hexString))
        } catch {
            throw invalidContinuation
        }
        return try DatabaseAdapterContinuation(
            mode: .keyset,
            payload: payload,
            expiresAt: Date().addingTimeInterval(900))
    }

    private static func conjunction(_ filters: [Document]) -> Document {
        guard filters.count > 1 else { return filters.first ?? Document() }
        return operatorArray("$and", documents: filters)
    }

    private static func operatorArray(
        _ name: String,
        documents: [Document]
    ) -> Document {
        var array = Document(isArray: true)
        for (index, document) in documents.enumerated() {
            array[String(index)] = document
        }
        var output = Document()
        output[name] = array
        return output
    }

    private static func fieldDescriptors(
        _ records: [DatabaseRecord],
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> (
        fields: [DatabaseFieldDescriptor], truncated: Bool
    ) {
        struct State {
            var typeName: String
            var nullable: Bool
            var occurrences: Int
        }
        var order: [String] = []
        var states: [String: State] = [:]
        var truncated = false
        for record in records {
            try await check(context)
            for (index, field) in record.fields.enumerated() {
                if index.isMultiple(of: 128) {
                    try await check(context)
                }
                if var state = states[field.name] {
                    let typeName = MongoDBDatabaseValueCodec.typeName(field.value)
                    if state.typeName != typeName {
                        state.typeName = "dynamic"
                    }
                    if case .null = field.value {
                        state.nullable = true
                    }
                    state.occurrences += 1
                    states[field.name] = state
                } else if states.count < DatabaseAdapterBounds.maximumPageFields {
                    order.append(field.name)
                    states[field.name] = State(
                        typeName: MongoDBDatabaseValueCodec.typeName(field.value),
                        nullable: {
                            if case .null = field.value { return true }
                            return false
                        }(),
                        occurrences: 1)
                } else {
                    truncated = true
                }
            }
        }
        let fields = order.compactMap { name -> DatabaseFieldDescriptor? in
            guard let state = states[name] else { return nil }
            return DatabaseFieldDescriptor(
                path: DatabaseFieldPath(name),
                displayName: name,
                typeName: state.typeName,
                isNullable: state.nullable || state.occurrences < records.count,
                isSortable: true,
                isFilterable: true)
        }
        return (fields, truncated)
    }

    private static func validateNativeFilter(_ value: DatabaseValue) throws {
        guard case let .object(fields) = value else {
            throw invalidQuery
        }
        try validateNativeObject(fields, depth: 0)
    }

    private static func validateNativeObject(
        _ fields: [DatabaseObjectField],
        depth: Int
    ) throws {
        guard depth <= MongoDBDatabaseValueCodec.maximumQueryDepth,
            !fields.isEmpty,
            fields.count <= 256
        else {
            throw invalidQuery
        }
        let operatorCount = fields.count(where: { $0.name.hasPrefix("$") })
        guard operatorCount == 0 || operatorCount == fields.count else {
            throw invalidQuery
        }
        var seen = Set<String>()
        for field in fields {
            guard seen.insert(field.name).inserted else {
                throw invalidQuery
            }
            if field.name.hasPrefix("$") {
                try validateNativeOperator(field, depth: depth)
            } else {
                try validateNativeFieldName(field.name)
                try validateNativeFieldValue(field.value, depth: depth + 1)
            }
        }
    }

    private static func validateNativeOperator(
        _ field: DatabaseObjectField,
        depth: Int
    ) throws {
        switch field.name {
        case "$and", "$or", "$nor":
            guard case let .array(values) = field.value,
                !values.isEmpty,
                values.count <= 256
            else {
                throw invalidQuery
            }
            for value in values {
                guard case let .object(fields) = value else {
                    throw invalidQuery
                }
                try validateNativeObject(fields, depth: depth + 1)
            }
        case "$eq", "$ne", "$gt", "$gte", "$lt", "$lte":
            try validateNativeLiteral(field.value, depth: depth + 1)
        case "$in", "$nin", "$all":
            guard case let .array(values) = field.value,
                !values.isEmpty,
                values.count <= 256
            else {
                throw invalidQuery
            }
            for value in values {
                try validateNativeLiteral(value, depth: depth + 1)
            }
        case "$exists":
            guard case .boolean = field.value else {
                throw invalidQuery
            }
        case "$size":
            switch field.value {
            case let .signedInteger(value):
                guard value >= 0, value <= 1_000_000 else { throw invalidQuery }
            case let .unsignedInteger(value):
                guard value <= 1_000_000 else { throw invalidQuery }
            default:
                throw invalidQuery
            }
        case "$not", "$elemMatch":
            guard case let .object(fields) = field.value else {
                throw invalidQuery
            }
            try validateNativeObject(fields, depth: depth + 1)
        default:
            throw invalidQuery
        }
    }

    private static func validateNativeFieldValue(
        _ value: DatabaseValue,
        depth: Int
    ) throws {
        if case let .object(fields) = value {
            try validateNativeObject(fields, depth: depth)
        } else {
            try validateNativeLiteral(value, depth: depth)
        }
    }

    private static func validateNativeLiteral(
        _ value: DatabaseValue,
        depth: Int
    ) throws {
        guard depth <= MongoDBDatabaseValueCodec.maximumQueryDepth else {
            throw invalidQuery
        }
        switch value {
        case .missing, .date, .time, .decimal:
            throw invalidQuery
        case let .array(values):
            guard values.count <= 256 else { throw invalidQuery }
            for value in values {
                try validateNativeLiteral(value, depth: depth + 1)
            }
        case let .object(fields):
            try validateNativeObject(fields, depth: depth + 1)
        case .null, .boolean, .signedInteger, .unsignedInteger, .floatingPoint,
            .string, .binary, .timestamp, .uuid, .productSpecific:
            return
        }
    }

    private static func validateNativeFieldName(_ name: String) throws {
        guard name.utf8.count <= 1_024,
            !name.contains("\0"),
            !name.hasPrefix("$"),
            !name.split(separator: ".", omittingEmptySubsequences: false).contains(where: {
                $0.isEmpty || $0.hasPrefix("$")
            })
        else {
            throw invalidQuery
        }
    }

    private static func fieldPath(_ path: DatabaseFieldPath) throws -> String {
        guard !path.segments.isEmpty,
            path.segments.count <= 32,
            path.segments.allSatisfy({ validFieldSegment($0) })
        else {
            throw invalidRead
        }
        let value = path.segments.joined(separator: ".")
        guard value.utf8.count <= 1_024 else {
            throw invalidRead
        }
        return value
    }

    private static func validateConsistency(
        _ consistency: DatabaseConsistencyPreference,
        failure: DatabaseAdapterFailure
    ) throws(DatabaseAdapterFailure) {
        switch consistency {
        case .productDefault, .bestEffort, .eventual:
            return
        case .session, .snapshot, .strong:
            throw failure
        }
    }

    private static func validHost(_ host: String) -> Bool {
        MongoDBDatabaseTransport.validHost(host)
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.contains("\0")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
            && !value.contains("/")
    }

    private static func optionalName(
        _ value: String?
    ) throws(DatabaseAdapterFailure) -> String? {
        guard let value else { return nil }
        guard validName(value) else { throw invalidConnection }
        return value
    }

    private static func validCredentialText(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 16_384
            && !value.contains("\0")
    }

    private static func validSCRAMPassword(_ value: String) -> Bool {
        validCredentialText(value)
            && value.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }
    }

    private static func validFieldSegment(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 255
            && !value.hasPrefix("$")
            && !value.contains(".")
            && !value.contains("\0")
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
