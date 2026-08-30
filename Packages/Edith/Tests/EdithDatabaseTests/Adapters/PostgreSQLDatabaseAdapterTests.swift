import Foundation
import Testing

@testable import EdithDatabase

private enum PostgreSQLDatabaseAdapterFixtures {
    static let identity = DatabaseProductIdentity(
        product: .postgresql,
        version: DatabaseVersion(string: "17.11", major: 17, minor: 11),
        distribution: "PostgreSQL",
        topology: DatabaseTopology(
            kind: .standalone,
            localRole: "primary",
            nodeCount: 1,
            attributes: [
                DatabaseStringAttribute(name: "database", value: "edith_lab"),
                DatabaseStringAttribute(name: "serverEncoding", value: "UTF8"),
                DatabaseStringAttribute(name: "serverVersionNumber", value: "170011"),
            ]))

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        product: DatabaseProduct = .postgresql,
        endpoints: [DatabaseNetworkEndpoint]? = nil,
        username: String? = "edith_admin",
        namespaces: DatabaseNamespaceDefaults = DatabaseNamespaceDefaults(
            catalog: "edith_lab",
            schema: "public",
            database: "edith_lab"),
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tunnel: DatabaseTunnelDefinition? = nil,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .required,
        productionPolicy: DatabaseProductionPolicy = .prohibitMutations,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        let effectiveEndpoints =
            try endpoints ?? [
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: DatabasePort(55_432),
                    role: .primary)
            ]
        return DatabaseConnectionDefinition(
            id: id,
            displayName: "PostgreSQL fixture",
            productHint: product,
            location: .network(effectiveEndpoints),
            username: username,
            namespaces: namespaces,
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            tunnel: tunnel,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 3_000),
                poolSize: try DatabasePoolSize(2)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: .readOnly),
            options: options,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func resolved(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:]
    ) throws(DatabaseAdapterFailure) -> DatabaseResolvedConnection {
        try DatabaseResolvedConnection(definition: definition, secrets: secrets)
    }

    static func context(
        operationID: DatabaseOperationID = DatabaseOperationID(),
        deadline: Date? = nil,
        cancellation: DatabaseAdapterCancellationSignal = DatabaseAdapterCancellationSignal()
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(
                operationID: operationID,
                deadline: deadline),
            cancellation: cancellation)
    }

    static func passwordConnection(
        password: String = "fixture-password",
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .preferred,
            verification: .none,
            serverName: "database.example.test")
    ) throws -> (DatabaseResolvedConnection, DatabaseSecretReference) {
        let reference = DatabaseSecretReference(
            identifier: UUID(uuidString: "8B204AA0-F87D-49A1-A72C-4D31DBF16889")!,
            purpose: .password)
        let definition = try definition(
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [reference]),
            tls: tls)
        return (
            try resolved(definition, secrets: [reference: Data(password.utf8)]),
            reference
        )
    }

    static func target(connectionID: DatabaseConnectionID) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(
                kind: .table,
                path: ["public", "orders"]))
    }
}

private actor PostgreSQLDatabaseAdapterTestClient: PostgreSQLDatabaseClient {
    private var identities: [DatabaseProductIdentity]
    private var delaysNanoseconds: [UInt64]
    private let cancellation: DatabaseAdapterCancellationSignal?
    private let cancellationReason: DatabaseAdapterCancellationReason
    private let cancellationDiscoveryCount: Int?
    private var discoveryCount = 0
    private var disconnectCount = 0

    init(
        identities: [DatabaseProductIdentity] = [PostgreSQLDatabaseAdapterFixtures.identity],
        delaysNanoseconds: [UInt64] = [],
        cancellation: DatabaseAdapterCancellationSignal? = nil,
        cancellationReason: DatabaseAdapterCancellationReason = .userRequested,
        cancellationDiscoveryCount: Int? = nil
    ) {
        self.identities = identities
        self.delaysNanoseconds = delaysNanoseconds
        self.cancellation = cancellation
        self.cancellationReason = cancellationReason
        self.cancellationDiscoveryCount = cancellationDiscoveryCount
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        discoveryCount += 1
        guard !identities.isEmpty else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        let delay: UInt64
        if delaysNanoseconds.isEmpty {
            delay = 0
        } else if delaysNanoseconds.count == 1 {
            delay = delaysNanoseconds[0]
        } else {
            delay = delaysNanoseconds.removeFirst()
        }
        if delay > 0 {
            var remaining = delay
            while remaining > 0 {
                if disconnectCount > 0 {
                    throw PostgreSQLDatabaseDriverFailure.connection
                }
                let interval = min(remaining, 10_000_000)
                try await Task.sleep(nanoseconds: interval)
                remaining -= interval
            }
        }
        if discoveryCount == cancellationDiscoveryCount {
            await cancellation?.cancel(cancellationReason)
        }
        if identities.count == 1 {
            return identities[0]
        }
        return identities.removeFirst()
    }

    func disconnect() {
        disconnectCount += 1
    }

    func disconnects() -> Int {
        disconnectCount
    }

    func discoveries() -> Int {
        discoveryCount
    }
}

private actor PostgreSQLDatabaseAdapterConnectorCapture {
    private var plans: [PostgreSQLDatabaseConnectionPlan] = []

    func record(_ plan: PostgreSQLDatabaseConnectionPlan) {
        plans.append(plan)
    }

    func latest() -> PostgreSQLDatabaseConnectionPlan? {
        plans.last
    }
}

private func postgresqlAdapterWaitForDiscoveries(
    _ count: Int,
    client: PostgreSQLDatabaseAdapterTestClient
) async -> Bool {
    let deadline = Date().addingTimeInterval(1)
    while Date() < deadline {
        if await client.discoveries() >= count {
            return true
        }
        try? await Task.sleep(nanoseconds: 1_000_000)
    }
    return await client.discoveries() >= count
}

@Test func postgresqlAdapterBuildsTypedBoundedConnectionPlan() async throws {
    let (resolved, _) = try PostgreSQLDatabaseAdapterFixtures.passwordConnection()
    let plan = try PostgreSQLDatabaseAdapterSupport.connectionPlan(
        resolved,
        context: PostgreSQLDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(10)))
    #expect(plan.host == "127.0.0.1")
    #expect(plan.port == 55_432)
    #expect(plan.username == "edith_admin")
    #expect(plan.password == "fixture-password")
    #expect(plan.database == "edith_lab")
    #expect(plan.tlsServerName == "database.example.test")
    #expect(plan.connectTimeoutMilliseconds == 2_000)
    #expect(plan.statementTimeoutMilliseconds == 3_000)
    #expect(plan.readOnly)
    guard case let .preferred(verifyCertificate) = plan.tls else {
        Issue.record("expected preferred TLS")
        return
    }
    #expect(!verifyCertificate)
}

@Test func postgresqlAdapterRejectsAmbiguousOrUnsupportedConnections() throws {
    let endpoint = DatabaseNetworkEndpoint(
        host: "127.0.0.1",
        port: try DatabasePort(55_432),
        role: .primary)
    let multipleEndpoints = try PostgreSQLDatabaseAdapterFixtures.definition(
        endpoints: [endpoint, endpoint])
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try PostgreSQLDatabaseAdapterSupport.connectionPlan(
            PostgreSQLDatabaseAdapterFixtures.resolved(multipleEndpoints),
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }

    let mismatchedNamespaces = try PostgreSQLDatabaseAdapterFixtures.definition(
        namespaces: DatabaseNamespaceDefaults(
            catalog: "first",
            database: "second"))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try PostgreSQLDatabaseAdapterSupport.connectionPlan(
            PostgreSQLDatabaseAdapterFixtures.resolved(mismatchedNamespaces),
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }

    let certificate = DatabaseResourceReference(
        identifier: UUID(uuidString: "7D86B64C-9105-454E-A3CB-052B5340121E")!,
        kind: .certificateAuthority)
    let customAuthority = try PostgreSQLDatabaseAdapterFixtures.definition(
        tls: DatabaseTLSConfiguration(
            mode: .required,
            verification: .full,
            certificateAuthority: certificate))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try PostgreSQLDatabaseAdapterSupport.connectionPlan(
            PostgreSQLDatabaseAdapterFixtures.resolved(customAuthority),
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }
}

@Test func postgresqlAdapterHonorsCancellationAndDeadlineBeforeConnecting() async throws {
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let resolved = try PostgreSQLDatabaseAdapterFixtures.resolved(definition)
    let cancellation = DatabaseAdapterCancellationSignal()
    await cancellation.cancel(.userRequested)
    let adapter = PostgreSQLDatabaseAdapter { _ in
        Issue.record("connector must not run after cancellation")
        return PostgreSQLDatabaseAdapterTestClient()
    }
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await adapter.connect(
            resolved,
            context: PostgreSQLDatabaseAdapterFixtures.context(cancellation: cancellation))
    }
    await #expect(throws: DatabaseAdapterFailure.self) {
        _ = try await adapter.connect(
            resolved,
            context: PostgreSQLDatabaseAdapterFixtures.context(
                deadline: Date(timeIntervalSince1970: 1)))
    }
}

@Test func postgresqlAdapterEnforcesDeadlineDuringConnectionIdentity() async throws {
    let client = PostgreSQLDatabaseAdapterTestClient(
        delaysNanoseconds: [5_000_000_000])
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let startedAt = Date()
    await #expect(throws: PostgreSQLDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await adapter.connect(
            PostgreSQLDatabaseAdapterFixtures.resolved(definition),
            context: PostgreSQLDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(0.05)))
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterMapsDeadlineAfterConnectionIdentityReturns() async throws {
    let cancellation = DatabaseAdapterCancellationSignal()
    let client = PostgreSQLDatabaseAdapterTestClient(
        cancellation: cancellation,
        cancellationReason: .deadlineExceeded,
        cancellationDiscoveryCount: 1)
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    await #expect(throws: PostgreSQLDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await adapter.connect(
            PostgreSQLDatabaseAdapterFixtures.resolved(definition),
            context: PostgreSQLDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(10),
                cancellation: cancellation))
    }
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterConnectsDiscoversCapabilitiesAndDisconnects() async throws {
    let client = PostgreSQLDatabaseAdapterTestClient()
    let capture = PostgreSQLDatabaseAdapterConnectorCapture()
    let adapter = PostgreSQLDatabaseAdapter { plan in
        await capture.record(plan)
        return client
    }
    let (resolved, _) = try PostgreSQLDatabaseAdapterFixtures.passwordConnection()
    let session = try await adapter.connect(
        resolved,
        context: PostgreSQLDatabaseAdapterFixtures.context())
    #expect(await capture.latest()?.database == "edith_lab")
    #expect(await session.lifecycleState() == .connected)
    let report = try await session.discoverCapabilities(
        context: PostgreSQLDatabaseAdapterFixtures.context())
    #expect(report.productIdentity == PostgreSQLDatabaseAdapterFixtures.identity)
    #expect(report.supports(.connectionTest))
    #expect(report.status(for: .browse)?.availability == .planned)
    #expect(report.status(for: .query)?.availability == .planned)
    let cancellation = await session.cancel(DatabaseOperationID())
    #expect(cancellation.support == .cooperative)
    #expect(cancellation.disposition == .alreadyFinished)
    let request = try DatabaseAdapterPageRequest(
        target: PostgreSQLDatabaseAdapterFixtures.target(
            connectionID: resolved.definition.id),
        page: DatabasePageRequest(pageSize: try DatabasePageSize(2)),
        continuation: nil)
    await #expect(throws: DatabaseAdapterFailure.self) {
        _ = try await session.readPage(
            request,
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }
    await session.disconnect()
    #expect(await session.lifecycleState() == .disconnected)
    #expect(await client.disconnects() == 1)
    let concrete = try #require(session as? PostgreSQLDatabaseAdapterSession)
    #expect(await !concrete.resourceIsOpen())
}

@Test func postgresqlAdapterRejectsIdentityDriftAndClosesTheClient() async throws {
    let drifted = DatabaseProductIdentity(
        product: .postgresql,
        version: DatabaseVersion(string: "17.12", major: 17, minor: 12),
        distribution: "PostgreSQL",
        topology: DatabaseTopology(kind: .standalone))
    let client = PostgreSQLDatabaseAdapterTestClient(
        identities: [PostgreSQLDatabaseAdapterFixtures.identity, drifted])
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let session = try await adapter.connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(definition),
        context: PostgreSQLDatabaseAdapterFixtures.context())
    await #expect(throws: DatabaseAdapterFailure.self) {
        _ = try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterEnforcesDeadlineDuringCapabilityDiscovery() async throws {
    let client = PostgreSQLDatabaseAdapterTestClient(
        identities: [
            PostgreSQLDatabaseAdapterFixtures.identity,
            PostgreSQLDatabaseAdapterFixtures.identity,
        ],
        delaysNanoseconds: [0, 5_000_000_000])
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let session = try await adapter.connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(definition),
        context: PostgreSQLDatabaseAdapterFixtures.context())
    let startedAt = Date()
    await #expect(throws: PostgreSQLDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(0.05)))
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterCancelsActiveCapabilityDiscovery() async throws {
    let operationID = DatabaseOperationID()
    let cancellation = DatabaseAdapterCancellationSignal()
    let client = PostgreSQLDatabaseAdapterTestClient(
        identities: [
            PostgreSQLDatabaseAdapterFixtures.identity,
            PostgreSQLDatabaseAdapterFixtures.identity,
        ],
        delaysNanoseconds: [0, 5_000_000_000])
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let session = try await adapter.connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(definition),
        context: PostgreSQLDatabaseAdapterFixtures.context())
    let discovery = Task {
        try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context(
                operationID: operationID,
                cancellation: cancellation))
    }
    guard await postgresqlAdapterWaitForDiscoveries(2, client: client) else {
        discovery.cancel()
        _ = try? await discovery.value
        Issue.record("capability discovery did not start")
        return
    }
    let startedAt = Date()
    let result = await session.cancel(operationID)
    #expect(result.disposition == .accepted)
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await discovery.value
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterTaskCancellationClosesActiveClient() async throws {
    let client = PostgreSQLDatabaseAdapterTestClient(
        identities: [
            PostgreSQLDatabaseAdapterFixtures.identity,
            PostgreSQLDatabaseAdapterFixtures.identity,
        ],
        delaysNanoseconds: [0, 5_000_000_000])
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let session = try await adapter.connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(definition),
        context: PostgreSQLDatabaseAdapterFixtures.context())
    let discovery = Task {
        try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context())
    }
    guard await postgresqlAdapterWaitForDiscoveries(2, client: client) else {
        discovery.cancel()
        _ = try? await discovery.value
        Issue.record("capability discovery did not start")
        return
    }
    let startedAt = Date()
    discovery.cancel()
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await discovery.value
    }
    #expect(Date().timeIntervalSince(startedAt) < 1)
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
}

@Test func postgresqlAdapterClosesWhenCancellationWinsAfterDriverReturn() async throws {
    let cancellation = DatabaseAdapterCancellationSignal()
    let client = PostgreSQLDatabaseAdapterTestClient(
        identities: [
            PostgreSQLDatabaseAdapterFixtures.identity,
            PostgreSQLDatabaseAdapterFixtures.identity,
        ],
        cancellation: cancellation,
        cancellationDiscoveryCount: 2)
    let adapter = PostgreSQLDatabaseAdapter { _ in client }
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition()
    let session = try await adapter.connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(definition),
        context: PostgreSQLDatabaseAdapterFixtures.context())
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context(
                cancellation: cancellation))
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
}

private enum PostgreSQLDatabaseAdapterLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_POSTGRESQL_HOST",
        "EDITH_DATABASE_POSTGRESQL_PORT",
        "EDITH_DATABASE_POSTGRESQL_DATABASE",
        "EDITH_DATABASE_POSTGRESQL_USERNAME",
        "EDITH_DATABASE_POSTGRESQL_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }
}

@Test(.enabled(if: PostgreSQLDatabaseAdapterLiveEnvironment.isEnabled))
func postgresqlAdapterLiveAuthenticatedCapabilityDiscovery() async throws {
    let environment = PostgreSQLDatabaseAdapterLiveEnvironment.values
    let host = try #require(environment["EDITH_DATABASE_POSTGRESQL_HOST"])
    let portText = try #require(environment["EDITH_DATABASE_POSTGRESQL_PORT"])
    let port = try #require(Int(portText))
    let database = try #require(environment["EDITH_DATABASE_POSTGRESQL_DATABASE"])
    let username = try #require(environment["EDITH_DATABASE_POSTGRESQL_USERNAME"])
    let password = try #require(environment["EDITH_DATABASE_POSTGRESQL_PASSWORD"])
    let reference = DatabaseSecretReference(
        identifier: UUID(uuidString: "5379DA6C-4BD6-4AEF-812E-0F1B37D06829")!,
        purpose: .password)
    let definition = try PostgreSQLDatabaseAdapterFixtures.definition(
        endpoints: [
            DatabaseNetworkEndpoint(
                host: host,
                port: DatabasePort(port),
                role: .primary)
        ],
        username: username,
        namespaces: DatabaseNamespaceDefaults(database: database),
        authentication: DatabaseAuthentication(
            kind: .usernameAndPassword,
            secretReferences: [reference]))
    let session = try await PostgreSQLDatabaseAdapter().connect(
        PostgreSQLDatabaseAdapterFixtures.resolved(
            definition,
            secrets: [reference: Data(password.utf8)]),
        context: PostgreSQLDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(10)))
    let report: DatabaseCapabilityReport
    do {
        report = try await session.discoverCapabilities(
            context: PostgreSQLDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(10)))
    } catch {
        await session.disconnect()
        throw error
    }
    await session.disconnect()
    #expect(report.productIdentity.product == .postgresql)
    #expect(report.productIdentity.version?.major == 17)
    #expect(report.supports(.connectionTest))
    print("postgresql adapter live capability discovery verified")
}
