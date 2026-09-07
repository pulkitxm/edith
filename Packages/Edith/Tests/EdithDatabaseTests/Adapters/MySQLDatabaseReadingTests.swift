import Foundation
import Testing

@testable import EdithDatabase

private enum MySQLDatabaseReadingFixtures {
    static func pageRequest(
        connectionID: DatabaseConnectionID,
        object: DatabaseObjectIdentifier? = nil,
        size: Int = 100,
        continuation: DatabaseAdapterContinuation? = nil
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: DatabaseTargetIdentifier(connectionID: connectionID, object: object),
            page: DatabasePageRequest(
                pageSize: DatabasePageSize(size),
                consistency: .bestEffort),
            continuation: continuation)
    }

    static func queryRequest(
        connectionID: DatabaseConnectionID,
        command: String,
        size: Int = 2
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: DatabaseTargetIdentifier(connectionID: connectionID),
                language: .sql,
                command: command,
                page: DatabasePageRequest(
                    pageSize: DatabasePageSize(size),
                    consistency: .bestEffort)),
            continuation: nil)
    }

    static func result(
        _ columns: [(String, String, Bool, Bool)],
        _ rows: [[DatabaseValue]]
    ) -> MySQLDatabaseReadResult {
        MySQLDatabaseReadResult(
            columns: columns.map { name, type, nullable, primaryKey in
                MySQLDatabaseReadColumn(
                    name: name,
                    typeName: type,
                    isNullable: nullable,
                    isPrimaryKey: primaryKey)
            },
            rows: rows.map(MySQLDatabaseReadRow.init(values:)))
    }

    static let databaseResult = result(
        [("name", "VARCHAR", false, false)],
        [[.string("edith_lab")], [.string("mysql")]])

    static let relationResult = result(
        [
            ("name", "VARCHAR", false, false),
            ("kind", "VARCHAR", false, false),
            ("engine", "VARCHAR", true, false),
            ("estimatedRows", "BIGINT UNSIGNED", true, false),
        ],
        [
            [.string("events"), .string("table"), .string("InnoDB"), .unsignedInteger(1_000_000)],
            [.string("recent_events"), .string("view"), .string(""), .null],
        ])

    static let columnResult = result(
        [
            ("name", "VARCHAR", false, false),
            ("typeName", "VARCHAR", false, false),
            ("nullable", "TINYINT", false, false),
            ("primaryKey", "TINYINT", false, false),
        ],
        [
            [.string("id"), .string("bigint unsigned"), .boolean(false), .boolean(true)],
            [.string("label"), .string("varchar(255)"), .boolean(false), .boolean(false)],
        ])

    static func rowResult(_ rows: [(UInt64, String)]) -> MySQLDatabaseReadResult {
        result(
            [
                ("id", "BIGINT UNSIGNED", false, true),
                ("label", "VARCHAR", false, false),
            ],
            rows.map { [.unsignedInteger($0.0), .string($0.1)] })
    }
}

private actor MySQLDatabaseReadingClient: MySQLDatabaseClient {
    typealias Handler = @Sendable (MySQLDatabaseReadPlan) async throws -> MySQLDatabaseReadResult

    private let handler: Handler
    private var plans: [MySQLDatabaseReadPlan] = []
    private var disconnected = false

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard !disconnected else { throw MySQLDatabaseDriverFailure.connection }
        return MySQLDatabaseFoundationFixtures.identity
    }

    func read(_ plan: MySQLDatabaseReadPlan) async throws -> MySQLDatabaseReadResult {
        guard !disconnected else { throw MySQLDatabaseDriverFailure.connection }
        try plan.validate()
        plans.append(plan)
        return try await handler(plan)
    }

    func disconnect() {
        disconnected = true
    }

    func capturedPlans() -> [MySQLDatabaseReadPlan] {
        plans
    }
}

@Test func mysqlReadingDiscoversDatabasesAndRelations() async throws {
    let definition = try MySQLDatabaseFoundationFixtures.definition()
    let client = MySQLDatabaseReadingClient { plan in
        if plan.sql.contains("information_schema.SCHEMATA") {
            return MySQLDatabaseReadingFixtures.databaseResult
        }
        #expect(plan.sql.contains("information_schema.TABLES"))
        #expect(plan.binds.first == .string("edith_lab"))
        return MySQLDatabaseReadingFixtures.relationResult
    }
    let session = try await MySQLDatabaseAdapter { _ in client }.connect(
        try MySQLDatabaseFoundationFixtures.resolved(definition),
        context: MySQLDatabaseFoundationFixtures.context())

    let databases = try await session.readPage(
        MySQLDatabaseReadingFixtures.pageRequest(connectionID: definition.id),
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(databases.records.count == 2)
    #expect(databases.records[1].fields.last?.value == .boolean(true))

    let relations = try await session.readPage(
        MySQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            object: DatabaseObjectIdentifier(kind: .database, path: ["edith_lab"])),
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(relations.records.count == 2)
    #expect(relations.records[0].fields.first?.value == .string("events"))
    #expect(relations.records[1].fields[1].value == .string("view"))
    await session.disconnect()
}

@Test func mysqlReadingBrowsesRowsWithPrimaryKeyContinuation() async throws {
    let definition = try MySQLDatabaseFoundationFixtures.definition()
    let client = MySQLDatabaseReadingClient { plan in
        if plan.sql.contains("information_schema.COLUMNS") {
            return MySQLDatabaseReadingFixtures.columnResult
        }
        if plan.sql.contains("`id` > ?") {
            #expect(plan.binds.first == .unsignedInteger(2))
            return MySQLDatabaseReadingFixtures.rowResult([(3, "gamma")])
        }
        #expect(plan.sql.contains("ORDER BY `id` ASC LIMIT ?"))
        return MySQLDatabaseReadingFixtures.rowResult([
            (1, "alpha"), (2, "beta"), (3, "gamma"),
        ])
    }
    let session = try await MySQLDatabaseAdapter { _ in client }.connect(
        try MySQLDatabaseFoundationFixtures.resolved(definition),
        context: MySQLDatabaseFoundationFixtures.context())
    let object = DatabaseObjectIdentifier(kind: .table, path: ["edith_lab", "events"])
    let first = try await session.readPage(
        MySQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            object: object,
            size: 2),
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(first.records.count == 2)
    #expect(first.records.map(\.identity).allSatisfy { $0?.kind == .primaryKey })
    let continuation = try #require(first.nextContinuation)

    let second = try await session.readPage(
        MySQLDatabaseReadingFixtures.pageRequest(
            connectionID: definition.id,
            object: object,
            size: 2,
            continuation: continuation),
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(second.records.count == 1)
    #expect(second.records[0].fields[1].value == .string("gamma"))
    #expect((await client.capturedPlans()).allSatisfy { !$0.sql.uppercased().contains("OFFSET") })
    await session.disconnect()
}

@Test func mysqlReadingBoundsQueriesAndRejectsMutations() async throws {
    let definition = try MySQLDatabaseFoundationFixtures.definition()
    let client = MySQLDatabaseReadingClient { plan in
        #expect(
            plan.sql == "SELECT * FROM (SELECT id, label FROM events) AS `_edith_query` LIMIT ?")
        #expect(plan.binds == [.signedInteger(3)])
        return MySQLDatabaseReadingFixtures.rowResult([
            (1, "alpha"), (2, "beta"), (3, "gamma"),
        ])
    }
    let session = try await MySQLDatabaseAdapter { _ in client }.connect(
        try MySQLDatabaseFoundationFixtures.resolved(definition),
        context: MySQLDatabaseFoundationFixtures.context())
    let page = try await session.query(
        MySQLDatabaseReadingFixtures.queryRequest(
            connectionID: definition.id,
            command: "SELECT id, label FROM events"),
        context: MySQLDatabaseFoundationFixtures.context())
    #expect(page.records.count == 2)
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.metadata.warnings.first?.code == "mysql.query.truncated")

    await #expect(throws: DatabaseAdapterFailure.self) {
        _ = try await session.query(
            MySQLDatabaseReadingFixtures.queryRequest(
                connectionID: definition.id,
                command: "DELETE FROM events"),
            context: MySQLDatabaseFoundationFixtures.context())
    }
    #expect((await client.capturedPlans()).count == 1)
    await session.disconnect()
}

@Test(.enabled(if: MySQLDatabaseLiveEnvironment.mysqlEnabled))
func mysqlReadingLiveDiscoversAndPagesMillionRowTable() async throws {
    let client = try await MySQLNIODatabaseClient.connect(MySQLDatabaseLiveEnvironment.plan())
    do {
        let connectionID = DatabaseConnectionID()
        let sessionID = DatabaseAdapterSessionID()
        let databases = try await MySQLDatabaseReadSupport.readPage(
            MySQLDatabaseReadingFixtures.pageRequest(connectionID: connectionID),
            connectionID: connectionID,
            sessionID: sessionID,
            client: client,
            startedAt: .now)
        #expect(
            databases.records.contains {
                $0.fields.first?.value == .string("edith_lab")
            })

        let database = DatabaseObjectIdentifier(kind: .database, path: ["edith_lab"])
        let relations = try await MySQLDatabaseReadSupport.readPage(
            MySQLDatabaseReadingFixtures.pageRequest(
                connectionID: connectionID,
                object: database),
            connectionID: connectionID,
            sessionID: sessionID,
            client: client,
            startedAt: .now)
        #expect(
            relations.records.contains {
                $0.fields.first?.value == .string("events")
            })

        let table = DatabaseObjectIdentifier(kind: .table, path: ["edith_lab", "events"])
        let first = try await MySQLDatabaseReadSupport.readPage(
            MySQLDatabaseReadingFixtures.pageRequest(
                connectionID: connectionID,
                object: table,
                size: 100),
            connectionID: connectionID,
            sessionID: sessionID,
            client: client,
            startedAt: .now)
        #expect(first.records.count == 100)
        #expect(first.records.first?.fields.first?.value == .unsignedInteger(1))
        let continuation = try #require(first.nextContinuation)

        let second = try await MySQLDatabaseReadSupport.readPage(
            MySQLDatabaseReadingFixtures.pageRequest(
                connectionID: connectionID,
                object: table,
                size: 100,
                continuation: continuation),
            connectionID: connectionID,
            sessionID: sessionID,
            client: client,
            startedAt: .now)
        #expect(second.records.count == 100)
        #expect(second.records.first?.fields.first?.value == .unsignedInteger(101))

        let query = try await MySQLDatabaseReadSupport.query(
            MySQLDatabaseReadingFixtures.queryRequest(
                connectionID: connectionID,
                command: "SELECT id, category FROM edith_lab.events ORDER BY id",
                size: 25),
            connectionID: connectionID,
            client: client,
            startedAt: .now)
        #expect(query.records.count == 25)
        #expect(query.metadata.completeness.state == .partial)
    } catch {
        await client.disconnect()
        throw error
    }
    await client.disconnect()
}
