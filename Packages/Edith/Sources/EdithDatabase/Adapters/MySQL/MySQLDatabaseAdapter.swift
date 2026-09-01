import Foundation

struct MySQLDatabaseAdapter: DatabaseAdapter {
    let id: DatabaseAdapterID = "mysql"
    let products: Set<DatabaseProduct> = [.mysql, .mariaDB]
    private let connector: MySQLDatabaseClientConnector

    init(
        connector: @escaping MySQLDatabaseClientConnector = { plan in
            try await MySQLNIODatabaseClient.connect(plan)
        }
    ) {
        self.connector = connector
    }

    func connect(
        _ connection: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await MySQLDatabaseAdapterSupport.check(context)
        let plan = try MySQLDatabaseAdapterSupport.connectionPlan(
            connection,
            context: context)
        let established = try await MySQLDatabaseAdapterSupport.establish(
            plan: plan,
            connector: connector,
            context: context)
        return MySQLDatabaseAdapterSession(
            connection: connection.definition,
            productIdentity: established.identity,
            client: established.client)
    }
}

actor MySQLDatabaseAdapterSession: DatabaseAdapterSession {
    nonisolated let id = DatabaseAdapterSessionID()
    nonisolated let connection: DatabaseConnectionDefinition
    nonisolated let productIdentity: DatabaseProductIdentity

    private var client: (any MySQLDatabaseClient)?
    private var state: DatabaseAdapterSessionState = .connected
    private var activeOperation: MySQLDatabaseAdapterActiveOperation?

    init(
        connection: DatabaseConnectionDefinition,
        productIdentity: DatabaseProductIdentity,
        client: any MySQLDatabaseClient
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
            fallback: MySQLDatabaseAdapterSupport.connectionFailed
        ) { client in
            try await client.discoverIdentity()
        }
        guard
            MySQLDatabaseStableIdentity(identity)
                == MySQLDatabaseStableIdentity(productIdentity)
        else {
            await failAndClose()
            throw MySQLDatabaseAdapterSupport.connectionFailed
        }
        try await MySQLDatabaseAdapterSupport.check(context)
        let report = MySQLDatabaseAdapterSupport.capabilityReport(
            identity: productIdentity,
            connection: connection)
        try DatabaseAdapterBounds.validate(report: report, identity: productIdentity)
        return report
    }

    func readPage(
        _ request: DatabaseAdapterPageRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        return try await perform(
            context: context,
            fallback: MySQLDatabaseAdapterSupport.readFailed
        ) { [connectionID = connection.id, sessionID = id] client in
            try await MySQLDatabaseReadSupport.readPage(
                request,
                connectionID: connectionID,
                sessionID: sessionID,
                client: client,
                startedAt: startedAt)
        }
    }

    func query(
        _ request: DatabaseAdapterQueryRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let startedAt = Date()
        return try await perform(
            context: context,
            fallback: MySQLDatabaseAdapterSupport.queryFailed
        ) { [connectionID = connection.id] client in
            try await MySQLDatabaseReadSupport.query(
                request,
                connectionID: connectionID,
                client: client,
                startedAt: startedAt)
        }
    }

    func normalizeMutation(
        _ request: DatabaseDestructiveRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        try await requireAvailableContext(context)
        return try MySQLDatabaseMutationSupport.normalize(
            request,
            connectionID: connection.id,
            product: productIdentity.product)
    }

    func executeMutation(
        _ plan: DatabaseDestructivePlan,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        let mutation = try MySQLDatabaseMutationSupport.executionPlan(
            plan,
            connectionID: connection.id,
            product: productIdentity.product)
        let result = try await perform(
            context: context,
            fallback: MySQLDatabaseAdapterSupport.mutationFailed
        ) { client in
            try await client.executeMutation(mutation)
        }
        guard result.affectedRows == 1 else {
            return try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .notApplied,
                affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
                error: DatabaseErrorEnvelope(
                    category: .conflict,
                    message: "The row no longer matched the requested mutation.",
                    productCode: "mysql.mutation.row_not_found"))
        }
        return try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .applied,
            affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact))
    }

    func openStream(
        _ request: DatabaseAdapterStreamRequest,
        context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterRecordStream {
        try await requireAvailableContext(context)
        throw MySQLDatabaseAdapterSupport.capabilityUnavailable
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

    private func connectedClient() throws(DatabaseAdapterFailure) -> any MySQLDatabaseClient {
        guard state == .connected, let client else {
            throw MySQLDatabaseAdapterSupport.disconnected
        }
        return client
    }

    private func requireAvailableContext(
        _ context: DatabaseAdapterOperationContext
    ) async throws(DatabaseAdapterFailure) {
        try await MySQLDatabaseAdapterSupport.check(context)
        _ = try connectedClient()
        try await MySQLDatabaseAdapterSupport.check(context)
    }

    private func perform<Output: Sendable>(
        context: DatabaseAdapterOperationContext,
        fallback: DatabaseAdapterFailure,
        body: @escaping @Sendable (any MySQLDatabaseClient) async throws -> Output
    ) async throws(DatabaseAdapterFailure) -> Output {
        try await MySQLDatabaseAdapterSupport.check(context)
        let client = try connectedClient()
        guard activeOperation == nil else {
            throw MySQLDatabaseAdapterSupport.operationBusy
        }
        activeOperation = MySQLDatabaseAdapterActiveOperation(
            operationID: context.operationID,
            cancellation: context.cancellation)
        let cancellationTask = Task { [weak self] in
            for await _ in await context.cancellation.events() {
                guard !Task.isCancelled else { return }
                await self?.interrupt(operationID: context.operationID)
                return
            }
        }
        let deadlineTask = MySQLDatabaseAdapterSupport.deadlineTask(context: context)
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
            try await MySQLDatabaseAdapterSupport.check(context)
            return output
        } catch {
            switch await context.cancellation.reason() {
            case .deadlineExceeded:
                await interrupt(operationID: context.operationID)
                throw MySQLDatabaseAdapterSupport.deadlineExceeded
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
            if let driverFailure = error as? MySQLDatabaseDriverFailure {
                if case .connection = driverFailure {
                    await failAndClose()
                } else if case .resourceLimit = driverFailure {
                    await failAndClose()
                }
                throw MySQLDatabaseAdapterSupport.map(driverFailure, fallback: fallback)
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

private struct MySQLDatabaseAdapterActiveOperation: Sendable {
    let operationID: DatabaseOperationID
    let cancellation: DatabaseAdapterCancellationSignal
}

struct MySQLDatabaseEstablishedClient: Sendable {
    let client: any MySQLDatabaseClient
    let identity: DatabaseProductIdentity
}

private struct MySQLDatabaseStableIdentity: Equatable {
    let product: DatabaseProduct
    let version: DatabaseVersion?
    let distribution: String?
    let serverIdentifier: String?
    let topology: DatabaseTopologyKind
    let topologyAttributes: [DatabaseStringAttribute]

    init(_ identity: DatabaseProductIdentity) {
        product = identity.product
        version = identity.version
        distribution = identity.distribution
        serverIdentifier = identity.serverIdentifier
        topology = identity.topology.kind
        topologyAttributes = identity.topology.attributes
            .filter {
                ["database", "hostName", "protocolVersion", "versionComment"].contains($0.name)
            }
            .sorted {
                if $0.name == $1.name {
                    return $0.value < $1.value
                }
                return $0.name < $1.name
            }
    }
}

enum MySQLDatabaseAdapterSupport {
    static let connectionFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The MySQL server could not be reached.",
            productCode: "mysql.connection.failed",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let authenticationFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .authenticationFailed,
            message: "MySQL authentication failed.",
            productCode: "mysql.authentication.failed",
            retry: DatabaseRetryGuidance(action: .reauthenticate)))

    static let disconnected = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The MySQL session is disconnected.",
            productCode: "mysql.session.disconnected",
            retry: DatabaseRetryGuidance(action: .reconnect)))

    static let invalidConnection = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MySQL connection configuration is invalid.",
            productCode: "mysql.connection.invalid"))

    static let deadlineExceeded = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .timeout,
            message: "The MySQL operation deadline was exceeded.",
            productCode: "mysql.deadline_exceeded",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let capabilityUnavailable = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .unsupported,
            message: "This MySQL capability is not available yet.",
            productCode: "mysql.capability.unavailable"))

    static let invalidRequest = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MySQL request is invalid.",
            productCode: "mysql.request.invalid"))

    static let invalidTarget = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MySQL object target is invalid.",
            productCode: "mysql.target.invalid"))

    static let invalidContinuation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MySQL continuation is invalid or stale.",
            productCode: "mysql.continuation.invalid"))

    static let readFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "MySQL could not browse the requested data.",
            productCode: "mysql.browse.failed",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let queryFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "MySQL could not complete the query.",
            productCode: "mysql.query.failed",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let invalidMutation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The MySQL row mutation is invalid.",
            productCode: "mysql.mutation.invalid"))

    static let mutationFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "MySQL could not apply the row mutation.",
            productCode: "mysql.mutation.failed",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let readOnlyViolation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .readOnlyViolation,
            message: "Only one read-only MySQL statement is allowed.",
            productCode: "mysql.query.read_only"))

    static let operationBusy = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .conflict,
            message: "The MySQL session already has an active operation.",
            productCode: "mysql.operation.busy",
            retry: DatabaseRetryGuidance(action: .retry)))

    static let tlsFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .connectionFailed,
            message: "The MySQL TLS policy could not be satisfied.",
            productCode: "mysql.tls.failed",
            retry: DatabaseRetryGuidance(action: .userDecision)))

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
        plan: MySQLDatabaseConnectionPlan,
        connector: @escaping MySQLDatabaseClientConnector,
        context: DatabaseAdapterConnectionContext
    ) async throws(DatabaseAdapterFailure) -> MySQLDatabaseEstablishedClient {
        let establishmentTask = Task {
            let client = try await connector(plan)
            do {
                let identity = try await client.discoverIdentity()
                guard identity.product == plan.product else {
                    throw connectionFailed
                }
                return MySQLDatabaseEstablishedClient(client: client, identity: identity)
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
            if let driverFailure = error as? MySQLDatabaseDriverFailure {
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
                let nanoseconds = UInt64(min(delay * 1_000_000_000, Double(UInt64.max)))
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await context.cancellation.cancel(.deadlineExceeded)
            }
        }
    }

    static func connectionPlan(
        _ resolved: DatabaseResolvedConnection,
        context: DatabaseAdapterConnectionContext
    ) throws(DatabaseAdapterFailure) -> MySQLDatabaseConnectionPlan {
        let definition = resolved.definition
        guard definition.version == DatabaseConnectionDefinition.schemaVersion,
            definition.productHint == .mysql || definition.productHint == .mariaDB,
            definition.tunnel == nil,
            definition.options.isEmpty,
            definition.namespaces.logicalDatabase == nil,
            definition.tls.certificateAuthority == nil,
            definition.tls.clientCertificate == nil,
            definition.tls.clientPrivateKey == nil
        else {
            throw invalidConnection
        }
        guard
            [.automatic, .standalone, .primaryReplica, .cluster].contains(
                definition.deploymentMode),
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
        let password = try password(
            authentication: definition.authentication,
            username: username,
            resolvedSecrets: resolved.secrets)
        let tls = try tlsPlan(definition.tls)
        let connectTimeout = try effectiveConnectTimeout(
            configured: definition.limits.connectionTimeout.milliseconds,
            deadline: context.deadline)
        return MySQLDatabaseConnectionPlan(
            product: definition.productHint,
            host: endpoint.host,
            port: endpoint.port.value,
            username: username,
            password: password,
            database: database,
            tls: tls,
            tlsServerName: definition.tls.serverName,
            connectTimeoutMilliseconds: connectTimeout)
    }

    static func capabilityReport(
        identity: DatabaseProductIdentity,
        connection: DatabaseConnectionDefinition
    ) -> DatabaseCapabilityReport {
        let pendingReason = DatabaseCapabilityUnavailableReason(
            category: .notImplemented,
            message: "This capability is pending an adapter extension.")
        let available: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.connectionTest, .sharedRequired),
            (.objectDiscovery, .sharedRequired),
            (.objectDescription, .sharedRequired),
            (.query, .familyRequired),
            (.queryCancellation, .sharedRequired),
            (.browse, .sharedRequired),
        ]
        let serverReadOnly =
            identity.topology.attributes.contains(where: {
                ($0.name == "readOnly" || $0.name == "superReadOnly") && $0.value == "true"
            })
        let policyAllowsMutations =
            connection.readOnlyPolicy != .required
            && connection.environment.protection != .readOnly
            && connection.productionPolicy != .prohibitMutations
        let mutationsAvailable = policyAllowsMutations && !serverReadOnly
        let mutationReason: DatabaseCapabilityUnavailableReason? =
            if !policyAllowsMutations {
                DatabaseCapabilityUnavailableReason(
                    category: .connectionPolicy,
                    message: "This connection policy does not allow data mutations.")
            } else if serverReadOnly {
                DatabaseCapabilityUnavailableReason(
                    category: .topology,
                    message: "The connected server reports read-only mode.")
            } else {
                nil
            }
        let mutations = [DatabaseCapabilityID.insert, .update, .delete].map { identifier in
            DatabaseCapabilityStatus(
                id: identifier,
                requirement: .sharedRequired,
                availability: mutationsAvailable ? .available : .unavailable,
                reason: mutationReason)
        }
        let pending: [(DatabaseCapabilityID, DatabaseCapabilityRequirement)] = [
            (.explain, .familyRequired),
            (.bulkMutation, .sharedRequired),
            (.importData, .sharedRequired),
            (.exportData, .sharedRequired),
            (.transactions, .familyRequired),
            (.schemaMutation, .familyRequired),
            (.monitoring, .productRequired),
            (.administration, .productRequired),
        ]
        let statuses =
            available.map { identifier, requirement in
                DatabaseCapabilityStatus(
                    id: identifier,
                    requirement: requirement,
                    availability: .available)
            }
            + mutations
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
            pagingModes: [.keyset],
            mutationModes: mutationsAvailable ? [.singleRecord] : [],
            transactionModes: mutationsAvailable ? [.implicit] : [],
            cancellationModes: [.cooperative],
            safetyLimitations: serverReadOnly
                ? ["The connected server reports read-only mode."] : [],
            discoveredAt: Date())
    }

    static func map(
        _ failure: MySQLDatabaseDriverFailure,
        fallback: DatabaseAdapterFailure
    ) -> DatabaseAdapterFailure {
        switch failure {
        case .authentication:
            return authenticationFailed
        case .configuration:
            return invalidConnection
        case .connection:
            return connectionFailed
        case let .incompatibleProduct(product):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .unsupported,
                    message: "The endpoint is not a MySQL server.",
                    productCode: "mysql.product." + product.rawValue,
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case .invalidRequest:
            return invalidMutation
        case let .permission(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .permissionDenied,
                    message: "MySQL denied the requested operation.",
                    productCode: code.map { "mysql.error." + $0 },
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case .resourceLimit:
            return .reported(
                DatabaseErrorEnvelope(
                    category: .resourceLimit,
                    message: "The MySQL response exceeded the safe limit.",
                    productCode: "mysql.response.limit",
                    retry: DatabaseRetryGuidance(action: .userDecision)))
        case let .server(code):
            return .reported(
                DatabaseErrorEnvelope(
                    category: .server,
                    message: "MySQL could not complete the requested operation.",
                    productCode: code.map { "mysql.error." + $0 },
                    retry: DatabaseRetryGuidance(action: .retry)))
        case .timeout:
            return deadlineExceeded
        case .tls:
            return tlsFailed
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
        case .password, .usernameAndPassword:
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
        case .token, .apiKey, .scram, .x509, .cloudIdentity:
            throw invalidConnection
        }
    }

    private static func tlsPlan(
        _ tls: DatabaseTLSConfiguration
    ) throws(DatabaseAdapterFailure) -> MySQLDatabaseTLSPlan {
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
        case (_, .certificateAuthority), (.disabled, .full):
            throw invalidConnection
        }
    }

    private static func databaseName(
        _ namespaces: DatabaseNamespaceDefaults
    ) throws(DatabaseAdapterFailure) -> String? {
        var values: [String] = []
        if let catalog = try optionalName(namespaces.catalog) {
            values.append(catalog)
        }
        if let schema = try optionalName(namespaces.schema) {
            values.append(schema)
        }
        if let database = try optionalName(namespaces.database) {
            values.append(database)
        }
        guard Set(values).count <= 1 else {
            throw invalidConnection
        }
        return values.first
    }

    private static func optionalName(
        _ value: String?
    ) throws(DatabaseAdapterFailure) -> String? {
        guard let value else { return nil }
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
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
