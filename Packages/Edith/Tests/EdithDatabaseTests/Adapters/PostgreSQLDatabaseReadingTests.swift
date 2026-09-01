import Foundation
import NIOCore
import PostgresNIO
import Testing

@testable import EdithDatabase

private enum PostgreSQLDatabaseReadingFixtures {
    static let identity = DatabaseProductIdentity(
        product: .postgresql,
        version: DatabaseVersion(string: "17.11", major: 17, minor: 11),
        distribution: "PostgreSQL",
        topology: DatabaseTopology(kind: .standalone, localRole: "primary", nodeCount: 1))

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID()
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id,
            displayName: "PostgreSQL reading fixture",
            productHint: .postgresql,
            location: .network([
                try DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: DatabasePort(55_432),
                    role: .primary)
            ]),
            username: "reader",
            namespaces: DatabaseNamespaceDefaults(
                catalog: "edith_lab",
                schema: "public",
                database: "edith_lab"),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 3_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: .required,
            productionPolicy: .prohibitMutations,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: .readOnly),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
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

    static func target(
        _ connectionID: DatabaseConnectionID,
        kind: DatabaseObjectKind = .table,
        path: [String] = ["public", "orders"]
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: kind, path: path))
    }

    static func pageRequest(
        connectionID: DatabaseConnectionID,
        pageSize: Int,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = []
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target(connectionID),
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(pageSize),
                projection: projection,
                filter: filter,
                sorts: sorts),
            continuation: continuation)
    }

    static func descriptor(
        key: Bool = true
    ) -> PostgreSQLDatabaseReadResult {
        PostgreSQLDatabaseReadResult(
            rows: [
                row([
                    string("column_name", "id"),
                    string("type_name", "bigint"),
                    int64("type_oid", 20),
                    bool("is_nullable", false),
                    int64("ordinal", 1),
                    string("relation_kind", "table"),
                    bool("is_key", key),
                    bool("key_is_primary", key),
                ]),
                row([
                    string("column_name", "notes"),
                    string("type_name", "text"),
                    int64("type_oid", 25),
                    bool("is_nullable", true),
                    int64("ordinal", 2),
                    string("relation_kind", "table"),
                    bool("is_key", false),
                    bool("key_is_primary", false),
                ]),
            ],
            bytesReceived: 64)
    }

    static func dataRows(_ values: [(Int64, String)]) -> PostgreSQLDatabaseReadResult {
        PostgreSQLDatabaseReadResult(
            rows: values.map { value in
                row([
                    int64("id", value.0),
                    string("notes", value.1),
                    int64("__edith_postgresql_key", value.0),
                ])
            },
            bytesReceived: UInt64(values.count * 24))
    }

    static func row(_ cells: [PostgresCell]) -> PostgreSQLDatabaseReadRow {
        PostgreSQLDatabaseReadRow(cells: cells)
    }

    static func string(
        _ name: String,
        _ value: String,
        type: PostgresDataType = .text
    ) -> PostgresCell {
        var bytes = ByteBuffer()
        if type == .jsonb {
            bytes.writeInteger(UInt8(1))
        }
        bytes.writeString(value)
        return PostgresCell(
            bytes: bytes,
            dataType: type,
            format: .binary,
            columnName: name,
            columnIndex: 0)
    }

    static func int64(_ name: String, _ value: Int64) -> PostgresCell {
        var bytes = ByteBuffer()
        bytes.writeInteger(value)
        return PostgresCell(
            bytes: bytes,
            dataType: .int8,
            format: .binary,
            columnName: name,
            columnIndex: 0)
    }

    static func bool(_ name: String, _ value: Bool) -> PostgresCell {
        var bytes = ByteBuffer()
        bytes.writeInteger(value ? UInt8(1) : UInt8(0))
        return PostgresCell(
            bytes: bytes,
            dataType: .bool,
            format: .binary,
            columnName: name,
            columnIndex: 0)
    }

    static func numeric(_ name: String) -> PostgresCell {
        var bytes = ByteBuffer()
        bytes.writeInteger(Int16(3))
        bytes.writeInteger(Int16(1))
        bytes.writeInteger(UInt16(0))
        bytes.writeInteger(UInt16(6))
        bytes.writeInteger(UInt16(12))
        bytes.writeInteger(UInt16(3456))
        bytes.writeInteger(UInt16(7890))
        return PostgresCell(
            bytes: bytes,
            dataType: .numeric,
            format: .binary,
            columnName: name,
            columnIndex: 0)
    }
}

private actor PostgreSQLDatabaseReadingClient: PostgreSQLDatabaseClient {
    private var outputs: [PostgreSQLDatabaseReadResult]
    private var plans: [PostgreSQLDatabaseReadPlan] = []
    private var delayNanoseconds: UInt64
    private var disconnected = false
    private var disconnectCount = 0

    init(
        outputs: [PostgreSQLDatabaseReadResult],
        delayNanoseconds: UInt64 = 0
    ) {
        self.outputs = outputs
        self.delayNanoseconds = delayNanoseconds
    }

    func discoverIdentity() throws -> DatabaseProductIdentity {
        guard !disconnected else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        return PostgreSQLDatabaseReadingFixtures.identity
    }

    func executeRead(
        _ plan: PostgreSQLDatabaseReadPlan
    ) async throws -> PostgreSQLDatabaseReadResult {
        plans.append(plan)
        var remaining = delayNanoseconds
        while remaining > 0 {
            let interval = min(remaining, 10_000_000)
            try await Task.sleep(nanoseconds: interval)
            guard !disconnected else {
                throw PostgreSQLDatabaseDriverFailure.connection
            }
            remaining -= interval
        }
        guard !disconnected, !outputs.isEmpty else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        return outputs.removeFirst()
    }

    func disconnect() {
        disconnected = true
        disconnectCount += 1
    }

    func capturedPlans() -> [PostgreSQLDatabaseReadPlan] {
        plans
    }

    func disconnects() -> Int {
        disconnectCount
    }
}

@Test func postgresqlReadingBuildsValidCaseInsensitiveLikeEscape() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let client = PostgreSQLDatabaseReadingClient(outputs: [
        PostgreSQLDatabaseReadingFixtures.descriptor(),
        PostgreSQLDatabaseReadingFixtures.dataRows([(1, "50%_off\\")]),
    ])
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let filter = DatabaseFilter.predicate(
        DatabaseFilterPredicate(
            field: DatabaseFieldPath("notes"),
            operation: .contains,
            values: [.string("50%_off\\")],
            caseSensitivity: .insensitive))

    _ = try await session.readPage(
        PostgreSQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            pageSize: 2,
            filter: filter),
        context: PostgreSQLDatabaseReadingFixtures.context())

    let plan = try #require(await client.capturedPlans().last)
    #expect(plan.sql.contains(#""_edith_relation"."notes" ILIKE $1 ESCAPE '\'"#))
    #expect(plan.parameters == [.string("%50\\%\\_off\\\\%")])
}

@Test func postgresqlReadingBrowsesWithBoundedKeysetContinuations() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let client = PostgreSQLDatabaseReadingClient(outputs: [
        PostgreSQLDatabaseReadingFixtures.descriptor(),
        PostgreSQLDatabaseReadingFixtures.dataRows([(1, "one"), (2, "two"), (3, "three")]),
        PostgreSQLDatabaseReadingFixtures.descriptor(),
        PostgreSQLDatabaseReadingFixtures.dataRows([(3, "three")]),
    ])
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let firstRequest = try PostgreSQLDatabaseReadingFixtures.pageRequest(
        connectionID: definition.id,
        pageSize: 2)
    let first = try await session.readPage(
        firstRequest,
        context: PostgreSQLDatabaseReadingFixtures.context())
    #expect(first.records.count == 2)
    #expect(first.nextContinuation?.mode == .keyset)
    #expect(
        first.records.map { $0.identity?.components.first?.value } == [
            .signedInteger(1), .signedInteger(2),
        ])
    let continuation = try #require(first.nextContinuation)
    #expect(continuation.payload.count < 1_024)
    let second = try await session.readPage(
        PostgreSQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            pageSize: 2,
            continuation: continuation),
        context: PostgreSQLDatabaseReadingFixtures.context())
    #expect(second.records.count == 1)
    #expect(second.nextContinuation == nil)
    let plans = await client.capturedPlans()
    #expect(plans.count == 4)
    #expect(plans[1].sql.contains("LIMIT 3"))
    #expect(!plans[1].sql.contains(" OFFSET "))
    #expect(plans[3].sql.contains(#"> $1"#))
    #expect(plans[3].parameters == [.signedInteger(2)])
}

@Test func postgresqlReadingBindsContinuationsToSessionAndRequest() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let client = PostgreSQLDatabaseReadingClient(outputs: [
        PostgreSQLDatabaseReadingFixtures.descriptor(),
        PostgreSQLDatabaseReadingFixtures.dataRows([(1, "one"), (2, "two")]),
        PostgreSQLDatabaseReadingFixtures.descriptor(),
    ])
    let firstSession = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let request = try PostgreSQLDatabaseReadingFixtures.pageRequest(
        connectionID: definition.id,
        pageSize: 1)
    let page = try await firstSession.readPage(
        request,
        context: PostgreSQLDatabaseReadingFixtures.context())
    let continuation = try #require(page.nextContinuation)
    let secondSession = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: PostgreSQLDatabaseReadingClient(outputs: [
            PostgreSQLDatabaseReadingFixtures.descriptor()
        ]))
    await #expect(throws: PostgreSQLDatabaseAdapterSupport.invalidContinuation) {
        _ = try await secondSession.readPage(
            PostgreSQLDatabaseReadingFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 1,
                continuation: continuation),
            context: PostgreSQLDatabaseReadingFixtures.context())
    }
    await #expect(throws: PostgreSQLDatabaseAdapterSupport.invalidContinuation) {
        _ = try await firstSession.readPage(
            PostgreSQLDatabaseReadingFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 2,
                continuation: continuation),
            context: PostgreSQLDatabaseReadingFixtures.context())
    }
}

@Test func postgresqlReadingDisclosesOffsetFallback() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let client = PostgreSQLDatabaseReadingClient(outputs: [
        PostgreSQLDatabaseReadingFixtures.descriptor(key: false),
        PostgreSQLDatabaseReadingFixtures.dataRows([(1, "one"), (2, "two")]),
    ])
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let page = try await session.readPage(
        PostgreSQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            pageSize: 1),
        context: PostgreSQLDatabaseReadingFixtures.context())
    #expect(page.nextContinuation?.mode == .offset)
    #expect(page.metadata.warnings.map(\.code) == ["postgresql.paging.offset"])
    let plans = await client.capturedPlans()
    #expect(plans.last?.sql.contains("OFFSET 0") == true)
}

@Test func postgresqlReadingExecutesParameterizedBoundedSQL() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let output = PostgreSQLDatabaseReadResult(
        rows: [
            PostgreSQLDatabaseReadingFixtures.row([
                PostgreSQLDatabaseReadingFixtures.int64("id", 42),
                PostgreSQLDatabaseReadingFixtures.string("label", "bounded"),
            ])
        ],
        bytesReceived: 15)
    let client = PostgreSQLDatabaseReadingClient(outputs: [output])
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let source = DatabaseQueryRequest(
        target: DatabaseTargetIdentifier(connectionID: definition.id),
        language: .sql,
        command: "SELECT $1::int8 AS id, $2::text AS label",
        parameters: [
            DatabaseQueryParameter(value: .signedInteger(42)),
            DatabaseQueryParameter(value: .string("bounded")),
        ],
        page: DatabasePageRequest(pageSize: try DatabasePageSize(2)))
    let page = try await session.query(
        DatabaseAdapterQueryRequest(request: source, continuation: nil),
        context: PostgreSQLDatabaseReadingFixtures.context())
    #expect(
        page.records.first?.fields.map(\.value) == [
            .signedInteger(42), .string("bounded"),
        ])
    let plan = try #require(await client.capturedPlans().first)
    #expect(plan.sql.contains("LIMIT 3 OFFSET 0"))
    #expect(plan.parameters == source.parameters.map(\.value))
}

@Test func postgresqlReadingRejectsUnsafeOrAmbiguousSQLBeforeExecution() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let client = PostgreSQLDatabaseReadingClient(outputs: [])
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    for command in [
        "UPDATE public.orders SET notes = 'x' RETURNING id",
        "SELECT 1; SELECT 2",
        "WITH changed AS (DELETE FROM public.orders RETURNING id) SELECT id FROM changed",
        "SELECT 1 -- hidden",
        "SELECT $2::int8",
    ] {
        let parameters =
            command.contains("$2")
            ? [DatabaseQueryParameter(value: .signedInteger(1))]
            : []
        let request = DatabaseQueryRequest(
            target: DatabaseTargetIdentifier(connectionID: definition.id),
            language: .sql,
            command: command,
            parameters: parameters,
            page: DatabasePageRequest(pageSize: try DatabasePageSize(1)))
        await #expect(throws: PostgreSQLDatabaseAdapterSupport.invalidQuery) {
            _ = try await session.query(
                DatabaseAdapterQueryRequest(request: request, continuation: nil),
                context: PostgreSQLDatabaseReadingFixtures.context())
        }
    }
    #expect(await client.capturedPlans().isEmpty)
}

@Test func postgresqlReadingDecodesPreciseAndProductValues() throws {
    #expect(
        try PostgreSQLDatabaseReadValueSupport.value(
            PostgreSQLDatabaseReadingFixtures.numeric("amount"))
            == .decimal(DatabaseDecimalValue(rawValue: "123456.789000")))
    #expect(
        try PostgreSQLDatabaseReadValueSupport.value(
            PostgreSQLDatabaseReadingFixtures.string(
                "payload",
                #"{"exact":12345678901234567890}"#,
                type: .jsonb))
            == .productSpecific(
                DatabaseProductValue(
                    product: .postgresql,
                    typeName: "JSONB",
                    textRepresentation: #"{"exact":12345678901234567890}"#)))
    #expect(PostgreSQLDatabaseReadValueSupport.validDecimal("-12.3400e+5"))
    #expect(!PostgreSQLDatabaseReadValueSupport.validDecimal("12;DROP TABLE x"))
}

@Test func postgresqlReadingCancellationClosesTheSessionAndAllowsReconnect() async throws {
    let definition = try PostgreSQLDatabaseReadingFixtures.definition()
    let operationID = DatabaseOperationID()
    let cancellation = DatabaseAdapterCancellationSignal()
    let client = PostgreSQLDatabaseReadingClient(
        outputs: [
            PostgreSQLDatabaseReadResult(
                rows: [
                    PostgreSQLDatabaseReadingFixtures.row([
                        PostgreSQLDatabaseReadingFixtures.int64("value", 1)
                    ])
                ],
                bytesReceived: 8)
        ],
        delayNanoseconds: 1_000_000_000)
    let session = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: client)
    let request = try DatabaseAdapterQueryRequest(
        request: DatabaseQueryRequest(
            target: DatabaseTargetIdentifier(connectionID: definition.id),
            language: .sql,
            command: "SELECT 1::int8 AS value",
            page: DatabasePageRequest(pageSize: try DatabasePageSize(1))),
        continuation: nil)
    let task = Task {
        try await session.query(
            request,
            context: PostgreSQLDatabaseReadingFixtures.context(
                operationID: operationID,
                cancellation: cancellation))
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    let cancellationResult = await session.cancel(operationID)
    #expect(cancellationResult.disposition == .accepted)
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await task.value
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnects() == 1)
    let replacement = PostgreSQLDatabaseAdapterSession(
        connection: definition,
        productIdentity: PostgreSQLDatabaseReadingFixtures.identity,
        client: PostgreSQLDatabaseReadingClient(outputs: [
            PostgreSQLDatabaseReadResult(
                rows: [
                    PostgreSQLDatabaseReadingFixtures.row([
                        PostgreSQLDatabaseReadingFixtures.int64("value", 1)
                    ])
                ],
                bytesReceived: 8)
        ]))
    let page = try await replacement.query(
        request,
        context: PostgreSQLDatabaseReadingFixtures.context())
    #expect(page.records.count == 1)
}
