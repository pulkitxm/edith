import Foundation
import Testing

@testable import EdithDatabase

private enum PostgreSQLDatabaseReadingLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_POSTGRESQL_HOST",
        "EDITH_DATABASE_POSTGRESQL_PORT",
        "EDITH_DATABASE_POSTGRESQL_DATABASE",
        "EDITH_DATABASE_POSTGRESQL_USERNAME",
        "EDITH_DATABASE_POSTGRESQL_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }
    static let traversalIsEnabled =
        isEnabled && values["EDITH_DATABASE_POSTGRESQL_TRAVERSAL"] == "1"

    static func plan(
        statementTimeoutMilliseconds: UInt64 = 15_000,
        readOnly: Bool = true
    ) throws -> PostgreSQLDatabaseConnectionPlan {
        let host = try #require(values["EDITH_DATABASE_POSTGRESQL_HOST"])
        let portText = try #require(values["EDITH_DATABASE_POSTGRESQL_PORT"])
        let port = try #require(Int(portText))
        let database = try #require(values["EDITH_DATABASE_POSTGRESQL_DATABASE"])
        let username = try #require(values["EDITH_DATABASE_POSTGRESQL_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_POSTGRESQL_PASSWORD"])
        return PostgreSQLDatabaseConnectionPlan(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: .disabled,
            tlsServerName: nil,
            connectTimeoutMilliseconds: 5_000,
            statementTimeoutMilliseconds: statementTimeoutMilliseconds,
            readOnly: readOnly)
    }

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        writable: Bool = false
    ) throws -> DatabaseConnectionDefinition {
        let plan = try plan(readOnly: !writable)
        return DatabaseConnectionDefinition(
            id: id,
            displayName: "PostgreSQL reading live fixture",
            productHint: .postgresql,
            location: .network([
                try DatabaseNetworkEndpoint(
                    host: plan.host,
                    port: DatabasePort(plan.port),
                    role: .primary)
            ]),
            username: plan.username,
            namespaces: DatabaseNamespaceDefaults(
                catalog: plan.database,
                schema: "public",
                database: plan.database),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(kind: .none),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 15_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: writable ? .disabled : .required,
            productionPolicy: writable ? .standard : .prohibitMutations,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: writable ? .standard : .readOnly),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func session(
        statementTimeoutMilliseconds: UInt64 = 15_000,
        writable: Bool = false
    ) async throws -> PostgreSQLDatabaseAdapterSession {
        let definition = try definition(writable: writable)
        let client = try await PostgresNIODatabaseClient.connect(
            plan(
                statementTimeoutMilliseconds: statementTimeoutMilliseconds,
                readOnly: !writable))
        do {
            let identity = try await client.discoverIdentity()
            return PostgreSQLDatabaseAdapterSession(
                connection: definition,
                productIdentity: identity,
                client: client)
        } catch {
            await client.disconnect()
            throw error
        }
    }

    static func context(
        operationID: DatabaseOperationID = DatabaseOperationID(),
        deadline: Date? = Date().addingTimeInterval(15)
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(
                operationID: operationID,
                deadline: deadline),
            cancellation: DatabaseAdapterCancellationSignal())
    }

    static func query(
        connectionID: DatabaseConnectionID,
        command: String,
        parameters: [DatabaseQueryParameter] = [],
        pageSize: Int = 10,
        continuation: DatabaseAdapterContinuation? = nil
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: DatabaseTargetIdentifier(connectionID: connectionID),
                language: .sql,
                command: command,
                parameters: parameters,
                page: DatabasePageRequest(
                    pageSize: try DatabasePageSize(pageSize))),
            continuation: continuation)
    }

    static func browse(
        connectionID: DatabaseConnectionID,
        relation: String,
        pageSize: Int,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: DatabaseTargetIdentifier(
                connectionID: connectionID,
                object: DatabaseObjectIdentifier(
                    kind: .table,
                    path: ["public", relation])),
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(pageSize),
                projection: projection),
            continuation: continuation)
    }

    static func value(
        _ name: String,
        in record: DatabaseRecord
    ) throws -> DatabaseValue {
        try #require(record.fields.first { $0.name == name }).value
    }

    static func signed(
        _ name: String,
        in record: DatabaseRecord
    ) throws -> Int64 {
        guard case let .signedInteger(value) = try value(name, in: record) else {
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
        return value
    }

    static func verifyReconnect() async throws {
        let replacement = try await session()
        do {
            let page = try await replacement.query(
                query(
                    connectionID: replacement.connection.id,
                    command: "SELECT 1::int8 AS value",
                    pageSize: 1),
                context: context())
            #expect(try signed("value", in: #require(page.records.first)) == 1)
        } catch {
            await replacement.disconnect()
            throw error
        }
        await replacement.disconnect()
    }

    static func executeSetup(
        _ sql: String,
        client: any PostgreSQLDatabaseClient
    ) async throws {
        _ = try await client.executeMutation(
            PostgreSQLDatabaseMutationPlan(sql: sql, parameters: []))
    }
}

@Suite
struct PostgreSQLDatabaseReadingLiveTests {
    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlMutationLiveCreatesUpdatesAndDeletesRow() async throws {
        let table = "edith_mutation_probe"
        let client = try await PostgresNIODatabaseClient.connect(
            PostgreSQLDatabaseReadingLiveEnvironment.plan(readOnly: false))
        let definition = try PostgreSQLDatabaseReadingLiveEnvironment.definition(writable: true)
        let identity = try await client.discoverIdentity()
        let session = PostgreSQLDatabaseAdapterSession(
            connection: definition,
            productIdentity: identity,
            client: client)
        do {
            try await PostgreSQLDatabaseReadingLiveEnvironment.executeSetup(
                "DROP TABLE IF EXISTS public.\(table)",
                client: client)
            try await PostgreSQLDatabaseReadingLiveEnvironment.executeSetup(
                "CREATE TABLE public.\(table) (id bigint PRIMARY KEY, name text NOT NULL)",
                client: client)
            let target = DatabaseTargetIdentifier(
                connectionID: definition.id,
                object: DatabaseObjectIdentifier(kind: .table, path: ["public", table]))
            let insertRequest = try DatabaseRowMutationRequests.postgreSQLInsert(
                target: target,
                values: [
                    DatabaseObjectField(name: "id", value: .signedInteger(1)),
                    DatabaseObjectField(name: "name", value: .string("before")),
                ])
            let insertPlan = try await session.normalizeMutation(
                insertRequest,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let insert = try await session.executeMutation(
                insertPlan,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(insert.effect == .applied)
            #expect(insert.affectedRecords.value == 1)

            let firstPage = try await session.readPage(
                PostgreSQLDatabaseReadingLiveEnvironment.browse(
                    connectionID: definition.id,
                    relation: table,
                    pageSize: 10),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let firstRecord = try #require(firstPage.records.first)
            let firstIdentity = try #require(firstRecord.identity)
            let recordTarget = DatabaseTargetIdentifier(
                connectionID: definition.id,
                object: target.object,
                record: firstIdentity)
            let updateRequest = try DatabaseRowMutationRequests.postgreSQLUpdate(
                target: recordTarget,
                values: [DatabaseObjectField(name: "name", value: .string("after"))])
            let updatePlan = try await session.normalizeMutation(
                updateRequest,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let update = try await session.executeMutation(
                updatePlan,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(update.effect == .applied)

            let updatedPage = try await session.readPage(
                PostgreSQLDatabaseReadingLiveEnvironment.browse(
                    connectionID: definition.id,
                    relation: table,
                    pageSize: 10),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(
                try PostgreSQLDatabaseReadingLiveEnvironment.value(
                    "name",
                    in: #require(updatedPage.records.first)) == .string("after"))

            let deleteRequest = try DatabaseRowMutationRequests.postgreSQLDelete(
                target: recordTarget)
            let deletePlan = try await session.normalizeMutation(
                deleteRequest,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let delete = try await session.executeMutation(
                deletePlan,
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(delete.effect == .applied)

            let emptyPage = try await session.readPage(
                PostgreSQLDatabaseReadingLiveEnvironment.browse(
                    connectionID: definition.id,
                    relation: table,
                    pageSize: 10),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(emptyPage.records.isEmpty)
            try await PostgreSQLDatabaseReadingLiveEnvironment.executeSetup(
                "DROP TABLE public.\(table)",
                client: client)
        } catch {
            try? await PostgreSQLDatabaseReadingLiveEnvironment.executeSetup(
                "DROP TABLE IF EXISTS public.\(table)",
                client: client)
            await session.disconnect()
            throw error
        }
        await session.disconnect()
        print("postgresql mutation live verified insert=1 update=1 delete=1 cleanup=true")
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlReadingLiveDiscoversAndDecodesFixture() async throws {
        let session = try await PostgreSQLDatabaseReadingLiveEnvironment.session()
        do {
            let schemas = try await session.readPage(
                DatabaseAdapterPageRequest(
                    target: DatabaseTargetIdentifier(connectionID: session.connection.id),
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    continuation: nil),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(
                schemas.records.contains {
                    $0.fields.contains {
                        $0.name == "name" && $0.value == .string("public")
                    }
                })
            let relations = try await session.readPage(
                DatabaseAdapterPageRequest(
                    target: DatabaseTargetIdentifier(
                        connectionID: session.connection.id,
                        object: DatabaseObjectIdentifier(
                            kind: .schema,
                            path: ["public"])),
                    page: DatabasePageRequest(pageSize: try DatabasePageSize(100)),
                    continuation: nil),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let relationNames = Set(
                relations.records.compactMap { record in
                    record.fields.first { $0.name == "name" }.flatMap { field in
                        if case let .string(value) = field.value { return value }
                        return nil
                    }
                })
            #expect(relationNames.isSuperset(of: ["orders", "type_samples"]))
            let types = try await session.readPage(
                PostgreSQLDatabaseReadingLiveEnvironment.browse(
                    connectionID: session.connection.id,
                    relation: "type_samples",
                    pageSize: 2),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(types.records.count == 2)
            let typeNames = Set(types.fields.map { $0.path.segments.joined(separator: ".") })
            #expect(
                typeNames.isSuperset(of: [
                    "precise_value", "float_value", "calendar_date", "clock_time",
                    "interval_value", "network_value", "hardware_value", "bit_value",
                    "xml_value", "optional_value",
                ]))
            let query = try await session.query(
                PostgreSQLDatabaseReadingLiveEnvironment.query(
                    connectionID: session.connection.id,
                    command:
                        "SELECT $1::int8 AS exact_id, $2::numeric AS exact_numeric, $3::text AS exact_text",
                    parameters: [
                        DatabaseQueryParameter(value: .signedInteger(42)),
                        DatabaseQueryParameter(
                            value: .decimal(DatabaseDecimalValue(rawValue: "1234567890.012300"))),
                        DatabaseQueryParameter(value: .string("bound-value")),
                    ],
                    pageSize: 1),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            let record = try #require(query.records.first)
            #expect(
                try PostgreSQLDatabaseReadingLiveEnvironment.signed("exact_id", in: record) == 42)
            #expect(
                try PostgreSQLDatabaseReadingLiveEnvironment.value(
                    "exact_numeric",
                    in: record)
                    == .decimal(DatabaseDecimalValue(rawValue: "1234567890.012300")))
            #expect(
                try PostgreSQLDatabaseReadingLiveEnvironment.value("exact_text", in: record)
                    == .string("bound-value"))
            print(
                "postgresql reading live discovery verified schemas=\(schemas.records.count) relations=\(relations.records.count) typeRows=\(types.records.count)"
            )
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlReadingLiveEnforcesReadOnlyTransactionsAndReusesConnection() async throws {
        let client = try await PostgresNIODatabaseClient.connect(
            PostgreSQLDatabaseReadingLiveEnvironment.plan())
        do {
            await #expect(throws: PostgreSQLDatabaseDriverFailure.server("25006")) {
                _ = try await client.executeRead(
                    PostgreSQLDatabaseReadPlan(
                        sql: "UPDATE public.orders SET notes = notes WHERE id = 1 RETURNING id",
                        maximumRows: 1))
            }
            let result = try await client.executeRead(
                PostgreSQLDatabaseReadPlan(
                    sql: "SELECT 1::int8 AS value",
                    maximumRows: 1))
            #expect(result.rows.count == 1)
            _ = try await client.discoverIdentity()
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
        print("postgresql reading live read-only transaction verified sqlstate=25006 reuse=true")
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlReadingLiveBoundsResultsAndRedactsBoundFailures() async throws {
        let session = try await PostgreSQLDatabaseReadingLiveEnvironment.session()
        do {
            await #expect(throws: PostgreSQLDatabaseAdapterSupport.resultTooLarge) {
                _ = try await session.query(
                    PostgreSQLDatabaseReadingLiveEnvironment.query(
                        connectionID: session.connection.id,
                        command: "SELECT repeat('x', 1048577) AS value",
                        pageSize: 1),
                    context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            }
            #expect(await session.lifecycleState() == .connected)
            let marker = "postgresql-reading-secret-marker-7f82"
            do {
                _ = try await session.query(
                    PostgreSQLDatabaseReadingLiveEnvironment.query(
                        connectionID: session.connection.id,
                        command: "SELECT $1::int8 AS value",
                        parameters: [
                            DatabaseQueryParameter(value: .string(marker))
                        ],
                        pageSize: 1),
                    context: PostgreSQLDatabaseReadingLiveEnvironment.context())
                Issue.record("The invalid bound value unexpectedly succeeded.")
            } catch {
                #expect(!String(reflecting: error).contains(marker))
                let failure = try #require(error as? DatabaseAdapterFailure)
                #expect(
                    failure
                        == DatabaseAdapterFailure.reported(
                            DatabaseErrorEnvelope(
                                category: .server,
                                message: "PostgreSQL could not complete the requested operation.",
                                productCode: "postgresql.sqlstate.22P02",
                                retry: DatabaseRetryGuidance(action: .retry))))
            }
            let recovered = try await session.query(
                PostgreSQLDatabaseReadingLiveEnvironment.query(
                    connectionID: session.connection.id,
                    command: "SELECT 1::int8 AS value",
                    pageSize: 1),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context())
            #expect(recovered.records.count == 1)
        } catch {
            await session.disconnect()
            throw error
        }
        await session.disconnect()
        print("postgresql reading live bounds verified cellBytes=1048576 redaction=true reuse=true")
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlReadingLiveCancelsWithinBoundAndReconnects() async throws {
        let session = try await PostgreSQLDatabaseReadingLiveEnvironment.session(
            statementTimeoutMilliseconds: 10_000)
        let operationID = DatabaseOperationID()
        let task = Task {
            try await session.query(
                PostgreSQLDatabaseReadingLiveEnvironment.query(
                    connectionID: session.connection.id,
                    command: "SELECT pg_sleep(10) AS slept",
                    pageSize: 1),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context(
                    operationID: operationID,
                    deadline: Date().addingTimeInterval(10)))
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let startedAt = Date()
        let result = await session.cancel(operationID)
        #expect(result.disposition == .accepted)
        await #expect(throws: DatabaseAdapterFailure.cancelled) {
            _ = try await task.value
        }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        #expect(milliseconds < 2_000)
        #expect(await session.lifecycleState() == .failed)
        await session.disconnect()
        try await PostgreSQLDatabaseReadingLiveEnvironment.verifyReconnect()
        print(
            "postgresql reading live cancellation verified latencyMilliseconds=\(milliseconds) reconnect=true"
        )
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.isEnabled))
    func postgresqlReadingLiveDeadlineWithinBoundAndReconnects() async throws {
        let session = try await PostgreSQLDatabaseReadingLiveEnvironment.session(
            statementTimeoutMilliseconds: 10_000)
        let startedAt = Date()
        await #expect(throws: PostgreSQLDatabaseAdapterSupport.deadlineExceeded) {
            _ = try await session.query(
                PostgreSQLDatabaseReadingLiveEnvironment.query(
                    connectionID: session.connection.id,
                    command: "SELECT pg_sleep(10) AS slept",
                    pageSize: 1),
                context: PostgreSQLDatabaseReadingLiveEnvironment.context(
                    deadline: Date().addingTimeInterval(0.2)))
        }
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        #expect(milliseconds < 2_000)
        #expect(await session.lifecycleState() == .failed)
        await session.disconnect()
        try await PostgreSQLDatabaseReadingLiveEnvironment.verifyReconnect()
        print(
            "postgresql reading live deadline verified latencyMilliseconds=\(milliseconds) reconnect=true"
        )
    }

    @Test(.enabled(if: PostgreSQLDatabaseReadingLiveEnvironment.traversalIsEnabled))
    func postgresqlReadingLiveTraversesMillionRowsWithKeysets() async throws {
        let session = try await PostgreSQLDatabaseReadingLiveEnvironment.session(
            statementTimeoutMilliseconds: 30_000)
        let projection = DatabaseProjection(
            mode: .include,
            fields: [DatabaseProjectedField(path: DatabaseFieldPath("id"))])
        let startedAt = Date()
        var continuation: DatabaseAdapterContinuation?
        var expected: Int64 = 1
        var pageCount = 0
        var maximumPage = 0
        var maximumContinuationBytes = 0
        var checksum: Int64 = 0
        do {
            repeat {
                let page = try await session.readPage(
                    PostgreSQLDatabaseReadingLiveEnvironment.browse(
                        connectionID: session.connection.id,
                        relation: "orders",
                        pageSize: 100,
                        continuation: continuation,
                        projection: projection),
                    context: PostgreSQLDatabaseReadingLiveEnvironment.context(
                        deadline: Date().addingTimeInterval(30)))
                #expect(!page.records.isEmpty)
                #expect(page.records.count <= 100)
                maximumPage = max(maximumPage, page.records.count)
                for record in page.records {
                    let id = try PostgreSQLDatabaseReadingLiveEnvironment.signed("id", in: record)
                    #expect(id == expected)
                    #expect(record.identity?.components.first?.value == .signedInteger(id))
                    checksum += id
                    expected += 1
                }
                continuation = page.nextContinuation
                if let continuation {
                    #expect(continuation.mode == .keyset)
                    #expect(continuation.payload.count <= 1_024)
                    maximumContinuationBytes = max(
                        maximumContinuationBytes,
                        continuation.payload.count)
                }
                pageCount += 1
            } while continuation != nil
        } catch {
            await session.disconnect()
            throw error
        }
        #expect(expected == 1_000_001)
        #expect(pageCount == 10_000)
        #expect(maximumPage == 100)
        #expect(checksum == 500_000_500_000)
        await session.disconnect()
        try await PostgreSQLDatabaseReadingLiveEnvironment.verifyReconnect()
        let milliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        print(
            "postgresql reading live traversal verified records=1000000 pages=\(pageCount) first=1 last=1000000 checksum=\(checksum) maximumPage=\(maximumPage) maximumContinuationBytes=\(maximumContinuationBytes) durationMilliseconds=\(milliseconds) reconnect=true"
        )
    }
}
