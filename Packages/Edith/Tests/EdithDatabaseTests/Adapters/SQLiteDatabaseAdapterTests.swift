import Foundation
import GRDB
import Testing

@testable import EdithDatabase

private typealias SQLiteAdapterValue = EdithDatabase.DatabaseValue

private enum SQLiteDatabaseAdapterFixtures {
    static func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-sqlite-adapter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true)
        return directory
    }

    static func definition(
        product: DatabaseProduct = .sqlite,
        location: DatabaseConnectionLocation = .memory(name: nil),
        version: Int = DatabaseConnectionDefinition.schemaVersion,
        username: String? = nil,
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tunnel: DatabaseTunnelDefinition? = nil,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled,
        environmentProtection: DatabaseEnvironmentProtection = .standard,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            version: version,
            id: DatabaseConnectionID(),
            displayName: "SQLite fixture",
            productHint: product,
            location: location,
            username: username,
            namespaces: DatabaseNamespaceDefaults(),
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            tunnel: tunnel,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 2_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: readOnlyPolicy,
            productionPolicy: .standard,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: environmentProtection),
            options: options,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func resolved(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:]
    ) throws(DatabaseAdapterFailure) -> DatabaseResolvedConnection {
        try DatabaseResolvedConnection(
            definition: definition,
            secrets: secrets)
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

    static func connect(
        _ definition: DatabaseConnectionDefinition,
        secrets: [DatabaseSecretReference: Data] = [:],
        context: DatabaseAdapterOperationContext? = nil
    ) async throws(DatabaseAdapterFailure) -> any DatabaseAdapterSession {
        try await SQLiteDatabaseAdapter().connect(
            try resolved(definition, secrets: secrets),
            context: context ?? self.context())
    }

    static func createFile(
        at path: String,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled
    ) async throws {
        let definition = try definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)),
            readOnlyPolicy: readOnlyPolicy)
        let session = try await connect(definition)
        await session.disconnect()
    }

    static func target(
        connectionID: DatabaseConnectionID,
        path: [String] = ["main", "items"],
        kind: DatabaseObjectKind = .table
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: kind, path: path))
    }

    static func pageRequest(
        connectionID: DatabaseConnectionID,
        pageSize: Int = 10,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = [],
        consistency: DatabaseConsistencyPreference = .productDefault,
        path: [String] = ["main", "items"]
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target(connectionID: connectionID, path: path),
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(pageSize),
                projection: projection,
                filter: filter,
                sorts: sorts,
                consistency: consistency),
            continuation: continuation)
    }

    static func queryRequest(
        connectionID: DatabaseConnectionID,
        command: String = "SELECT 1",
        parameters: [DatabaseQueryParameter] = [],
        body: SQLiteAdapterValue? = nil,
        pageSize: Int = 10,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = [],
        consistency: DatabaseConsistencyPreference = .productDefault
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: target(connectionID: connectionID),
                language: .sql,
                command: command,
                parameters: parameters,
                body: body,
                page: DatabasePageRequest(
                    pageSize: try DatabasePageSize(pageSize),
                    projection: projection,
                    filter: filter,
                    sorts: sorts,
                    consistency: consistency)),
            continuation: continuation)
    }

    static func createFixture(at path: String, rowCount: Int = 5_000) throws {
        let databaseQueue = try DatabaseQueue(path: path)
        defer { try? databaseQueue.close() }
        try databaseQueue.writeWithoutTransaction { database in
            try database.execute(
                sql: """
                    CREATE TABLE items(
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL,
                        category TEXT,
                        score REAL NOT NULL,
                        payload BLOB,
                        optional_value TEXT
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE "quoted""table"(
                        "odd""column" TEXT NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE nullable_keys(
                        code TEXT PRIMARY KEY,
                        value TEXT NOT NULL
                    )
                    """)
            try database.execute(
                sql: """
                    CREATE TABLE shadowed_rowid_key(
                        "rowid" INTEGER PRIMARY KEY,
                        "_rowid_" TEXT,
                        "oid" TEXT
                    )
                    """)
            try database.execute(
                sql: """
                    INSERT INTO "quoted""table"("odd""column") VALUES (?)
                    """,
                arguments: ["quoted-value"])
            try database.execute(
                sql: """
                    INSERT INTO nullable_keys(code, value) VALUES
                        (NULL, 'first'),
                        (NULL, 'second')
                    """)
            try database.execute(
                sql: """
                    INSERT INTO shadowed_rowid_key("_rowid_", "oid")
                    VALUES ('shadow-one', 'shadow-two')
                    """)
            try database.inTransaction {
                let statement = try database.makeStatement(
                    sql: """
                        INSERT INTO items(
                            id, name, category, score, payload, optional_value
                        ) VALUES (?, ?, ?, ?, ?, ?)
                        """)
                for identifier in 1...rowCount {
                    try statement.execute(
                        arguments: [
                            identifier,
                            String(format: "item-%05d", identifier),
                            identifier.isMultiple(of: 2) ? "even" : "odd",
                            Double(identifier) / 10,
                            Data([UInt8(identifier % 251)]),
                            identifier.isMultiple(of: 3) ? nil : "present",
                        ])
                }
                return .commit
            }
        }
    }

    static func createLargePayloadFixture(at path: String) throws {
        let databaseQueue = try DatabaseQueue(path: path)
        defer { try? databaseQueue.close() }
        try databaseQueue.writeWithoutTransaction { database in
            try database.execute(
                sql: "CREATE TABLE payload_items(id INTEGER PRIMARY KEY, payload TEXT NOT NULL)")
            let payload = String(repeating: "x", count: 690_000)
            let statement = try database.makeStatement(
                sql: "INSERT INTO payload_items(id, payload) VALUES (?, ?)")
            for identifier in 1...5 {
                try statement.execute(arguments: [identifier, payload])
            }
        }
    }

    static func field(
        _ name: String,
        in record: DatabaseRecord
    ) -> SQLiteAdapterValue? {
        record.fields.first(where: { $0.name == name })?.value
    }

    static func destructiveRequest(
        connectionID: DatabaseConnectionID
    ) -> DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: target(connectionID: connectionID),
            payload: .relational(
                product: .sqlite,
                statement: "DELETE FROM items",
                parameters: []))
    }

    static func destructivePlan(
        connectionID: DatabaseConnectionID
    ) -> DatabaseDestructivePlan {
        DatabaseDestructivePlan(
            request: destructiveRequest(connectionID: connectionID),
            action: .deleteMany,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 0, accuracy: .unknown),
                description: "Unknown impact"),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous)
    }

    static func failure<Value>(
        _ operation: () async throws -> Value
    ) async -> DatabaseAdapterFailure? {
        do {
            _ = try await operation()
            return nil
        } catch let failure as DatabaseAdapterFailure {
            return failure
        } catch {
            Issue.record("Expected an adapter failure, received \(type(of: error))")
            return nil
        }
    }

    static func expectReported(
        _ failure: DatabaseAdapterFailure?,
        category: DatabaseErrorCategory,
        productCode: String
    ) {
        guard case let .reported(envelope) = failure else {
            Issue.record("Expected a reported adapter failure")
            return
        }
        #expect(envelope.category == category)
        #expect(envelope.productCode == productCode)
        #expect(envelope.target == nil)
        #expect(envelope.details.isEmpty)
    }
}

@Suite struct SQLiteDatabaseAdapterTests {
    @Test func connectsToIndependentAndNamedMemoryDatabases() async throws {
        let adapter = SQLiteDatabaseAdapter()
        #expect(adapter.id.rawValue == "sqlite")
        #expect(adapter.products == [.sqlite])

        let independentDefinition = try SQLiteDatabaseAdapterFixtures.definition()
        let independent = try await SQLiteDatabaseAdapterFixtures.connect(independentDefinition)
        #expect(await independent.lifecycleState() == .connected)
        #expect(independent.productIdentity.product == .sqlite)
        #expect(independent.productIdentity.distribution == "SQLite")
        #expect(independent.productIdentity.topology.kind == .embedded)
        #expect(independent.productIdentity.topology.nodeCount == 1)
        #expect(independent.productIdentity.version?.major != nil)
        #expect(independent.productIdentity.version?.minor != nil)
        #expect(independent.productIdentity.version?.patch != nil)

        let name = "memory_\(UUID().uuidString.replacingOccurrences(of: "-", with: "_"))"
        let namedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .memory(name: name))
        let named = try await SQLiteDatabaseAdapterFixtures.connect(namedDefinition)
        #expect(await named.lifecycleState() == .connected)
        #expect(named.productIdentity == independent.productIdentity)

        let protectedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .memory(name: nil),
            readOnlyPolicy: .required)
        let protectedValue = try await SQLiteDatabaseAdapterFixtures.connect(protectedDefinition)
        let protected = try #require(protectedValue as? SQLiteDatabaseAdapterSession)
        #expect(await protected.readOnlyEnforcementIsActive())
        _ = try await protected.discoverCapabilities(
            context: SQLiteDatabaseAdapterFixtures.context())
        _ = try await protected.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: protectedDefinition.id),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(await protected.readOnlyEnforcementIsActive())

        await independent.disconnect()
        await named.disconnect()
        await protected.disconnect()
    }

    @Test func honorsFileAccessModesAndReadOnlyPolicies() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("database file.sqlite").path

        let createDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)))
        let created = try await SQLiteDatabaseAdapterFixtures.connect(createDefinition)
        let createdSession = try #require(created as? SQLiteDatabaseAdapterSession)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(await createdSession.resourceIsOpen())
        #expect(!(await createdSession.readOnlyEnforcementIsActive()))
        await created.disconnect()

        let readWriteDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readWrite)))
        let readWrite = try await SQLiteDatabaseAdapterFixtures.connect(readWriteDefinition)
        let readWriteSession = try #require(readWrite as? SQLiteDatabaseAdapterSession)
        #expect(!(await readWriteSession.readOnlyEnforcementIsActive()))
        await readWrite.disconnect()

        let readOnlyDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readOnly)))
        let readOnly = try await SQLiteDatabaseAdapterFixtures.connect(readOnlyDefinition)
        let readOnlySession = try #require(readOnly as? SQLiteDatabaseAdapterSession)
        #expect(await readOnlySession.readOnlyEnforcementIsActive())
        await readOnly.disconnect()

        let policyDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .readWrite)),
            readOnlyPolicy: .preferred)
        let policySessionValue = try await SQLiteDatabaseAdapterFixtures.connect(policyDefinition)
        let policySession = try #require(
            policySessionValue as? SQLiteDatabaseAdapterSession)
        #expect(await policySession.readOnlyEnforcementIsActive())
        await policySession.disconnect()

        let protectedPath = directory.appendingPathComponent("protected.sqlite").path
        let protectedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: protectedPath,
                    accessMode: .createIfMissing)),
            environmentProtection: .readOnly)
        let protectedValue = try await SQLiteDatabaseAdapterFixtures.connect(protectedDefinition)
        let protectedSession = try #require(
            protectedValue as? SQLiteDatabaseAdapterSession)
        #expect(await protectedSession.readOnlyEnforcementIsActive())
        await protectedSession.disconnect()
    }

    @Test func readWriteAndReadOnlyNeverCreateMissingFiles() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        for mode in [DatabaseSQLiteAccessMode.readWrite, .readOnly] {
            let path = directory.appendingPathComponent("missing-\(mode.rawValue).sqlite").path
            let definition = try SQLiteDatabaseAdapterFixtures.definition(
                location: .sqlite(
                    DatabaseSQLiteLocation(path: path, accessMode: mode)))
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }

            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .connectionFailed,
                productCode: "sqlite.open_failed")
            #expect(!FileManager.default.fileExists(atPath: path))
        }
        #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path)).isEmpty)
    }

    @Test func browsesLargeFixtureWithProjectionFilterSortAndContinuation() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("large.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(path: path, accessMode: .readOnly)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)

        let projection = DatabaseProjection(
            mode: .include,
            fields: [
                DatabaseProjectedField(
                    path: DatabaseFieldPath("id"),
                    alias: "record_id"),
                DatabaseProjectedField(path: DatabaseFieldPath("name")),
                DatabaseProjectedField(path: DatabaseFieldPath("score")),
            ])
        let filter = DatabaseFilter.all([
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("category"),
                    operation: .equal,
                    values: [.string("even")])),
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("name"),
                    operation: .contains,
                    values: [.string("item-")],
                    caseSensitivity: .sensitive)),
            .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("score"),
                    operation: .greaterThan,
                    values: [.floatingPoint(100)])),
        ])
        let sorts = [
            DatabaseSort(
                field: DatabaseFieldPath("score"),
                direction: .descending,
                nullPlacement: .last)
        ]
        var continuation: DatabaseAdapterContinuation?
        var identifiers: [Int64] = []
        var pageCount = 0
        repeat {
            let request = try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 137,
                continuation: continuation,
                projection: projection,
                filter: filter,
                sorts: sorts)
            let page = try await session.readPage(
                request,
                context: SQLiteDatabaseAdapterFixtures.context())
            #expect(page.records.count <= 137)
            #expect(page.fields.map(\.displayName) == ["record_id", "name", "score"])
            for record in page.records {
                guard
                    case let .signedInteger(identifier)? =
                        SQLiteDatabaseAdapterFixtures.field("record_id", in: record)
                else {
                    Issue.record("Expected an integer record identifier")
                    continue
                }
                identifiers.append(identifier)
                #expect(record.identity?.kind == .primaryKey)
                #expect(record.identity?.components.first?.name == "id")
                #expect(record.identity?.components.first?.value == .signedInteger(identifier))
            }
            continuation = page.nextContinuation
            pageCount += 1
            if continuation == nil {
                #expect(page.metadata.completeness.state == .complete)
                #expect(page.metadata.count.value == 2_000)
                #expect(page.metadata.count.accuracy == .exact)
            } else {
                #expect(continuation?.mode == .offset)
                #expect(page.metadata.completeness.state == .partial)
                #expect(page.metadata.count.accuracy == .lowerBound)
            }
        } while continuation != nil

        #expect(pageCount == 15)
        #expect(identifiers.count == 2_000)
        #expect(identifiers.first == 5_000)
        #expect(identifiers.last == 1_002)
        #expect(Set(identifiers).count == identifiers.count)
        #expect(identifiers == identifiers.sorted(by: >))
        await session.disconnect()
    }

    @Test func usesStableIdentitiesForNullableAndShadowedRowIDPrimaryKeys() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("identities.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path, rowCount: 1)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)

        let first = try await session.readPage(
            try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 1,
                path: ["main", "nullable_keys"]),
            context: SQLiteDatabaseAdapterFixtures.context())
        let second = try await session.readPage(
            try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 1,
                continuation: first.nextContinuation,
                path: ["main", "nullable_keys"]),
            context: SQLiteDatabaseAdapterFixtures.context())
        let firstIdentity = try #require(first.records.first?.identity)
        let secondIdentity = try #require(second.records.first?.identity)
        #expect(firstIdentity.kind == .rowID)
        #expect(secondIdentity.kind == .rowID)
        #expect(firstIdentity != secondIdentity)
        #expect(first.fields.first(where: { $0.displayName == "code" })?.isNullable == true)

        let shadowed = try await session.readPage(
            try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 1,
                path: ["main", "shadowed_rowid_key"]),
            context: SQLiteDatabaseAdapterFixtures.context())
        let shadowedIdentity = try #require(shadowed.records.first?.identity)
        #expect(shadowedIdentity.kind == .primaryKey)
        #expect(shadowedIdentity.components.first?.name == "rowid")
        #expect(shadowedIdentity.components.first?.value == .signedInteger(1))
        #expect(shadowed.fields.first(where: { $0.displayName == "rowid" })?.isNullable == false)
        await session.disconnect()
    }

    @Test func pageByteBudgetReturnsShorterContinuablePages() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("page-budget.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createLargePayloadFixture(at: path)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)

        let first = try await session.readPage(
            try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 5,
                path: ["main", "payload_items"]),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(first.records.count == 3)
        #expect(first.nextContinuation != nil)
        #expect(first.metadata.completeness.state == .partial)

        let second = try await session.readPage(
            try SQLiteDatabaseAdapterFixtures.pageRequest(
                connectionID: definition.id,
                pageSize: 5,
                continuation: first.nextContinuation,
                path: ["main", "payload_items"]),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(second.records.count == 2)
        #expect(second.nextContinuation == nil)
        #expect(second.metadata.completeness.state == .complete)
        await session.disconnect()
    }

    @Test func quotesTableAndColumnIdentifiersWithoutExecutingInjectedText() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("quoted.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path, rowCount: 10)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)

        let projection = DatabaseProjection(
            mode: .include,
            fields: [
                DatabaseProjectedField(path: DatabaseFieldPath("odd\"column"))
            ])
        let request = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: definition.id,
            projection: projection,
            path: ["main", "quoted\"table"])
        let page = try await session.readPage(
            request,
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(page.records.count == 1)
        #expect(
            SQLiteDatabaseAdapterFixtures.field("odd\"column", in: page.records[0])
                == .string("quoted-value"))
        let unicode = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT 'upper' AS \"Ä\", 'lower' AS \"ä\""),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(unicode.fields.map(\.displayName) == ["Ä", "ä"])

        let injected = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: definition.id,
            path: ["main", "items\"; DELETE FROM items; SELECT \""])
        let failure = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.readPage(
                injected,
                context: SQLiteDatabaseAdapterFixtures.context())
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            failure,
            category: .invalidRequest,
            productCode: "sqlite.read.invalid")

        let count = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT COUNT(*) AS count FROM items"),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("count", in: count.records[0])
                == .signedInteger(10))
        await session.disconnect()
    }

    @Test func runsParameterizedQueriesWithOuterProjectionFilterAndSort() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("query.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let projection = DatabaseProjection(
            mode: .include,
            fields: [
                DatabaseProjectedField(path: DatabaseFieldPath("id"), alias: "record_id"),
                DatabaseProjectedField(path: DatabaseFieldPath("name")),
            ])
        let filter = DatabaseFilter.predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("name"),
                operation: .startsWith,
                values: [.string("item-")],
                caseSensitivity: .sensitive))
        let sorts = [
            DatabaseSort(
                field: DatabaseFieldPath("id"),
                direction: .descending)
        ]
        let firstRequest = try SQLiteDatabaseAdapterFixtures.queryRequest(
            connectionID: definition.id,
            command: "SELECT id, name, score FROM items WHERE id > ? AND id <= ?",
            parameters: [
                DatabaseQueryParameter(value: .signedInteger(100)),
                DatabaseQueryParameter(value: .signedInteger(350)),
            ],
            pageSize: 60,
            projection: projection,
            filter: filter,
            sorts: sorts)
        let first = try await session.query(
            firstRequest,
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(first.records.count == 60)
        #expect(first.nextContinuation == nil)
        #expect(first.metadata.completeness.state == .truncated)
        #expect(
            SQLiteDatabaseAdapterFixtures.field("record_id", in: first.records[0])
                == .signedInteger(350))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("record_id", in: first.records[59])
                == .signedInteger(291))

        let injection = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT id FROM items WHERE name = :name",
                parameters: [
                    DatabaseQueryParameter(
                        name: "name",
                        value: .string("item-00001' OR 1 = 1"))
                ],
                sorts: [
                    DatabaseSort(
                        field: DatabaseFieldPath("id"),
                        direction: .ascending)
                ]),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(injection.records.isEmpty)
        await session.disconnect()
    }

    @Test func convertsSQLiteStorageClassesAndBoundParametersDeterministically() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let identifier = UUID(uuidString: "12345678-1234-5678-1234-567812345678")!
        let request = try SQLiteDatabaseAdapterFixtures.queryRequest(
            connectionID: definition.id,
            command: """
                SELECT
                    :integer_value AS integer_value,
                    :boolean_value AS boolean_value,
                    :text_value AS text_value,
                    :blob_value AS blob_value,
                    :null_value AS null_value,
                    1.25 AS floating_value,
                    :decimal_value AS decimal_value,
                    :date_value AS date_value,
                    :uuid_value AS uuid_value
                """,
            parameters: [
                DatabaseQueryParameter(name: "integer_value", value: .signedInteger(-7)),
                DatabaseQueryParameter(name: "boolean_value", value: .boolean(true)),
                DatabaseQueryParameter(name: "text_value", value: .string("text")),
                DatabaseQueryParameter(
                    name: "blob_value",
                    value: .binary(
                        .complete(data: Data([0, 1, 255]), mediaType: nil, digest: nil))),
                DatabaseQueryParameter(name: "null_value", value: .null),
                DatabaseQueryParameter(
                    name: "decimal_value",
                    value: .decimal("1234567890.0123456789")),
                DatabaseQueryParameter(
                    name: "date_value",
                    value: .date(DatabaseDateValue(text: "2026-08-30"))),
                DatabaseQueryParameter(name: "uuid_value", value: .uuid(identifier)),
            ])
        let page = try await session.query(
            request,
            context: SQLiteDatabaseAdapterFixtures.context())
        let record = try #require(page.records.first)

        #expect(
            SQLiteDatabaseAdapterFixtures.field("integer_value", in: record) == .signedInteger(-7))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("boolean_value", in: record) == .signedInteger(1))
        #expect(SQLiteDatabaseAdapterFixtures.field("text_value", in: record) == .string("text"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("blob_value", in: record)
                == .binary(
                    .complete(data: Data([0, 1, 255]), mediaType: nil, digest: nil)))
        #expect(SQLiteDatabaseAdapterFixtures.field("null_value", in: record) == .null)
        #expect(
            SQLiteDatabaseAdapterFixtures.field("floating_value", in: record)
                == .floatingPoint(1.25))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("decimal_value", in: record)
                == .string("1234567890.0123456789"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("date_value", in: record)
                == .string("2026-08-30"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("uuid_value", in: record)
                == .string(identifier.uuidString.lowercased()))
        await session.disconnect()
    }

    @Test func rawQueriesFailClosedWithoutDatabaseSideEffects() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("fail-closed.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path, rowCount: 20)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(path: path, accessMode: .readWrite)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let rejectedCommands = [
            "INSERT INTO items(id, name, score) VALUES (100, 'inserted', 1)",
            "UPDATE items SET name = 'updated' WHERE id = 1",
            "DELETE FROM items WHERE id = 1",
            "CREATE TABLE injected(value TEXT)",
            "DROP TABLE items",
            "WITH chosen AS (SELECT 1) DELETE FROM items WHERE id = 1 RETURNING id",
            "UPDATE items SET name = 'returned' WHERE id = 1 RETURNING id",
            "PRAGMA user_version = 9",
            "PRAGMA table_info(items)",
            "SELECT * FROM pragma_table_info('items')",
            "SELECT * FROM \"pragma_table_info\"('items')",
            "SELECT * FROM 'pragma_table_info'('items')",
            "SELECT * FROM 'pragma_database_list'",
            "SELECT * FROM main.'pragma_database_list'",
            "SELECT * FROM ('pragma_database_list')",
            "SELECT * FROM items, 'pragma_database_list'",
            "SELECT * FROM (items, 'pragma_database_list')",
            "SELECT * FROM items JOIN 'pragma_database_list'",
            "SELECT load_extension('/tmp/not-loaded')",
            "SELECT \"load_extension\"('/tmp/not-loaded')",
            "SELECT `load_extension`('/tmp/not-loaded')",
            "SELECT [load_extension]('/tmp/not-loaded')",
            "ATTACH DATABASE ':memory:' AS attached",
            "DETACH DATABASE attached",
            "VACUUM",
            "BEGIN",
            "COMMIT",
            "ROLLBACK",
            "SAVEPOINT query_savepoint",
            "RELEASE query_savepoint",
            "SELECT 1; DELETE FROM items WHERE id = 1",
            "SELECT 1; /* harmless-looking tail */ UPDATE items SET name = 'tail'",
            "/* SELECT 1 */ DELETE FROM items WHERE id = 1",
        ]
        for command in rejectedCommands {
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await session.query(
                    try SQLiteDatabaseAdapterFixtures.queryRequest(
                        connectionID: definition.id,
                        command: command),
                    context: SQLiteDatabaseAdapterFixtures.context())
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.query.invalid")
        }

        let quotedSemicolon = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT '; still one statement' AS value /* ; DELETE */"),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("value", in: quotedSemicolon.records[0])
                == .string("; still one statement"))
        let commented = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "/* leading comment */ SELECT 1 AS value -- trailing comment"),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("value", in: commented.records[0])
                == .signedInteger(1))
        let expressions = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: """
                    SELECT
                        CASE WHEN id = 1 THEN 'yes' ELSE 'no' END AS decision,
                        replace(name, 'item', 'row') AS renamed
                    FROM items WHERE id = 1
                    """),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("decision", in: expressions.records[0])
                == .string("yes"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("renamed", in: expressions.records[0])
                == .string("row-00001"))
        let harmlessNames = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: """
                    SELECT
                        'load_extension' AS function_name,
                        'pragma_table_info' AS pragma_name,
                        (SELECT COUNT(*) FROM items WHERE name = 'writefile') AS matches,
                        (SELECT value FROM (
                            SELECT 'pragma_table_info' AS value
                        )) AS nested_literal
                    """),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("function_name", in: harmlessNames.records[0])
                == .string("load_extension"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("pragma_name", in: harmlessNames.records[0])
                == .string("pragma_table_info"))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("matches", in: harmlessNames.records[0])
                == .signedInteger(0))
        #expect(
            SQLiteDatabaseAdapterFixtures.field("nested_literal", in: harmlessNames.records[0])
                == .string("pragma_table_info"))
        let oversized = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.query(
                try SQLiteDatabaseAdapterFixtures.queryRequest(
                    connectionID: definition.id,
                    command: "SELECT randomblob(20000000) AS payload"),
                context: SQLiteDatabaseAdapterFixtures.context())
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            oversized,
            category: .resourceLimit,
            productCode: "sqlite.result.too_large")
        let count = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT COUNT(*) AS count FROM items"),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("count", in: count.records[0])
                == .signedInteger(20))
        let names = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT name FROM items WHERE id = 1"),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(
            SQLiteDatabaseAdapterFixtures.field("name", in: names.records[0])
                == .string("item-00001"))
        await session.disconnect()
        let verificationQueue = try DatabaseQueue(path: path)
        let verification = try await verificationQueue.read { database in
            (
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM items"),
                try String.fetchOne(database, sql: "SELECT name FROM items WHERE id = 1"),
                try Int.fetchOne(database, sql: "PRAGMA user_version"),
                try database.tableExists("injected")
            )
        }
        try verificationQueue.close()
        #expect(verification.0 == 20)
        #expect(verification.1 == "item-00001")
        #expect(verification.2 == 0)
        #expect(!verification.3)
    }

    @Test func unsortedQueryResultsAreBoundedWithoutUnstableContinuation() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("bounded.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path, rowCount: 500)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let page = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT id, name FROM items",
                pageSize: 25),
            context: SQLiteDatabaseAdapterFixtures.context())

        #expect(page.records.count == 25)
        #expect(page.nextContinuation == nil)
        #expect(page.metadata.completeness.state == .truncated)
        #expect(page.metadata.count.value == 25)
        #expect(page.metadata.count.accuracy == .lowerBound)

        let collated = try await session.query(
            try SQLiteDatabaseAdapterFixtures.queryRequest(
                connectionID: definition.id,
                command: "SELECT name COLLATE NOCASE AS name FROM items",
                pageSize: 1,
                sorts: [
                    DatabaseSort(
                        field: DatabaseFieldPath("name"),
                        direction: .ascending)
                ]),
            context: SQLiteDatabaseAdapterFixtures.context())
        #expect(collated.records.count == 1)
        #expect(collated.nextContinuation == nil)
        #expect(collated.metadata.completeness.state == .truncated)
        await session.disconnect()
    }

    @Test func rejectsConsistencyThatOffsetPagingCannotHonor() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("consistency.sqlite").path
        try SQLiteDatabaseAdapterFixtures.createFixture(at: path, rowCount: 10)
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)

        for consistency in [
            DatabaseConsistencyPreference.session,
            .snapshot,
            .strong,
        ] {
            let browseFailure = await SQLiteDatabaseAdapterFixtures.failure {
                try await session.readPage(
                    try SQLiteDatabaseAdapterFixtures.pageRequest(
                        connectionID: definition.id,
                        consistency: consistency),
                    context: SQLiteDatabaseAdapterFixtures.context())
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                browseFailure,
                category: .invalidRequest,
                productCode: "sqlite.read.invalid")
            let queryFailure = await SQLiteDatabaseAdapterFixtures.failure {
                try await session.query(
                    try SQLiteDatabaseAdapterFixtures.queryRequest(
                        connectionID: definition.id,
                        consistency: consistency),
                    context: SQLiteDatabaseAdapterFixtures.context())
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                queryFailure,
                category: .invalidRequest,
                productCode: "sqlite.query.invalid")
        }
        await session.disconnect()
    }

    @Test func interruptsActiveQueriesForCancellationAndDeadline() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let command = """
            WITH RECURSIVE sequence(value) AS (
                VALUES(0)
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 100000000
            )
            SELECT sum(value) AS total FROM sequence
            """

        let operationID = DatabaseOperationID()
        let cancellation = DatabaseAdapterCancellationSignal()
        let cancellationContext = SQLiteDatabaseAdapterFixtures.context(
            operationID: operationID,
            cancellation: cancellation)
        let cancellationTask = Task {
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.query(
                    try SQLiteDatabaseAdapterFixtures.queryRequest(
                        connectionID: definition.id,
                        command: command),
                    context: cancellationContext)
            }
        }
        try await Task.sleep(nanoseconds: 10_000_000)
        let cancellationResult = await session.cancel(operationID)
        #expect(cancellationResult.support == .cooperative)
        #expect(cancellationResult.disposition == .accepted)
        let cancellationFailure = await cancellationTask.value
        #expect(cancellationFailure == DatabaseAdapterFailure.cancelled)

        let precedenceSignal = DatabaseAdapterCancellationSignal()
        await precedenceSignal.cancel(.userRequested)
        let precedenceFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.query(
                try SQLiteDatabaseAdapterFixtures.queryRequest(
                    connectionID: definition.id,
                    command: "SELECT 1"),
                context: SQLiteDatabaseAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: -1),
                    cancellation: precedenceSignal))
        }
        #expect(precedenceFailure == DatabaseAdapterFailure.cancelled)

        let deadlineFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.query(
                try SQLiteDatabaseAdapterFixtures.queryRequest(
                    connectionID: definition.id,
                    command: command),
                context: SQLiteDatabaseAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: 0.01)))
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            deadlineFailure,
            category: .timeout,
            productCode: "sqlite.deadline_exceeded")
        await session.disconnect()
    }

    @Test func cancellationHandoffDoesNotInterruptTheSuccessor() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let longCommand = """
            WITH RECURSIVE sequence(value) AS (
                VALUES(0)
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 100000000
            )
            SELECT sum(value) AS total FROM sequence
            """
        let successorCommand = """
            WITH RECURSIVE sequence(value) AS (
                VALUES(0)
                UNION ALL
                SELECT value + 1 FROM sequence WHERE value < 200000
            )
            SELECT sum(value) AS total FROM sequence
            """

        for _ in 0..<8 {
            let operationID = DatabaseOperationID()
            let cancellation = DatabaseAdapterCancellationSignal()
            let first = Task {
                await SQLiteDatabaseAdapterFixtures.failure {
                    try await session.query(
                        try SQLiteDatabaseAdapterFixtures.queryRequest(
                            connectionID: definition.id,
                            command: longCommand),
                        context: SQLiteDatabaseAdapterFixtures.context(
                            operationID: operationID,
                            cancellation: cancellation))
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
            let cancellationTask = Task {
                await session.cancel(operationID)
            }
            #expect(await first.value == .cancelled)

            let successor = try await session.query(
                try SQLiteDatabaseAdapterFixtures.queryRequest(
                    connectionID: definition.id,
                    command: successorCommand),
                context: SQLiteDatabaseAdapterFixtures.context())
            #expect(
                SQLiteDatabaseAdapterFixtures.field("total", in: successor.records[0])
                    == .signedInteger(20_000_100_000))
            #expect(await cancellationTask.value.disposition == .accepted)
        }
        await session.disconnect()
    }

    @Test func rejectsUnsafeFileLocationsAndBookmarks() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.sqlite")
        try await SQLiteDatabaseAdapterFixtures.createFile(at: target.path)
        let symbolicLink = directory.appendingPathComponent("linked.sqlite")
        try FileManager.default.createSymbolicLink(
            at: symbolicLink,
            withDestinationURL: target)

        let bookmark = DatabaseResourceReference(
            identifier: UUID(),
            kind: .sqliteBookmark)
        let invalidLocations: [DatabaseConnectionLocation] = [
            .sqlite(DatabaseSQLiteLocation(path: "relative.sqlite")),
            .sqlite(DatabaseSQLiteLocation(path: directory.path)),
            .sqlite(
                DatabaseSQLiteLocation(
                    path: directory.appendingPathComponent("missing/child.sqlite").path,
                    accessMode: .createIfMissing)),
            .sqlite(DatabaseSQLiteLocation(path: symbolicLink.path)),
        ]

        for location in invalidLocations {
            let definition = try SQLiteDatabaseAdapterFixtures.definition(location: location)
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }

        let bookmarkedDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: target.path,
                    fileReference: bookmark)))
        let bookmarkFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(bookmarkedDefinition)
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            bookmarkFailure,
            category: .unsupported,
            productCode: "sqlite.file_bookmark.unavailable")
    }

    @Test func rejectsNonSQLiteAndUnsupportedSecurityConfiguration() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("database.sqlite").path
        try await SQLiteDatabaseAdapterFixtures.createFile(at: path)
        let location = DatabaseConnectionLocation.sqlite(
            DatabaseSQLiteLocation(path: path))
        let secretReference = DatabaseSecretReference(
            identifier: UUID(),
            purpose: .password)
        let endpoint = DatabaseNetworkEndpoint(
            host: "127.0.0.1",
            port: try DatabasePort(5_432))

        let invalidDefinitions = try [
            SQLiteDatabaseAdapterFixtures.definition(
                product: .postgresql,
                location: location),
            SQLiteDatabaseAdapterFixtures.definition(
                location: .network([endpoint])),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                version: DatabaseConnectionDefinition.schemaVersion + 1),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                username: "local-user"),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                deploymentMode: .standalone),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                authentication: DatabaseAuthentication(
                    kind: .password,
                    secretReferences: [secretReference])),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                tls: DatabaseTLSConfiguration(
                    mode: .required,
                    verification: .full,
                    serverName: "localhost")),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                tunnel: DatabaseTunnelDefinition(
                    machineIdentifier: "machine",
                    remoteEndpoint: endpoint)),
            SQLiteDatabaseAdapterFixtures.definition(
                location: location,
                options: [
                    DatabaseNonSecretOption(
                        name: "unknown",
                        value: .boolean(true))
                ]),
        ]

        for definition in invalidDefinitions {
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }

        let secretDefinition = try SQLiteDatabaseAdapterFixtures.definition(location: location)
        let secretFailure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                secretDefinition,
                secrets: [secretReference: Data("private-value".utf8)])
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            secretFailure,
            category: .invalidRequest,
            productCode: "sqlite.connection.invalid")
    }

    @Test func rejectsUnsafeNamedMemoryIdentifiers() async throws {
        for name in ["", "name?mode=memory", "name/child", String(repeating: "a", count: 129)] {
            let definition = try SQLiteDatabaseAdapterFixtures.definition(
                location: .memory(name: name))
            let failure = await SQLiteDatabaseAdapterFixtures.failure {
                try await SQLiteDatabaseAdapterFixtures.connect(definition)
            }
            SQLiteDatabaseAdapterFixtures.expectReported(
                failure,
                category: .invalidRequest,
                productCode: "sqlite.connection.invalid")
        }
    }

    @Test func reportsOnlyImplementedCapabilities() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let report = try await session.discoverCapabilities(
            context: SQLiteDatabaseAdapterFixtures.context())
        let expectedUnavailable: Set<DatabaseCapabilityID> = [
            .objectDiscovery,
            .objectDescription,
            .explain,
            .insert,
            .update,
            .delete,
            .bulkMutation,
            .importData,
            .exportData,
            .transactions,
            .schemaMutation,
            .monitoring,
            .administration,
        ]

        #expect(report.productIdentity == session.productIdentity)
        #expect(report.status(for: .connectionTest)?.availability == .available)
        #expect(report.status(for: .browse)?.availability == .available)
        #expect(report.status(for: .query)?.availability == .available)
        #expect(report.status(for: .queryCancellation)?.availability == .available)
        #expect(report.capabilities.count == expectedUnavailable.count + 4)
        for identifier in expectedUnavailable {
            let status = report.status(for: identifier)
            #expect(status?.availability == .unavailable)
            #expect(status?.reason?.category == .notImplemented)
            #expect(status?.isAvailable == false)
        }
        #expect(report.pagingModes == [.offset])
        #expect(report.mutationModes == [.unsupported])
        #expect(report.transactionModes == [.none])
        #expect(report.cancellationModes == [.cooperative])
        #expect(report.importFormats.isEmpty)
        #expect(report.exportFormats.isEmpty)
        #expect(report.explainModes.isEmpty)

        await session.disconnect()
    }

    @Test func unsupportedOperationsUseOneStableRedactedFailure() async throws {
        let definition = try SQLiteDatabaseAdapterFixtures.definition()
        let session = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let destructiveRequest = SQLiteDatabaseAdapterFixtures.destructiveRequest(
            connectionID: definition.id)
        let destructivePlan = SQLiteDatabaseAdapterFixtures.destructivePlan(
            connectionID: definition.id)
        let page = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: definition.id)
        let stream = DatabaseAdapterStreamRequest(source: .browse(page))
        let context = SQLiteDatabaseAdapterFixtures.context()

        let failures = [
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.normalizeMutation(destructiveRequest, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.executeMutation(destructivePlan, context: context)
            },
            await SQLiteDatabaseAdapterFixtures.failure {
                try await session.openStream(stream, context: context)
            },
        ]
        let expected = DatabaseAdapterFailure.reported(
            DatabaseErrorEnvelope(
                category: .unsupported,
                message: "The requested SQLite capability is unavailable.",
                productCode: "sqlite.capability.not_implemented",
                retry: DatabaseRetryGuidance(action: .none)))

        #expect(failures.allSatisfy { $0 == expected })
        let cancellation = await session.cancel(DatabaseOperationID())
        #expect(cancellation.support == .cooperative)
        #expect(cancellation.disposition == .alreadyFinished)

        await session.disconnect()
    }

    @Test func observesCancellationAndDeadlinesBeforeOpeningOrExecuting() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let cancelledPath = directory.appendingPathComponent("cancelled.sqlite").path
        let cancelledDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: cancelledPath,
                    accessMode: .createIfMissing)))
        let cancellation = DatabaseAdapterCancellationSignal()
        await cancellation.cancel(.userRequested)
        let cancelledContext = SQLiteDatabaseAdapterFixtures.context(
            cancellation: cancellation)
        let connectCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                cancelledDefinition,
                context: cancelledContext)
        }
        #expect(connectCancellation == .cancelled)
        #expect(!FileManager.default.fileExists(atPath: cancelledPath))

        let deadlinePath = directory.appendingPathComponent("deadline.sqlite").path
        let deadlineDefinition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: deadlinePath,
                    accessMode: .createIfMissing)))
        let expiredContext = SQLiteDatabaseAdapterFixtures.context(
            deadline: Date(timeIntervalSinceNow: -1))
        let connectDeadline = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(
                deadlineDefinition,
                context: expiredContext)
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            connectDeadline,
            category: .timeout,
            productCode: "sqlite.deadline_exceeded")
        #expect(!FileManager.default.fileExists(atPath: deadlinePath))

        let session = try await SQLiteDatabaseAdapterFixtures.connect(
            try SQLiteDatabaseAdapterFixtures.definition())
        let operationCancellation = DatabaseAdapterCancellationSignal()
        await operationCancellation.cancel(.userRequested)
        let discoveryCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context(
                    cancellation: operationCancellation))
        }
        #expect(discoveryCancellation == .cancelled)

        let discoveryDeadline = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context(
                    deadline: Date(timeIntervalSinceNow: -1)))
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            discoveryDeadline,
            category: .timeout,
            productCode: "sqlite.deadline_exceeded")

        let page = try SQLiteDatabaseAdapterFixtures.pageRequest(
            connectionID: session.connection.id)
        let unsupportedCancellation = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.readPage(
                page,
                context: SQLiteDatabaseAdapterFixtures.context(
                    cancellation: operationCancellation))
        }
        #expect(unsupportedCancellation == .cancelled)

        await session.disconnect()
    }

    @Test func disconnectIsIdempotentAndReleasesTheDatabase() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("release.sqlite").path
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(
                DatabaseSQLiteLocation(
                    path: path,
                    accessMode: .createIfMissing)))
        let sessionValue = try await SQLiteDatabaseAdapterFixtures.connect(definition)
        let session = try #require(sessionValue as? SQLiteDatabaseAdapterSession)

        #expect(await session.lifecycleState() == .connected)
        #expect(await session.resourceIsOpen())
        await session.disconnect()
        #expect(await session.lifecycleState() == .disconnected)
        #expect(!(await session.resourceIsOpen()))
        await session.disconnect()
        #expect(await session.lifecycleState() == .disconnected)

        let failure = await SQLiteDatabaseAdapterFixtures.failure {
            try await session.discoverCapabilities(
                context: SQLiteDatabaseAdapterFixtures.context())
        }
        SQLiteDatabaseAdapterFixtures.expectReported(
            failure,
            category: .connectionFailed,
            productCode: "sqlite.session.disconnected")

        try FileManager.default.removeItem(atPath: path)
        #expect(!FileManager.default.fileExists(atPath: path))
    }

    @Test func corruptDatabaseErrorsDoNotExposePathOrContents() async throws {
        let directory = try SQLiteDatabaseAdapterFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = "private-database-marker"
        let path = directory.appendingPathComponent("\(secret).sqlite").path
        try Data(secret.utf8).write(to: URL(fileURLWithPath: path))
        let definition = try SQLiteDatabaseAdapterFixtures.definition(
            location: .sqlite(DatabaseSQLiteLocation(path: path)))
        let failure = await SQLiteDatabaseAdapterFixtures.failure {
            try await SQLiteDatabaseAdapterFixtures.connect(definition)
        }

        SQLiteDatabaseAdapterFixtures.expectReported(
            failure,
            category: .connectionFailed,
            productCode: "sqlite.open_failed")
        guard case let .reported(envelope) = failure else { return }
        #expect(!envelope.message.contains(secret))
        #expect(!envelope.message.contains(path))
    }
}
