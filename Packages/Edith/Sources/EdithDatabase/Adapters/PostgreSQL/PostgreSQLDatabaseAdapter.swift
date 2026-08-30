import Foundation

struct PostgreSQLDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "postgresql"
    let products: Set<DatabaseProduct> = [.postgresql]
    private let connector: PostgreSQLDatabaseClientConnector

    init(
        connector: @escaping PostgreSQLDatabaseClientConnector = { plan in
            try await PostgresNIODatabaseClient.connect(plan)
        }
    ) {
        self.connector = connector
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await PostgreSQLDatabaseAdapterSupport.check(context)
        let plan = try PostgreSQLDatabaseAdapterSupport.connectionPlan(
            connection,
            context: context)
        let established = try await PostgreSQLDatabaseAdapterSupport.establish(
            plan: plan,
            connector: connector,
            context: context)
        return PostgreSQLDatabaseAdapterSession(
            connection: connection.definition,
            productIdentity: established.identity,
            client: established.client)
    }
}

actor PostgreSQLDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any PostgreSQLDatabaseClient)?
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: PostgreSQLDatabaseAdapterActiveOperation?

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any PostgreSQLDatabaseClient
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
            fallback: PostgreSQLDatabaseAdapterSupport.connectionFailed
        ) { client in
            try await client.discoverIdentity()
        }
        guard
            PostgreSQLDatabaseStableIdentity(identity)
                == PostgreSQLDatabaseStableIdentity(productIdentity)
        else {
            await failAndClose()
            throw PostgreSQLDatabaseAdapterSupport.connectionFailed
        }
        try await PostgreSQLDatabaseAdapterSupport.check(context)
        let report = PostgreSQLDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try await requireAvailableContext(context)
        throw PostgreSQLDatabaseAdapterSupport.capabilityUnavailable
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try await requireAvailableContext(context)
        throw PostgreSQLDatabaseAdapterSupport.capabilityUnavailable
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        throw PostgreSQLDatabaseAdapterSupport.capabilityUnavailable
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        try await requireAvailableContext(context)
        throw PostgreSQLDatabaseAdapterSupport.capabilityUnavailable
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw PostgreSQLDatabaseAdapterSupport.capabilityUnavailable
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
        await client?.disconnect()
        state = .disconnected
    }

    func resourceIsOpen() -> Bool {
        client != nil
    }

    private func connectedClient() throws(DatabaseAdapterFailure)
        -> any PostgreSQLDatabaseClient
    {
        guard state == .connected, let client else {
            throw PostgreSQLDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await PostgreSQLDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await PostgreSQLDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body: @escaping @Sendable (any PostgreSQLDatabaseClient) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await PostgreSQLDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw PostgreSQLDatabaseAdapterSupport.operationBusy
        }
        activeOperation = PostgreSQLDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)
        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = PostgreSQLDatabaseAdapterSupport.deadlineTask(
            context: context)
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
            try await PostgreSQLDatabaseAdapterSupport.check(context)
            return output
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded:
                await interrupt(operationID: context.operationID)
                throw PostgreSQLDatabaseAdapterSupport.deadlineExceeded
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
            if let driverFailure = error as? PostgreSQLDatabaseDriverFailure {
                if case .connection = driverFailure {
                    await failAndClose()
                }
                throw PostgreSQLDatabaseAdapterSupport.map(
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
        state = .failed
        await client?.disconnect()
    }
}

private struct PostgreSQLDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

struct PostgreSQLDatabaseEstablishedClient: Sendable {
    let client: any PostgreSQLDatabaseClient
    let identity: DatabaseProductIdentity
}

private struct PostgreSQLDatabaseStableIdentity: Equatable {
    let product: DatabaseProduct
    let version: DatabaseVersion?
    let distribution: String?
    let serverIdentifier: String?
    let topologyAttributes: [DatabaseStringAttribute]

    init(_ identity: DatabaseProductIdentity) {
        product = identity.product
        version = identity.version
        distribution = identity.distribution
        serverIdentifier = identity.serverIdentifier
        topologyAttributes = identity.topology.attributes
            .filter {
                ["database", "serverEncoding", "serverVersionNumber"].contains($0.name)
            }
            .sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
    }
}

enum PostgreSQLDatabaseAdapterSupport {
    static let connectionFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The PostgreSQL server could not be reached.",
            productCode: "postgresql.connection.failed",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let authenticationFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .authenticationFailed,
            message: "PostgreSQL authentication failed.",
            productCode: "postgresql.authentication.failed",
            retry: DatabaseRetryGuidance(action: .reauthenticate)))

    static let disconnected = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The PostgreSQL session is disconnected.",
            productCode: "postgresql.session.disconnected",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let invalidConnection = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The PostgreSQL connection configuration is invalid.",
            productCode: "postgresql.connection.invalid"))

    static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "The PostgreSQL operation deadline was exceeded.",
            productCode: "postgresql.deadline_exceeded",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let capabilityUnavailable = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "This PostgreSQL capability is not available yet.",
            productCode: "postgresql.capability.unavailable"))

    static let operationBusy = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .conflict,
            message: "The PostgreSQL session already has an active operation.",
            productCode: "postgresql.operation.busy",
            retry: DatabaseRetryGuidance(action: .retry)))

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

    static func establish(
        plan: PostgreSQLDatabaseConnectionPlan,
        connector: @escaping PostgreSQLDatabaseClientConnector,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> PostgreSQLDatabaseEstablishedClient {
        let establishmentTask = Task {
            let client = try await connector(plan)
            do {
                let identity = try await client.discoverIdentity()
                guard identity.product == .postgresql else {
                    throw connectionFailed
                }
                return PostgreSQLDatabaseEstablishedClient(
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
            if let driverFailure = error as? PostgreSQLDatabaseDriverFailure {
                throw map(driverFailure, fallback: connectionFailed)
            }
            throw connectionFailed
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

    static func connectionPlan(
        _ resolved: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) throws(DatabaseAdapterFailure) -> PostgreSQLDatabaseConnectionPlan {
        let definition = resolved.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .postgresql,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.namespaces.logicalDatabase == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil
        else {
            throw invalidConnection
        }
        guard [.automatic, .standalone, .primaryReplica].contains(definition.deploymentMode),
            case let .network(endpoints) = definition.location,
            endpoints.count == 1,
            let endpoint = endpoints.first,
            [.primary, .readReplica, .seed, .node].contains(endpoint.role),
            validHost(endpoint.host),
            let username = definition.username,
            validCredential(username)
        else {
            throw invalidConnection
        }
        let database = try databaseName(definition.namespaces)
        _ = try optionalName(definition.namespaces.schema)
        let password = try password(
            authentication: definition.authentication,
            username: username,
            resolvedSecrets: resolved.secrets)
        let tls = try tlsPlan(definition.tls)
        let connectTimeout = try effectiveConnectTimeout(
            configured: definition.limits.connectionTimeout.milliseconds,
            deadline: context.deadline)
        let readOnly =
            definition.readOnlyPolicy != .disabled
            || definition.productionPolicy == .prohibitMutations
        return PostgreSQLDatabaseConnectionPlan(
            host: endpoint.host,
            port: endpoint.port.value,
            username: username,
            password: password,
            database: database,
            tls: tls,
            tlsServerName: definition.tls.serverName,
            connectTimeoutMilliseconds: connectTimeout,
            statementTimeoutMilliseconds: definition.limits.operationTimeout.milliseconds,
            readOnly: readOnly)
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity
    ) -> DatabaseCapabilityReport {
        let pendingReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is pending a PostgreSQL adapter extension.")
        let available = DatabaseCapabilityStatus(
            id: .connectionTest,
            requirement: .sharedRequired,
            availability: .available)
        let pending: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.objectDiscovery, .sharedRequired),
            (.objectDescription, .sharedRequired),
            (.query, .familyRequired),
            (.queryCancellation, .sharedRequired),
            (.explain, .familyRequired),
            (.browse, .sharedRequired),
            (.insert, .sharedRequired),
            (.update, .sharedRequired),
            (.delete, .sharedRequired),
            (.bulkMutation, .sharedRequired),
            (.importData, .sharedRequired),
            (.exportData, .sharedRequired),
            (.transactions, .familyRequired),
            (.schemaMutation, .familyRequired),
            (.monitoring, .productRequired),
            (.administration, .productRequired),
        ].map { identifier, requirement in
            (identifier, requirement)
        }
        let statuses =
            [available]
            + pending.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .planned,
                    reason: pendingReason)
            }
        return DatabaseCapabilityReport(
            productIdentity: identity,
            capabilities: statuses,
            discoveredAt: Date())
    }

    static func map(
        _ failure: PostgreSQLDatabaseDriverFailure,
        fallback: DatabaseAdapterFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication:
            return authenticationFailed
        case .connection:
            return connectionFailed
        case let .permission(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .permissionDenied,
                    message: "PostgreSQL denied the requested operation.",
                    productCode: code.map { "postgresql.sqlstate.\($0)" },
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case .timeout:
            return deadlineExceeded
        case let .server(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .server,
                    message: "PostgreSQL could not complete the requested operation.",
                    productCode: code.map { "postgresql.sqlstate.\($0)" },
                    retry: DatabaseRetryGuidance(action: .retry)))
        }
    }

    private static func password(
        authentication: DatabaseAuthentication,
        username: String,
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
        case .password, .usernameAndPassword, .scram:
            guard authentication.source == nil,
                authentication.secretReferences.count == 1,
                let reference = authentication.secretReferences.first,
                reference.purpose == .password,
                resolvedSecrets.count == 1,
                let passwordData = resolvedSecrets[reference],
                let password = String(data: passwordData, encoding: .utf8),
                validCredential(password),
                validCredential(username)
            else {
                throw invalidConnection
            }
            return password
        case .token, .apiKey, .x509, .cloudIdentity:
            throw invalidConnection
        }
    }

    private static func tlsPlan(
        _ tls: DatabaseTLSConfiguration
    ) throws(DatabaseAdapterFailure) -> PostgreSQLDatabaseTLSPlan {
        if let serverName = tls.serverName, !validHost(serverName) {
            throw invalidConnection
        }
        switch (tls.mode, tls.verification) {
        case (.disabled, .none):
            guard tls.serverName == nil else { throw invalidConnection }
            return .disabled
        case (.preferred, .none):
            return .preferred(verifyCertificate: false)
        case (.preferred, .full):
            return .preferred(verifyCertificate: true)
        case (.required, .none):
            return .required(verifyCertificate: false)
        case (.required, .full):
            return .required(verifyCertificate: true)
        case (_, .certificateAuthority):
            throw invalidConnection
        case (.disabled, .full):
            throw invalidConnection
        }
    }

    private static func databaseName(
        _ namespaces: DatabaseNamespaceDefaults
    ) throws(DatabaseAdapterFailure) -> String? {
        let catalog = try optionalName(namespaces.catalog)
        let database = try optionalName(namespaces.database)
        guard catalog == nil || database == nil || catalog == database else {
            throw invalidConnection
        }
        return database ?? catalog
    }

    private static func optionalName(
        _ value: String?
    ) throws(DatabaseAdapterFailure) -> String? {
        guard let value else { return nil }
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw invalidConnection
        }
        return value
    }

    private static func effectiveConnectTimeout(
        configured: UInt64,
        deadline: Date?
    ) throws(DatabaseAdapterFailure) -> UInt64 {
        guard let deadline else { return configured }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining.isFinite, remaining > 0 else {
            throw deadlineExceeded
        }
        let remainingMilliseconds = UInt64(max(1, floor(remaining * 1_000)))
        return min(configured, remainingMilliseconds)
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
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
            )
    }
}
