import Foundation
import Testing

@testable import EdithDatabase

private enum ClickHouseDatabaseMutationFixtures {
    static let identity = try! ClickHouseDatabaseDriverSupport.identity(
        ClickHouseDatabaseIdentityValues(
            version: "26.7.5.10",
            database: "analytics",
            timezone: "UTC",
            hostName: "clickhouse-mutation-test",
            clusterName: "",
            clusterNodeCount: 0,
            shardCount: 0,
            totalReplicas: 0))

    static func definition(
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled,
        productionPolicy: DatabaseProductionPolicy = .standard,
        environmentProtection: DatabaseEnvironmentProtection = .standard
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: DatabaseConnectionID(),
            displayName: "ClickHouse mutation fixture",
            productHint: .clickHouse,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(8_123),
                    role: .node)
            ]),
            username: "writer",
            namespaces: DatabaseNamespaceDefaults(database: "analytics"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 10_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: environmentProtection),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func target(
        connectionID: DatabaseConnectionID,
        kind: DatabaseObjectKind = .table,
        database: String = "analytics"
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(
                kind: kind,
                path: [database, "events"]))
    }

    static func context() -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(operationID: DatabaseOperationID()),
            cancellation: DatabaseAdapterCancellationSignal())
    }

    static func description(
        engine: String = "ReplicatedMergeTree",
        generated: Bool = false
    ) throws -> ClickHouseDatabaseHTTPResponse {
        try response(
            names: [
                "name", "type", "position", "is_in_primary_key", "is_in_sorting_key",
                "default_kind", "engine",
            ],
            types: ["String", "String", "UInt64", "UInt64", "UInt64", "String", "String"],
            rows: [
                ["event_id", "UInt64", "1", "1", "1", "", engine],
                ["category", "LowCardinality(String)", "2", "0", "0", "", engine],
                ["note", "Nullable(String)", "3", "0", "0", "DEFAULT", engine],
                [
                    "generated", "UInt64", "4", "0", "0",
                    generated ? "MATERIALIZED" : "", engine,
                ],
            ])
    }

    static func response(
        names: [String],
        types: [String],
        rows: [[Any]]
    ) throws -> ClickHouseDatabaseHTTPResponse {
        var body = Data()
        for line in [names as [Any], types as [Any]] + rows {
            body.append(try JSONSerialization.data(withJSONObject: line))
            body.append(0x0A)
        }
        return ClickHouseDatabaseHTTPResponse(
            statusCode: 200,
            exceptionCode: nil,
            body: body)
    }

    static func envelope(
        _ operation: () async throws -> Void
    ) async -> DatabaseErrorEnvelope? {
        do {
            try await operation()
            return nil
        } catch let failure as DatabaseAdapterFailure {
            guard case let .reported(envelope) = failure else { return nil }
            return envelope
        } catch {
            return nil
        }
    }
}

private struct ClickHouseDatabaseMutationOperation: Equatable, Sendable {
    let query: String
    let parameters: [ClickHouseDatabaseHTTPParameter]
}

private final class ClickHouseDatabaseMutationClient: ClickHouseDatabaseClient,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let descriptionResponse: ClickHouseDatabaseHTTPResponse
    private var recordedOperations: [ClickHouseDatabaseMutationOperation] = []
    private var disconnected = false

    init(descriptionResponse: ClickHouseDatabaseHTTPResponse) {
        self.descriptionResponse = descriptionResponse
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard !lock.withLock({ disconnected }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        return ClickHouseDatabaseMutationFixtures.identity
    }

    func execute(
        query: String,
        maximumResponseBytes: Int,
        parameters: [ClickHouseDatabaseHTTPParameter]
    ) async throws -> ClickHouseDatabaseHTTPResponse {
        guard !lock.withLock({ disconnected }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        lock.withLock {
            recordedOperations.append(
                ClickHouseDatabaseMutationOperation(query: query, parameters: parameters))
        }
        if query.contains("FROM system.columns AS c") {
            return descriptionResponse
        }
        guard query.hasPrefix("INSERT INTO") else {
            throw ClickHouseDatabaseDriverFailure.server(nil)
        }
        return ClickHouseDatabaseHTTPResponse(
            statusCode: 200,
            exceptionCode: nil,
            body: Data())
    }

    func disconnect() async {
        lock.withLock { disconnected = true }
    }

    var operations: [ClickHouseDatabaseMutationOperation] {
        lock.withLock { recordedOperations }
    }
}

@Test func clickHouseInsertBuildsCanonicalSingleRowRequest() throws {
    let definition = try ClickHouseDatabaseMutationFixtures.definition()
    let request = try DatabaseRowMutationRequests.clickHouseInsert(
        target: ClickHouseDatabaseMutationFixtures.target(connectionID: definition.id),
        values: [
            DatabaseObjectField(name: "event_id", value: .unsignedInteger(42)),
            DatabaseObjectField(name: "category", value: .string("signup")),
        ])
    #expect(
        request.payload.command
            == "INSERT INTO `analytics`.`events` (`event_id`, `category`) VALUES (?, ?)")
    #expect(request.payload.product == .clickHouse)
    #expect(request.payload.parameters.map(\.name) == ["event_id", "category"])
    #expect(throws: DatabaseRowMutationRequestError.invalidTarget) {
        _ = try DatabaseRowMutationRequests.clickHouseInsert(
            target: ClickHouseDatabaseMutationFixtures.target(
                connectionID: definition.id,
                kind: .view),
            values: [DatabaseObjectField(name: "event_id", value: .unsignedInteger(42))])
    }
}

@Test func clickHouseInsertPreflightsAndBindsOneMergeTreeRow() async throws {
    let definition = try ClickHouseDatabaseMutationFixtures.definition()
    let client = ClickHouseDatabaseMutationClient(
        descriptionResponse: try ClickHouseDatabaseMutationFixtures.description())
    let session = try await ClickHouseDatabaseAdapter { _ in client }.connect(
        try DatabaseResolvedConnection(definition: definition, secrets: [:]),
        context: ClickHouseDatabaseMutationFixtures.context())
    let capabilities = try await session.discoverCapabilities(
        context: ClickHouseDatabaseMutationFixtures.context())
    #expect(capabilities.supports(.insert))
    #expect(capabilities.supports(.update) == false)
    #expect(capabilities.supports(.delete) == false)
    #expect(capabilities.mutationModes == [.singleRecord])
    let request = try DatabaseRowMutationRequests.clickHouseInsert(
        target: ClickHouseDatabaseMutationFixtures.target(connectionID: definition.id),
        values: [
            DatabaseObjectField(name: "event_id", value: .unsignedInteger(42)),
            DatabaseObjectField(name: "category", value: .string("signup")),
            DatabaseObjectField(name: "note", value: .null),
        ])
    let plan = try await session.normalizeMutation(
        request,
        context: ClickHouseDatabaseMutationFixtures.context())
    #expect(plan.action == .insert)
    #expect(plan.scope == .entireObject)
    #expect(plan.transactionBehavior == .nontransactional)
    #expect(plan.rollbackAvailability == .unavailable)
    let result = try await session.executeMutation(
        plan,
        context: ClickHouseDatabaseMutationFixtures.context())
    #expect(result.effect == .applied)
    #expect(result.affectedRecords.value == 1)
    let operations = client.operations
    #expect(operations.filter { $0.query.contains("FROM system.columns AS c") }.count == 2)
    let insert = try #require(operations.first(where: { $0.query.hasPrefix("INSERT INTO") }))
    let expectedQuery =
        "INSERT INTO `analytics`.`events` (`event_id`, `category`, `note`) "
        + "VALUES (CAST({_edith_insert_0:String}, 'UInt64'), "
        + "CAST({_edith_insert_1:String}, 'LowCardinality(String)'), "
        + "CAST(NULL, 'Nullable(String)'))"
    #expect(insert.query == expectedQuery)
    #expect(
        insert.parameters
            == [
                ClickHouseDatabaseHTTPParameter(name: "_edith_insert_0", value: "42"),
                ClickHouseDatabaseHTTPParameter(name: "_edith_insert_1", value: "signup"),
            ])
    await session.disconnect()
}

@Test func clickHouseInsertRejectsReadOnlyTargetsAndGeneratedColumns() async throws {
    let definition = try ClickHouseDatabaseMutationFixtures.definition()
    let target = ClickHouseDatabaseMutationFixtures.target(connectionID: definition.id)
    let distributedClient = ClickHouseDatabaseMutationClient(
        descriptionResponse: try ClickHouseDatabaseMutationFixtures.description(
            engine: "Distributed"))
    let distributedSession = try await ClickHouseDatabaseAdapter { _ in distributedClient }
        .connect(
            try DatabaseResolvedConnection(definition: definition, secrets: [:]),
            context: ClickHouseDatabaseMutationFixtures.context())
    let request = try DatabaseRowMutationRequests.clickHouseInsert(
        target: target,
        values: [DatabaseObjectField(name: "event_id", value: .unsignedInteger(42))])
    let distributedEnvelope = await ClickHouseDatabaseMutationFixtures.envelope {
        _ = try await distributedSession.normalizeMutation(
            request,
            context: ClickHouseDatabaseMutationFixtures.context())
    }
    #expect(distributedEnvelope?.productCode == "clickhouse.mutation.target_read_only")
    #expect(distributedClient.operations.allSatisfy { !$0.query.hasPrefix("INSERT INTO") })
    await distributedSession.disconnect()

    let generatedClient = ClickHouseDatabaseMutationClient(
        descriptionResponse: try ClickHouseDatabaseMutationFixtures.description(generated: true))
    let generatedSession = try await ClickHouseDatabaseAdapter { _ in generatedClient }.connect(
        try DatabaseResolvedConnection(definition: definition, secrets: [:]),
        context: ClickHouseDatabaseMutationFixtures.context())
    let generatedRequest = try DatabaseRowMutationRequests.clickHouseInsert(
        target: target,
        values: [DatabaseObjectField(name: "generated", value: .unsignedInteger(7))])
    let generatedEnvelope = await ClickHouseDatabaseMutationFixtures.envelope {
        _ = try await generatedSession.normalizeMutation(
            generatedRequest,
            context: ClickHouseDatabaseMutationFixtures.context())
    }
    #expect(generatedEnvelope?.productCode == "clickhouse.mutation.invalid")
    #expect(generatedClient.operations.allSatisfy { !$0.query.hasPrefix("INSERT INTO") })
    await generatedSession.disconnect()
}

@Test func clickHouseInsertHonorsConnectionMutationPolicyBeforePreflight() async throws {
    let definition = try ClickHouseDatabaseMutationFixtures.definition(
        readOnlyPolicy: .required,
        productionPolicy: .prohibitMutations,
        environmentProtection: .readOnly)
    let client = ClickHouseDatabaseMutationClient(
        descriptionResponse: try ClickHouseDatabaseMutationFixtures.description())
    let session = try await ClickHouseDatabaseAdapter { _ in client }.connect(
        try DatabaseResolvedConnection(definition: definition, secrets: [:]),
        context: ClickHouseDatabaseMutationFixtures.context())
    let capabilities = try await session.discoverCapabilities(
        context: ClickHouseDatabaseMutationFixtures.context())
    #expect(capabilities.supports(.insert) == false)
    #expect(capabilities.mutationModes.isEmpty)
    let request = try DatabaseRowMutationRequests.clickHouseInsert(
        target: ClickHouseDatabaseMutationFixtures.target(connectionID: definition.id),
        values: [DatabaseObjectField(name: "event_id", value: .unsignedInteger(42))])
    let envelope = await ClickHouseDatabaseMutationFixtures.envelope {
        _ = try await session.normalizeMutation(
            request,
            context: ClickHouseDatabaseMutationFixtures.context())
    }
    #expect(envelope?.productCode == "clickhouse.read_only")
    #expect(client.operations.isEmpty)
    await session.disconnect()
}
