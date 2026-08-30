import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import Testing

@testable import EdithDatabase

private struct MySQLDatabaseFoundationUnknownFailure: Error {}

private enum MySQLDatabaseFoundationFixtures {
    static let values = MySQLDatabaseIdentityValues(
        version: "8.4.6",
        versionComment: "MySQL Community Server - GPL",
        database: "edith_lab",
        hostName: "mysql-test",
        serverUUID: "11111111-2222-3333-4444-555555555555",
        readOnly: false,
        superReadOnly: false,
        defaultStorageEngine: "InnoDB",
        characterSet: "utf8mb4",
        collation: "utf8mb4_0900_ai_ci",
        compileMachine: "aarch64",
        compileOS: "Linux",
        tlsCipher: "TLS_AES_256_GCM_SHA384",
        groupMemberCount: 0,
        localMemberRole: "",
        groupReplicaCount: 0,
        replicaChannelCount: 0)

    static let identity = try! MySQLDatabaseDriverSupport.identity(values)

    static func definition(
        product: DatabaseProduct = .mysql,
        endpoints: [DatabaseNetworkEndpoint]? = nil,
        username: String? = "edith_reader",
        namespaces: DatabaseNamespaceDefaults = DatabaseNamespaceDefaults(
            catalog: "edith_lab",
            schema: "edith_lab",
            database: "edith_lab"),
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        let effectiveEndpoints =
            try endpoints ?? [
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: DatabasePort(53_306),
                    role: .primary)
            ]
        return DatabaseConnectionDefinition(
            id: DatabaseConnectionID(),
            displayName: "MySQL fixture",
            productHint: product,
            location: .network(effectiveEndpoints),
            username: username,
            namespaces: namespaces,
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 3_000),
                poolSize: try DatabasePoolSize(2)),
            readOnlyPolicy: .required,
            productionPolicy: .prohibitMutations,
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
    ) throws -> DatabaseResolvedConnection {
        let reference = DatabaseSecretReference(
            identifier: UUID(uuidString: "50D74B01-596B-4A16-9FA6-A2E43C7FCB49")!,
            purpose: .password)
        let definition = try definition(
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [reference]),
            tls: tls)
        return try resolved(
            definition,
            secrets: [reference: Data(password.utf8)])
    }
}

private actor MySQLDatabaseFoundationTestClient: MySQLDatabaseClient {
    private var identities: [DatabaseProductIdentity]
    private var delays: [UInt64]
    private var discoveryCount = 0
    private var disconnectCount = 0

    init(
        identities: [DatabaseProductIdentity] = [MySQLDatabaseFoundationFixtures.identity],
        delays: [UInt64] = []
    ) {
        self.identities = identities
        self.delays = delays
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        discoveryCount += 1
        let delay: UInt64
        if delays.isEmpty {
            delay = 0
        } else if delays.count == 1 {
            delay = delays[0]
        } else {
            delay = delays.removeFirst()
        }
        var remaining = delay
        while remaining > 0 {
            if disconnectCount > 0 {
                throw MySQLDatabaseDriverFailure.connection
            }
            let interval = min(remaining, 10_000_000)
            try await Task.sleep(nanoseconds: interval)
            remaining -= interval
        }
        guard !identities.isEmpty else {
            throw MySQLDatabaseDriverFailure.connection
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

@Test func mysqlFoundationConnectionPlanValidatesEndpointAndTLS() throws {
    let plan = MySQLDatabaseConnectionPlan(
        host: "db.example.test",
        port: 3_306,
        username: "reader",
        password: "fixture-password",
        database: "edith_lab",
        tls: .required(verifyCertificate: true),
        tlsServerName: nil,
        connectTimeoutMilliseconds: 2_000)
    try plan.validate()
    #expect(plan.effectiveTLSServerName == "db.example.test")
    #expect(plan.tls.requiresEncryption)
    #expect(plan.tls.configuration()?.minimumTLSVersion == .tlsv12)

    let ipPlan = MySQLDatabaseConnectionPlan(
        host: "127.0.0.1",
        port: 3_306,
        username: "reader",
        password: nil,
        database: nil,
        tls: .preferred(verifyCertificate: false),
        tlsServerName: nil,
        connectTimeoutMilliseconds: 2_000)
    try ipPlan.validate()
    #expect(ipPlan.effectiveTLSServerName == nil)

    let invalid = MySQLDatabaseConnectionPlan(
        host: "host with space",
        port: 0,
        username: "reader",
        password: nil,
        database: nil,
        tls: .disabled,
        tlsServerName: "unexpected.example.test",
        connectTimeoutMilliseconds: 0)
    #expect(throws: MySQLDatabaseDriverFailure.configuration) {
        try invalid.validate()
    }
}

@Test func mysqlFoundationIdentityMapsStandaloneServerAndCapabilities() throws {
    let identity = try MySQLDatabaseDriverSupport.identity(
        MySQLDatabaseFoundationFixtures.values)
    #expect(identity.product == .mysql)
    #expect(identity.version == DatabaseVersion(string: "8.4.6", major: 8, minor: 4, patch: 6))
    #expect(identity.distribution == "MySQL")
    #expect(identity.serverIdentifier == "11111111-2222-3333-4444-555555555555")
    #expect(identity.topology.kind == .standalone)
    #expect(identity.topology.localRole == "primary")
    #expect(identity.topology.nodeCount == 1)
    #expect(
        identity.topology.attributes.contains(
            DatabaseStringAttribute(name: "protocolVersion", value: "4.1")))
    #expect(
        identity.topology.attributes.contains(
            DatabaseStringAttribute(name: "tlsCipher", value: "TLS_AES_256_GCM_SHA384")))
}

@Test func mysqlFoundationIdentityMapsReplicationTopologies() throws {
    let group = try MySQLDatabaseDriverSupport.identity(
        MySQLDatabaseIdentityValues(
            version: "8.4.6",
            versionComment: "MySQL Community Server - GPL",
            database: "edith_lab",
            hostName: "mysql-group-2",
            serverUUID: "11111111-2222-3333-4444-555555555555",
            readOnly: true,
            superReadOnly: true,
            defaultStorageEngine: "InnoDB",
            characterSet: "utf8mb4",
            collation: "utf8mb4_0900_ai_ci",
            compileMachine: "aarch64",
            compileOS: "Linux",
            tlsCipher: "",
            groupMemberCount: 3,
            localMemberRole: "SECONDARY",
            groupReplicaCount: 2,
            replicaChannelCount: 0))
    #expect(group.topology.kind == .cluster)
    #expect(group.topology.localRole == "secondary")
    #expect(group.topology.nodeCount == 3)
    #expect(group.topology.replicaCount == 2)

    var replicaValues = MySQLDatabaseFoundationFixtures.values
    replicaValues = MySQLDatabaseIdentityValues(
        version: replicaValues.version,
        versionComment: replicaValues.versionComment,
        database: replicaValues.database,
        hostName: replicaValues.hostName,
        serverUUID: replicaValues.serverUUID,
        readOnly: true,
        superReadOnly: true,
        defaultStorageEngine: replicaValues.defaultStorageEngine,
        characterSet: replicaValues.characterSet,
        collation: replicaValues.collation,
        compileMachine: replicaValues.compileMachine,
        compileOS: replicaValues.compileOS,
        tlsCipher: replicaValues.tlsCipher,
        groupMemberCount: 0,
        localMemberRole: "",
        groupReplicaCount: 0,
        replicaChannelCount: 1)
    let replica = try MySQLDatabaseDriverSupport.identity(replicaValues)
    #expect(replica.topology.kind == .primaryReplica)
    #expect(replica.topology.localRole == "replica")
    #expect(replica.topology.nodeCount == nil)
}

@Test func mysqlFoundationRejectsMariaDBAndUnboundedIdentity() throws {
    #expect(throws: MySQLDatabaseDriverFailure.incompatibleProduct(.mariaDB)) {
        try MySQLDatabaseDriverSupport.requireMySQL(
            ("11.8.3-MariaDB", "MariaDB Server"))
    }
    #expect(throws: MySQLDatabaseDriverFailure.server(nil)) {
        var values = MySQLDatabaseFoundationFixtures.values
        values = MySQLDatabaseIdentityValues(
            version: values.version,
            versionComment: String(repeating: "x", count: 1_025),
            database: values.database,
            hostName: values.hostName,
            serverUUID: values.serverUUID,
            readOnly: values.readOnly,
            superReadOnly: values.superReadOnly,
            defaultStorageEngine: values.defaultStorageEngine,
            characterSet: values.characterSet,
            collation: values.collation,
            compileMachine: values.compileMachine,
            compileOS: values.compileOS,
            tlsCipher: values.tlsCipher,
            groupMemberCount: values.groupMemberCount,
            localMemberRole: values.localMemberRole,
            groupReplicaCount: values.groupReplicaCount,
            replicaChannelCount: values.replicaChannelCount)
        _ = try MySQLDatabaseDriverSupport.identity(values)
    }
    #expect(throws: MySQLDatabaseDriverFailure.server(nil)) {
        var values = MySQLDatabaseFoundationFixtures.values
        values = MySQLDatabaseIdentityValues(
            version: values.version,
            versionComment: values.versionComment,
            database: values.database,
            hostName: values.hostName,
            serverUUID: values.serverUUID,
            readOnly: values.readOnly,
            superReadOnly: values.superReadOnly,
            defaultStorageEngine: values.defaultStorageEngine,
            characterSet: values.characterSet,
            collation: values.collation,
            compileMachine: values.compileMachine,
            compileOS: values.compileOS,
            tlsCipher: values.tlsCipher,
            groupMemberCount: 1,
            localMemberRole: "PRIMARY",
            groupReplicaCount: 2,
            replicaChannelCount: 0)
        _ = try MySQLDatabaseDriverSupport.identity(values)
    }
}

@Test func mysqlFoundationErrorsRemainTypedAndRedacted() throws {
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 1045, sqlState: "28000")
            == .authentication)
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 1142, sqlState: "42000")
            == .permission("1142.42000"))
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 1317, sqlState: "70100")
            == .timeout)
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 2013, sqlState: "HY000")
            == .connection)
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 2026, sqlState: "HY000")
            == .tls)
    #expect(
        MySQLDatabaseDriverErrorClassifier.classify(code: 9999, sqlState: "unsafe detail")
            == .server("9999"))
    #expect(
        try MySQLDatabaseDriverErrorClassifier.classify(
            MySQLDatabaseFoundationUnknownFailure()) == .connection)
    #expect(throws: CancellationError.self) {
        _ = try MySQLDatabaseDriverErrorClassifier.classify(CancellationError())
    }
}

@Test func mysqlFoundationResponseGuardClosesOversizedResponse() async throws {
    let responseGuard = MySQLDatabaseInboundResponseGuard()
    let channel = EmbeddedChannel()
    try channel.pipeline.syncOperations.addHandler(responseGuard)
    #expect(responseGuard.begin(maximumBytes: 4))
    var buffer = channel.allocator.buffer(capacity: 5)
    buffer.writeRepeatingByte(1, count: 5)
    _ = try? channel.writeInbound(buffer)
    #expect(responseGuard.exceededLimit)
    #expect(!channel.isActive)
    responseGuard.end()
    _ = try? channel.finish()
}

@Test func mysqlFoundationClassifiesStalledHandshakeAsTimeout() async throws {
    try await withMySQLDatabaseStalledServer { port in
        let plan = MySQLDatabaseConnectionPlan(
            host: "127.0.0.1",
            port: port,
            username: "reader",
            password: "fixture-password",
            database: "edith_lab",
            tls: .disabled,
            tlsServerName: nil,
            connectTimeoutMilliseconds: 300)
        let startedAt = ContinuousClock.now
        await #expect(throws: MySQLDatabaseDriverFailure.timeout) {
            _ = try await MySQLNIODatabaseClient.connect(plan)
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
    }
}

@Test func mysqlFoundationCancelsStalledHandshakePromptly() async throws {
    try await withMySQLDatabaseStalledServer { port in
        let task = Task {
            try await MySQLNIODatabaseClient.connect(
                MySQLDatabaseConnectionPlan(
                    host: "127.0.0.1",
                    port: port,
                    username: "reader",
                    password: "fixture-password",
                    database: "edith_lab",
                    tls: .disabled,
                    tlsServerName: nil,
                    connectTimeoutMilliseconds: 5_000))
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        let startedAt = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
    }
}

@Test func mysqlFoundationAdapterBuildsTypedBoundedPlan() throws {
    let resolved = try MySQLDatabaseFoundationFixtures.passwordConnection()
    let plan = try MySQLDatabaseAdapterSupport.connectionPlan(
        resolved,
        context: MySQLDatabaseFoundationFixtures.context(
            deadline: Date().addingTimeInterval(10)))
    #expect(plan.host == "127.0.0.1")
    #expect(plan.port == 53_306)
    #expect(plan.username == "edith_reader")
    #expect(plan.password == "fixture-password")
    #expect(plan.database == "edith_lab")
    #expect(plan.tlsServerName == "database.example.test")
    #expect(plan.connectTimeoutMilliseconds == 2_000)
    guard case let .preferred(verifyCertificate) = plan.tls else {
        Issue.record("expected preferred TLS")
        return
    }
    #expect(!verifyCertificate)
}

@Test func mysqlFoundationAdapterRejectsAmbiguousConnections() throws {
    let endpoint = DatabaseNetworkEndpoint(
        host: "127.0.0.1",
        port: try DatabasePort(53_306),
        role: .primary)
    let multipleEndpoints = try MySQLDatabaseFoundationFixtures.definition(
        endpoints: [endpoint, endpoint])
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try MySQLDatabaseAdapterSupport.connectionPlan(
            MySQLDatabaseFoundationFixtures.resolved(multipleEndpoints),
            context: MySQLDatabaseFoundationFixtures.context())
    }
    let mismatchedNamespaces = try MySQLDatabaseFoundationFixtures.definition(
        namespaces: DatabaseNamespaceDefaults(catalog: "first", database: "second"))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try MySQLDatabaseAdapterSupport.connectionPlan(
            MySQLDatabaseFoundationFixtures.resolved(mismatchedNamespaces),
            context: MySQLDatabaseFoundationFixtures.context())
    }
    let wrongProduct = try MySQLDatabaseFoundationFixtures.definition(product: .mariaDB)
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try MySQLDatabaseAdapterSupport.connectionPlan(
            MySQLDatabaseFoundationFixtures.resolved(wrongProduct),
            context: MySQLDatabaseFoundationFixtures.context())
    }
}

@Test func mysqlFoundationAdapterLifecycleAndCapabilities() async throws {
    let client = MySQLDatabaseFoundationTestClient()
    let adapter = MySQLDatabaseAdapter { _ in client }
    let resolved = try MySQLDatabaseFoundationFixtures.passwordConnection()
    let session = try await adapter.connect(
        resolved,
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(await session.lifecycleState() == .connected)
    let report = try await session.discoverCapabilities(
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(report.productIdentity == MySQLDatabaseFoundationFixtures.identity)
    #expect(report.supports(.connectionTest))
    #expect(report.status(for: .browse)?.availability == .planned)
    #expect(report.transactionModes == [.explicit, .savepoints])
    #expect(report.cancellationModes == [.cooperative])
    await session.disconnect()
    #expect(await session.lifecycleState() == .disconnected)
    #expect(await client.disconnects() == 1)
    let concrete = try #require(session as? MySQLDatabaseAdapterSession)
    #expect(await !concrete.resourceIsOpen())
}

@Test func mysqlFoundationAdapterEnforcesDeadlineAndCancellation() async throws {
    let client = MySQLDatabaseFoundationTestClient(
        identities: [
            MySQLDatabaseFoundationFixtures.identity,
            MySQLDatabaseFoundationFixtures.identity,
        ],
        delays: [0, 5_000_000_000])
    let adapter = MySQLDatabaseAdapter { _ in client }
    let resolved = try MySQLDatabaseFoundationFixtures.resolved(
        MySQLDatabaseFoundationFixtures.definition())
    let session = try await adapter.connect(
        resolved,
        context: MySQLDatabaseFoundationFixtures.context())
    let operationID = DatabaseOperationID()
    let cancellation = DatabaseAdapterCancellationSignal()
    let discovery = Task {
        try await session.discoverCapabilities(
            context: MySQLDatabaseFoundationFixtures.context(
                operationID: operationID,
                deadline: Date().addingTimeInterval(5),
                cancellation: cancellation))
    }
    let waitDeadline = Date().addingTimeInterval(1)
    while await client.discoveries() < 2, Date() < waitDeadline {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(await client.discoveries() == 2)
    let result = await session.cancel(operationID)
    #expect(result.disposition == .accepted)
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await discovery.value
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)

    let deadlineClient = MySQLDatabaseFoundationTestClient(delays: [5_000_000_000])
    let deadlineAdapter = MySQLDatabaseAdapter { _ in deadlineClient }
    let startedAt = ContinuousClock.now
    await #expect(throws: MySQLDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await deadlineAdapter.connect(
            resolved,
            context: MySQLDatabaseFoundationFixtures.context(
                deadline: Date().addingTimeInterval(0.05)))
    }
    #expect(ContinuousClock.now - startedAt < .seconds(2))
    #expect(await deadlineClient.disconnects() == 1)
}

private func withMySQLDatabaseStalledServer<Output: Sendable>(
    _ body: @escaping @Sendable (Int) async throws -> Output
) async throws -> Output {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server: any Channel
    do {
        server = try await ServerBootstrap(group: group)
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    } catch {
        try? await group.shutdownGracefully()
        throw error
    }
    do {
        let port = try #require(server.localAddress?.port)
        let output = try await body(port)
        try await server.close()
        try await group.shutdownGracefully()
        return output
    } catch {
        try? await server.close()
        try? await group.shutdownGracefully()
        throw error
    }
}
