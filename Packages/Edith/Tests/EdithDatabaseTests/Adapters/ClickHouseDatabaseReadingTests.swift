import Foundation
import Testing

#if canImport(Darwin)
import Darwin
#endif

@testable import EdithDatabase

private enum ClickHouseDatabaseReadingFixtures {
    static let identity = try! ClickHouseDatabaseDriverSupport.identity(
        ClickHouseDatabaseIdentityValues(
            version: "26.7.5.10",
            database: "analytics",
            timezone: "UTC",
            hostName: "clickhouse-test",
            clusterName: "",
            clusterNodeCount: 0,
            shardCount: 0,
            totalReplicas: 0))

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        product: DatabaseProduct = .clickHouse,
        readOnly: DatabaseReadOnlyPolicy = .required,
        productionPolicy: DatabaseProductionPolicy = .prohibitMutations,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        username: String? = "reader",
        namespaces: DatabaseNamespaceDefaults = DatabaseNamespaceDefaults(
            database: "analytics"),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none)
    ) throws -> DatabaseConnectionDefinition {
        DatabaseConnectionDefinition(
            id: id,
            displayName: "ClickHouse fixture",
            productHint: product,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(58_123),
                    role: .node)
            ]),
            username: username,
            namespaces: namespaces,
            deploymentMode: .standalone,
            authentication: authentication,
            tls: tls,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 10_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: readOnly,
            productionPolicy: productionPolicy,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "Testing",
                protection: .readOnly),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }

    static func resolved(
        _ definition: DatabaseConnectionDefinition
    ) throws -> DatabaseResolvedConnection {
        try DatabaseResolvedConnection(definition: definition, secrets: [:])
    }

    static func context(
        operationID: DatabaseOperationID = DatabaseOperationID(),
        deadline: Date? = nil
    ) -> DatabaseAdapterOperationContext {
        DatabaseAdapterOperationContext(
            operation: DatabaseOperationContext(
                operationID: operationID,
                deadline: deadline),
            cancellation: DatabaseAdapterCancellationSignal())
    }

    static func target(
        connectionID: DatabaseConnectionID,
        kind: DatabaseObjectKind = .table,
        path: [String] = ["analytics", "events"]
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: kind, path: path))
    }

    static func pageRequest(
        target: DatabaseTargetIdentifier,
        size: Int = 2,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = []
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target,
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(size),
                projection: projection,
                filter: filter,
                sorts: sorts,
                consistency: .bestEffort),
            continuation: continuation)
    }

    static func queryRequest(
        target: DatabaseTargetIdentifier,
        command: String,
        size: Int = 20,
        parameters: [DatabaseQueryParameter] = []
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: target,
                language: .clickHouseSQL,
                command: command,
                parameters: parameters,
                page: DatabasePageRequest(
                    pageSize: try DatabasePageSize(size),
                    consistency: .bestEffort)),
            continuation: nil)
    }

    static func response(
        names: [String],
        types: [String],
        rows: [[Any]]
    ) throws -> ClickHouseDatabaseHTTPResponse {
        var body = Data()
        for value in [names as [Any], types as [Any]] + rows {
            body.append(try JSONSerialization.data(withJSONObject: value))
            body.append(0x0A)
        }
        return ClickHouseDatabaseHTTPResponse(
            statusCode: 200,
            exceptionCode: nil,
            body: body)
    }

    static func descriptionResponse() throws -> ClickHouseDatabaseHTTPResponse {
        try response(
            names: ["name", "type", "position", "is_in_primary_key", "is_in_sorting_key"],
            types: ["String", "String", "UInt64", "UInt64", "UInt64"],
            rows: [
                ["event_id", "UInt64", "1", "1", "1"],
                ["category", "String", "2", "0", "0"],
                ["score", "Float64", "3", "0", "0"],
            ])
    }

    static func browseResponse(
        secondPage: Bool = false
    ) throws -> ClickHouseDatabaseHTTPResponse {
        try response(
            names: ["label", "_edith_sort_0", "_edith_sort_1"],
            types: ["String", "Float64", "UInt64"],
            rows: secondPage
                ? [["delta", 6.5, "4"]]
                : [
                    ["alpha", 9.5, "1"],
                    ["beta", 8.5, "2"],
                    ["gamma", 7.5, "3"],
                ])
    }
}

private final class ClickHouseDatabaseReadingClient: ClickHouseDatabaseClient,
    @unchecked Sendable
{
    typealias Handler =
        @Sendable (
            _ query: String,
            _ parameters: [ClickHouseDatabaseHTTPParameter]
        ) async throws -> ClickHouseDatabaseHTTPResponse

    private let lock = NSLock()
    private let identity: DatabaseProductIdentity
    private let handler: Handler
    private var recordedQueries: [String] = []
    private var disconnected = false

    init(
        identity: DatabaseProductIdentity = ClickHouseDatabaseReadingFixtures.identity,
        handler: @escaping Handler
    ) {
        self.identity = identity
        self.handler = handler
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard !lock.withLock({ disconnected }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        return identity
    }

    func execute(
        query: String,
        maximumResponseBytes: Int,
        parameters: [ClickHouseDatabaseHTTPParameter]
    ) async throws -> ClickHouseDatabaseHTTPResponse {
        guard !lock.withLock({ disconnected }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        lock.withLock { recordedQueries.append(query) }
        let response = try await handler(query, parameters)
        guard response.body.count <= maximumResponseBytes else {
            throw ClickHouseDatabaseDriverFailure.resourceLimit(nil)
        }
        return response
    }

    func disconnect() async {
        lock.withLock { disconnected = true }
    }

    var queries: [String] {
        lock.withLock { recordedQueries }
    }
}

@Test func clickHouseReadingRequiresExplicitReadOnlyConnection() throws {
    let definition = try ClickHouseDatabaseReadingFixtures.definition(
        readOnly: .disabled,
        productionPolicy: .standard)
    let resolved = try ClickHouseDatabaseReadingFixtures.resolved(definition)
    #expect(throws: ClickHouseDatabaseAdapterSupport.invalidConnection) {
        _ = try ClickHouseDatabaseAdapterSupport.connectionPlan(
            resolved,
            context: ClickHouseDatabaseReadingFixtures.context())
    }
}

@Test func clickHouseReadingDiscoversCapabilitiesAndMetadata() async throws {
    let definition = try ClickHouseDatabaseReadingFixtures.definition()
    let rootResponse = try ClickHouseDatabaseReadingFixtures.response(
        names: ["name", "engine"],
        types: ["String", "String"],
        rows: [["analytics", "Atomic"]])
    let client = ClickHouseDatabaseReadingClient { query, _ in
        #expect(query.contains("FROM system.databases"))
        return rootResponse
    }
    let adapter = ClickHouseDatabaseAdapter { _ in client }
    let session = try await adapter.connect(
        try ClickHouseDatabaseReadingFixtures.resolved(definition),
        context: ClickHouseDatabaseReadingFixtures.context())
    let report = try await session.discoverCapabilities(
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(report.supports(.browse))
    #expect(report.supports(.query))
    #expect(report.supports(.explain))
    #expect(report.pagingModes == [.keyset, .streamed])
    #expect(report.cancellationModes == [.serverOperation])
    let page = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: DatabaseTargetIdentifier(connectionID: definition.id)),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(page.records.count == 1)
    #expect(page.metadata.completeness.state == .complete)
    #expect(page.records[0].identity?.kind == .key)
    await session.disconnect()
}

@Test func clickHouseReadingBrowsesWithBoundKeysetAndStreams() async throws {
    let definition = try ClickHouseDatabaseReadingFixtures.definition()
    let description = try ClickHouseDatabaseReadingFixtures.descriptionResponse()
    let first = try ClickHouseDatabaseReadingFixtures.browseResponse()
    let second = try ClickHouseDatabaseReadingFixtures.browseResponse(secondPage: true)
    let client = ClickHouseDatabaseReadingClient { query, parameters in
        if query.contains("FROM system.columns") { return description }
        return parameters.contains(where: { $0.name.hasPrefix("_edith_after") })
            ? second
            : first
    }
    let adapter = ClickHouseDatabaseAdapter { _ in client }
    let session = try await adapter.connect(
        try ClickHouseDatabaseReadingFixtures.resolved(definition),
        context: ClickHouseDatabaseReadingFixtures.context())
    let target = ClickHouseDatabaseReadingFixtures.target(connectionID: definition.id)
    let projection = DatabaseProjection(
        mode: .include,
        fields: [
            DatabaseProjectedField(
                path: DatabaseFieldPath("category"),
                alias: "label")
        ])
    let filter = DatabaseFilter.predicate(
        DatabaseFilterPredicate(
            field: DatabaseFieldPath("category"),
            operation: .contains,
            values: [.string("a")]))
    let sorts = [
        DatabaseSort(field: DatabaseFieldPath("score"), direction: .descending)
    ]
    let request = try ClickHouseDatabaseReadingFixtures.pageRequest(
        target: target,
        projection: projection,
        filter: filter,
        sorts: sorts)
    let firstPage = try await session.readPage(
        request,
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(firstPage.records.map { $0.fields[0].name } == ["label", "label"])
    #expect(firstPage.records.map(\.identity).allSatisfy { $0?.kind == .key })
    let continuation = try #require(firstPage.nextContinuation)
    #expect(continuation.mode == .keyset)
    let secondPage = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: target,
            continuation: continuation,
            projection: projection,
            filter: filter,
            sorts: sorts),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(secondPage.records.count == 1)
    #expect(
        Set(firstPage.records.compactMap(\.identity)).isDisjoint(
            with: Set(secondPage.records.compactMap(\.identity))))
    #expect(client.queries.allSatisfy { !$0.uppercased().contains("OFFSET") })
    #expect(client.queries.contains { $0.contains("positionUTF8") })
    #expect(client.queries.contains { $0.contains("`score` DESC") })

    let streamSession = try await adapter.connect(
        try ClickHouseDatabaseReadingFixtures.resolved(definition),
        context: ClickHouseDatabaseReadingFixtures.context())
    let streamSource = try ClickHouseDatabaseReadingFixtures.pageRequest(
        target: target,
        size: 100,
        projection: projection,
        filter: filter,
        sorts: sorts)
    let stream = try await streamSession.openStream(
        DatabaseAdapterStreamRequest(
            source: .browse(streamSource),
            batchSize: try DatabaseAdapterBatchSize(2)),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(try await stream.nextBatch()?.records.count == 2)
    #expect(try await stream.nextBatch()?.records.count == 1)
    #expect(try await stream.nextBatch() == nil)
    await stream.close()
    await streamSession.disconnect()
    await session.disconnect()
}

@Test func clickHouseReadingRejectsForgedContinuationsAndUnsafeQueries() throws {
    let connectionID = DatabaseConnectionID()
    let target = ClickHouseDatabaseReadingFixtures.target(connectionID: connectionID)
    let description = ClickHouseDatabaseTableDescription(
        database: "analytics",
        table: "events",
        columns: [
            ClickHouseDatabaseColumn(
                name: "event_id",
                type: "UInt64",
                position: 1,
                isPrimaryKey: true,
                isSortingKey: true)
        ])
    let sessionID = DatabaseAdapterSessionID()
    let initial = try ClickHouseDatabaseReadingFixtures.pageRequest(target: target, size: 1)
    let plan = try ClickHouseDatabaseReadCompiler.compileBrowse(
        initial,
        description: description,
        sessionID: sessionID)
    let response = try ClickHouseDatabaseReadingFixtures.response(
        names: ["event_id", "_edith_sort_0"],
        types: ["UInt64", "UInt64"],
        rows: [["1", "1"], ["2", "2"]])
    let page = try ClickHouseDatabaseReadCompiler.browsePage(
        response: response,
        plan: plan,
        request: initial,
        sessionID: sessionID,
        startedAt: .now)
    let valid = try #require(page.nextContinuation)
    let payload = try JSONDecoder().decode(
        ClickHouseDatabaseContinuationPayload.self,
        from: valid.payload)
    let malformed = try DatabaseAdapterContinuation(
        mode: .keyset,
        payload: JSONEncoder().encode(
            ClickHouseDatabaseContinuationPayload(
                version: payload.version,
                sessionID: payload.sessionID,
                scope: payload.scope,
                requestDigest: payload.requestDigest,
                order: payload.order,
                values: [],
                seenRows: payload.seenRows,
                expiresAt: payload.expiresAt)),
        expiresAt: payload.expiresAt)
    #expect(throws: ClickHouseDatabaseAdapterSupport.invalidContinuation) {
        _ = try ClickHouseDatabaseReadCompiler.compileBrowse(
            ClickHouseDatabaseReadingFixtures.pageRequest(
                target: target,
                size: 1,
                continuation: malformed),
            description: description,
            sessionID: sessionID)
    }
    for command in [
        "INSERT INTO events VALUES (1)",
        "SELECT * FROM url('https://example.test')",
        "SELECT 1 FORMAT JSONEachRow",
        "SELECT 1 SETTINGS readonly=0",
        "SELECT 1; DROP TABLE events",
        "SELECT * FROM remote('host', database, table)",
    ] {
        #expect(throws: ClickHouseDatabaseAdapterSupport.unsafeRequest) {
            _ = try ClickHouseDatabaseReadCompiler.compileQuery(
                ClickHouseDatabaseReadingFixtures.queryRequest(
                    target: target,
                    command: command))
        }
    }
    let bounded = try ClickHouseDatabaseReadCompiler.compileQuery(
        ClickHouseDatabaseReadingFixtures.queryRequest(
            target: target,
            command: "SELECT event_id FROM events",
            size: 7))
    #expect(bounded.query.contains("LIMIT 8"))
    #expect(bounded.query.hasSuffix("FORMAT JSONCompactEachRowWithNamesAndTypes"))
    let explain = try ClickHouseDatabaseReadCompiler.compileQuery(
        ClickHouseDatabaseReadingFixtures.queryRequest(
            target: target,
            command: "EXPLAIN PIPELINE SELECT event_id FROM events",
            size: 7))
    #expect(!explain.query.contains("AS _edith_query"))
    #expect(explain.query.hasSuffix("FORMAT JSONCompactEachRowWithNamesAndTypes"))
}

@Test func clickHouseReadingDegradesMetadataPermissionAndRedactsFailures() async throws {
    let definition = try ClickHouseDatabaseReadingFixtures.definition()
    let permissionClient = ClickHouseDatabaseReadingClient { _, _ in
        throw ClickHouseDatabaseDriverFailure.permission("497")
    }
    let session = try await ClickHouseDatabaseAdapter { _ in permissionClient }.connect(
        try ClickHouseDatabaseReadingFixtures.resolved(definition),
        context: ClickHouseDatabaseReadingFixtures.context())
    let page = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: DatabaseTargetIdentifier(connectionID: definition.id)),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(page.records.isEmpty)
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.metadata.warnings.first?.code == "clickhouse.metadata.permission_denied")
    await session.disconnect()

    let failure = ClickHouseDatabaseAdapterSupport.map(
        .resourceLimit("241"),
        fallback: ClickHouseDatabaseAdapterSupport.invalidResponse)
    guard case let .reported(envelope) = failure else {
        Issue.record("expected a reported failure")
        return
    }
    #expect(envelope.category == .resourceLimit)
    #expect(envelope.productCode == "clickhouse.exception.241")
    #expect(envelope.details.isEmpty)
    #expect(!envelope.message.contains("credential"))
}

private enum ClickHouseDatabaseReadingLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_CLICKHOUSE_HOST",
        "EDITH_DATABASE_CLICKHOUSE_PORT",
        "EDITH_DATABASE_CLICKHOUSE_DATABASE",
        "EDITH_DATABASE_CLICKHOUSE_USERNAME",
        "EDITH_DATABASE_CLICKHOUSE_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }

    static func resolved() throws -> DatabaseResolvedConnection {
        let host = try #require(values["EDITH_DATABASE_CLICKHOUSE_HOST"])
        let portText = try #require(values["EDITH_DATABASE_CLICKHOUSE_PORT"])
        let port = try #require(Int(portText))
        let database = try #require(values["EDITH_DATABASE_CLICKHOUSE_DATABASE"])
        let username = try #require(values["EDITH_DATABASE_CLICKHOUSE_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_CLICKHOUSE_PASSWORD"])
        let reference = DatabaseSecretReference(
            identifier: UUID(uuidString: "EC72C163-9595-4217-B5FC-C8F25C80E571")!,
            purpose: .password)
        let definition = DatabaseConnectionDefinition(
            id: DatabaseConnectionID(),
            displayName: "ClickHouse TUF reading fixture",
            productHint: .clickHouse,
            location: .network([
                DatabaseNetworkEndpoint(
                    host: host,
                    port: try DatabasePort(port),
                    role: .node)
            ]),
            username: username,
            namespaces: DatabaseNamespaceDefaults(database: database),
            deploymentMode: .standalone,
            authentication: DatabaseAuthentication(
                kind: .usernameAndPassword,
                secretReferences: [reference]),
            tls: DatabaseTLSConfiguration(mode: .disabled, verification: .none),
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 5_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 15_000),
                poolSize: try DatabasePoolSize(1)),
            readOnlyPolicy: .required,
            productionPolicy: .prohibitMutations,
            environment: DatabaseEnvironmentMetadata(
                kind: .testing,
                label: "TUF",
                protection: .readOnly),
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
        return try DatabaseResolvedConnection(
            definition: definition,
            secrets: [reference: Data(password.utf8)])
    }

    static func residentBytes() -> UInt64? {
        #if canImport(Darwin)
        var information = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &information) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count)
            }
        }
        return result == KERN_SUCCESS ? information.resident_size : nil
        #else
        return nil
        #endif
    }
}

@Test(.enabled(if: ClickHouseDatabaseReadingLiveEnvironment.isEnabled))
func clickHouseReadingLiveMillionRowTraversalAndLifecycle() async throws {
    let resolved = try ClickHouseDatabaseReadingLiveEnvironment.resolved()
    let adapter = ClickHouseDatabaseAdapter()
    let session = try await adapter.connect(
        resolved,
        context: ClickHouseDatabaseReadingFixtures.context(
            deadline: Date().addingTimeInterval(10)))
    #expect(session.productIdentity.product == .clickHouse)
    let version = try #require(session.productIdentity.version)
    let major = try #require(version.major)
    #expect(major >= 26)
    let capabilities = try await session.discoverCapabilities(
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(capabilities.supports(.browse))
    #expect(capabilities.supports(.explain))

    let database = try #require(resolved.definition.namespaces.database)
    let discovery = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: DatabaseTargetIdentifier(connectionID: resolved.definition.id),
            size: 100),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(
        discovery.records.contains {
            $0.fields.contains { $0.name == "name" && $0.value == .string(database) }
        })
    let columnPage = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: ClickHouseDatabaseReadingFixtures.target(
                connectionID: resolved.definition.id,
                kind: .column,
                path: [database, "events"]),
            size: 100),
        context: ClickHouseDatabaseReadingFixtures.context())
    let columnNames: Set<String> = Set(
        columnPage.records.compactMap { record in
            guard case .string(let name)? = record.fields.first(where: { $0.name == "name" })?.value
            else { return nil }
            return name
        })
    #expect(
        Set([
            "event_id", "event_date", "event_time", "category", "nullable_note", "tags",
            "coordinates", "attributes", "amount", "payload", "day_of_week",
        ]).isSubset(of: columnNames))

    let target = ClickHouseDatabaseReadingFixtures.target(
        connectionID: resolved.definition.id,
        path: [database, "events"])
    let projection = DatabaseProjection(
        mode: .include,
        fields: ["event_id", "event_date", "event_time", "category", "amount"].map {
            DatabaseProjectedField(path: DatabaseFieldPath($0))
        })
    let firstStartedAt = ContinuousClock.now
    let first = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: target,
            size: 200,
            projection: projection),
        context: ClickHouseDatabaseReadingFixtures.context())
    let firstLatency = firstStartedAt.duration(to: .now)
    let firstIdentities = Set(first.records.compactMap(\.identity))
    #expect(first.records.count == 200)
    #expect(first.nextContinuation != nil)
    let second = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: target,
            size: 200,
            continuation: first.nextContinuation,
            projection: projection),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(firstIdentities.isDisjoint(with: Set(second.records.compactMap(\.identity))))

    let filtered = try await session.readPage(
        ClickHouseDatabaseReadingFixtures.pageRequest(
            target: target,
            size: 50,
            projection: projection,
            filter: .predicate(
                DatabaseFilterPredicate(
                    field: DatabaseFieldPath("category"),
                    operation: .equal,
                    values: [.string("alpha")])),
            sorts: [
                DatabaseSort(
                    field: DatabaseFieldPath("amount"),
                    direction: .descending)
            ]),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(!filtered.records.isEmpty)
    #expect(filtered.fields.map(\.displayName) == projection.fields.map { $0.path.segments[0] })

    let countPage = try await session.query(
        ClickHouseDatabaseReadingFixtures.queryRequest(
            target: target,
            command: "SELECT count() AS total FROM `\(database)`.`events`"),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(countPage.records.first?.fields.first?.value == .unsignedInteger(1_000_000))
    let explain = try await session.query(
        ClickHouseDatabaseReadingFixtures.queryRequest(
            target: target,
            command: "EXPLAIN PIPELINE SELECT event_id FROM `\(database)`.`events` LIMIT 10"),
        context: ClickHouseDatabaseReadingFixtures.context())
    #expect(!explain.records.isEmpty)

    let streamSource = try ClickHouseDatabaseReadingFixtures.pageRequest(
        target: target,
        size: 500,
        projection: projection)
    let stream = try await session.openStream(
        DatabaseAdapterStreamRequest(
            source: .browse(streamSource),
            batchSize: try DatabaseAdapterBatchSize(500)),
        context: ClickHouseDatabaseReadingFixtures.context(
            deadline: Date().addingTimeInterval(30)))
    var traversed = 0
    var previous = Set<DatabaseRecordIdentity>()
    var warmedMemory: UInt64?
    var peakMemory: UInt64 = 0
    for batchIndex in 0..<60 {
        let batch = try #require(try await stream.nextBatch())
        let identities = Set(batch.records.compactMap(\.identity))
        #expect(previous.isDisjoint(with: identities))
        previous = identities
        traversed += batch.records.count
        if let memory = ClickHouseDatabaseReadingLiveEnvironment.residentBytes() {
            if batchIndex == 9 { warmedMemory = memory }
            if batchIndex >= 9 { peakMemory = max(peakMemory, memory) }
        }
    }
    await stream.close()
    #expect(traversed == 30_000)
    if let warmedMemory {
        #expect(peakMemory <= warmedMemory + 100 * 1_048_576)
    }

    let cancelID = DatabaseOperationID()
    let cancellation = Task {
        try await session.query(
            ClickHouseDatabaseReadingFixtures.queryRequest(
                target: target,
                command: "SELECT sleepEachRow(0.01) FROM numbers(1000)"),
            context: ClickHouseDatabaseReadingFixtures.context(
                operationID: cancelID,
                deadline: Date().addingTimeInterval(10)))
    }
    try await Task.sleep(for: .milliseconds(20))
    let cancelStartedAt = ContinuousClock.now
    let cancellationResult = await session.cancel(cancelID)
    #expect(cancellationResult.disposition == .accepted)
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await cancellation.value
    }
    let cancellationLatency = cancelStartedAt.duration(to: .now)
    #expect(cancellationLatency < .seconds(2))

    let reconnected = try await adapter.connect(
        resolved,
        context: ClickHouseDatabaseReadingFixtures.context())
    let deadlineStartedAt = ContinuousClock.now
    await #expect(throws: ClickHouseDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await reconnected.query(
            ClickHouseDatabaseReadingFixtures.queryRequest(
                target: target,
                command: "SELECT sleep(2)"),
            context: ClickHouseDatabaseReadingFixtures.context(
                deadline: Date().addingTimeInterval(0.02)))
    }
    let deadlineLatency = deadlineStartedAt.duration(to: .now)
    #expect(deadlineLatency < .seconds(2))
    await reconnected.disconnect()
    await session.disconnect()

    print(
        [
            "clickhouse reading live version=\(version.string)",
            "count=1000000",
            "firstPage=\(firstLatency)",
            "traversed=\(traversed)",
            "warmedRSS=\(warmedMemory ?? 0)",
            "peakRSS=\(peakMemory)",
            "cancel=\(cancellationLatency)",
            "deadline=\(deadlineLatency)",
        ].joined(separator: " "))
}
