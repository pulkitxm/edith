import Foundation
import MongoCore
import MongoKitten
import Testing

@testable import EdithDatabase

private typealias MongoAdapterValue = EdithDatabase.DatabaseValue

private enum MongoDBDatabaseAdapterFixtures {
    static let objectIDs = [
        ObjectId("64b7abdecf2160b649ab6085")!,
        ObjectId("64b7abdecf2160b649ab6086")!,
        ObjectId("64b7abdecf2160b649ab6087")!,
        ObjectId("64b7abdecf2160b649ab6088")!,
    ]

    static let identity = DatabaseProductIdentity(
        product: .mongoDB,
        version: DatabaseVersion(string: "8.0.12", major: 8, minor: 0, patch: 12),
        distribution: "MongoDB",
        topology: DatabaseTopology(
            kind: .standalone,
            localRole: "standalone",
            nodeCount: 1,
            attributes: [DatabaseStringAttribute(name: "maxWireVersion", value: "25")]))

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        product: DatabaseProduct = .mongoDB,
        location: DatabaseConnectionLocation? = nil,
        username: String? = nil,
        database: String? = "edith_scale",
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication = DatabaseAuthentication(kind: .none),
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        tunnel: DatabaseTunnelDefinition? = nil,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        let effectiveLocation: DatabaseConnectionLocation
        if let location {
            effectiveLocation = location
        } else {
            effectiveLocation = .network([
                DatabaseNetworkEndpoint(
                    host: "127.0.0.1",
                    port: try DatabasePort(57_017),
                    role: .seed)
            ])
        }
        return DatabaseConnectionDefinition(
            id: id,
            displayName: "MongoDB fixture",
            productHint: product,
            location: effectiveLocation,
            username: username,
            namespaces: DatabaseNamespaceDefaults(database: database),
            deploymentMode: deploymentMode,
            authentication: authentication,
            tls: tls,
            tunnel: tunnel,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 2_000),
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

    static func target(
        connectionID: DatabaseConnectionID,
        database: String = "edith_scale",
        collection: String = "events",
        kind: DatabaseObjectKind = .collection
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(
                kind: kind,
                path: [database, collection]))
    }

    static func request(
        connectionID: DatabaseConnectionID,
        pageSize: Int = 2,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = [],
        consistency: DatabaseConsistencyPreference = .productDefault
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target(connectionID: connectionID),
            page: DatabasePageRequest(
                pageSize: try DatabasePageSize(pageSize),
                projection: projection,
                filter: filter,
                sorts: sorts,
                consistency: consistency),
            continuation: continuation)
    }

    static func query(
        connectionID: DatabaseConnectionID,
        command: String = "find",
        language: DatabaseQueryLanguage = .mongoQuery,
        parameters: [DatabaseQueryParameter] = [],
        body: MongoAdapterValue? = nil,
        page: DatabasePageRequest? = nil,
        continuation: DatabaseAdapterContinuation? = nil
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: target(connectionID: connectionID),
                language: language,
                command: command,
                parameters: parameters,
                body: body,
                page: page ?? DatabasePageRequest(pageSize: try DatabasePageSize(2))),
            continuation: continuation)
    }

    static func document(
        index: Int,
        includeObjectID: Bool = true,
        stringID: String? = nil
    ) -> Document {
        var document = Document()
        if let stringID {
            document["_id"] = stringID
        } else if includeObjectID {
            document["_id"] = objectIDs[index]
        }
        document["sequence"] = Int32(index)
        document["name"] = "event-\(index)"
        return document
    }

    static func connect(
        client: MongoDBDatabaseAdapterTestClient,
        definition: DatabaseConnectionDefinition? = nil,
        secrets: [DatabaseSecretReference: Data] = [:],
        capture: MongoDBDatabaseConnectorCapture? = nil
    ) async throws -> (any DatabaseAdapterSession, DatabaseConnectionDefinition) {
        let definition = try definition ?? self.definition()
        let adapter = MongoDBDatabaseAdapter { plan in
            await capture?.record(plan)
            return client
        }
        let session = try await adapter.connect(
            try resolved(definition, secrets: secrets),
            context: context())
        return (session, definition)
    }

    static func binary(_ data: Data, subtype: Binary.SubType = .generic) -> Binary {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Binary(subType: subtype, buffer: buffer)
    }

    static func reportedCategory(_ failure: DatabaseAdapterFailure) -> DatabaseErrorCategory? {
        guard case let .reported(envelope) = failure else { return nil }
        return envelope.category
    }

    static func reportedCode(_ failure: DatabaseAdapterFailure) -> String? {
        guard case let .reported(envelope) = failure else { return nil }
        return envelope.productCode
    }
}

private actor MongoDBDatabaseAdapterTestClient: MongoDBDatabaseClient {
    enum Outcome: Sendable {
        case result(MongoDBDatabaseReadResult)
        case failure(MongoDBDatabaseDriverFailure)
        case cancelled
    }

    private let identity: DatabaseProductIdentity
    private var outcomes: [Outcome]
    private let suspendsReads: Bool
    private var disconnected = false
    private var readPlans: [MongoDBDatabaseReadPlan] = []
    private var disconnects = 0

    init(
        identity: DatabaseProductIdentity = MongoDBDatabaseAdapterFixtures.identity,
        outcomes: [Outcome] = [],
        suspendsReads: Bool = false
    ) {
        self.identity = identity
        self.outcomes = outcomes
        self.suspendsReads = suspendsReads
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard !disconnected else { throw MongoDBDatabaseDriverFailure.connection }
        return identity
    }

    func read(_ plan: MongoDBDatabaseReadPlan) async throws -> MongoDBDatabaseReadResult {
        readPlans.append(plan)
        if suspendsReads {
            while !disconnected {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            throw CancellationError()
        }
        guard !outcomes.isEmpty else {
            return MongoDBDatabaseReadResult(documents: [], hasMore: false, bytesReceived: 0)
        }
        switch outcomes.removeFirst() {
        case let .result(result):
            return result
        case let .failure(failure):
            throw failure
        case .cancelled:
            throw CancellationError()
        }
    }

    func disconnect() async {
        disconnected = true
        disconnects += 1
    }

    func plans() -> [MongoDBDatabaseReadPlan] {
        readPlans
    }

    func disconnectCount() -> Int {
        disconnects
    }
}

private actor MongoDBDatabaseConnectorCapture {
    private var plans: [MongoDBDatabaseConnectionPlan] = []

    func record(_ plan: MongoDBDatabaseConnectionPlan) {
        plans.append(plan)
    }

    func last() -> MongoDBDatabaseConnectionPlan? {
        plans.last
    }
}

@Test func mongoReadingAdapterRegistersOnlyMongoDB() {
    let adapter = MongoDBDatabaseAdapter()
    #expect(adapter.id == "mongodb")
    #expect(adapter.products == [.mongoDB])
}

@Test func mongoReadingConnectionUsesTypedAuthenticatedSettings() async throws {
    let passwordReference = DatabaseSecretReference(
        identifier: UUID(),
        purpose: .password)
    let definition = try MongoDBDatabaseAdapterFixtures.definition(
        username: "reader",
        authentication: DatabaseAuthentication(
            kind: .scram,
            secretReferences: [passwordReference],
            source: "edith_scale"))
    let capture = MongoDBDatabaseConnectorCapture()
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, _) = try await MongoDBDatabaseAdapterFixtures.connect(
        client: client,
        definition: definition,
        secrets: [passwordReference: Data("fixture-password".utf8)],
        capture: capture)
    let plan = try #require(await capture.last())
    #expect(plan.settings.hosts.count == 1)
    #expect(plan.settings.hosts[0].hostname == "127.0.0.1")
    #expect(plan.settings.hosts[0].port == 57_017)
    #expect(plan.settings.authenticationSource == "edith_scale")
    #expect(plan.settings.targetDatabase == "edith_scale")
    #expect(plan.settings.maximumNumberOfConnections == 2)
    #expect(plan.settings.applicationName == "Edith")
    guard case let .auto(username, password) = plan.settings.authentication else {
        Issue.record("Expected automatic SCRAM authentication")
        return
    }
    #expect(username == "reader")
    #expect(password == "fixture-password")
    await session.disconnect()
}

@Test func mongoReadingConnectionValidationFailsClosed() throws {
    let invalidDefinitions = [
        try MongoDBDatabaseAdapterFixtures.definition(product: .postgresql),
        try MongoDBDatabaseAdapterFixtures.definition(
            location: .network([])),
        try MongoDBDatabaseAdapterFixtures.definition(
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "bad host",
                    port: try DatabasePort(27_017))
            ])),
        try MongoDBDatabaseAdapterFixtures.definition(
            deploymentMode: .cluster),
        try MongoDBDatabaseAdapterFixtures.definition(
            tls: DatabaseTLSConfiguration(mode: .preferred, verification: .full)),
        try MongoDBDatabaseAdapterFixtures.definition(
            options: [DatabaseNonSecretOption(name: "retryWrites", value: .boolean(true))]),
    ]
    for definition in invalidDefinitions {
        let resolved = try MongoDBDatabaseAdapterFixtures.resolved(definition)
        #expect(throws: DatabaseAdapterFailure.self) {
            try MongoDBDatabaseAdapterSupport.connectionPlan(resolved)
        }
    }
}

@Test func mongoReadingConnectionRejectsMissingAndExtraneousSecrets() throws {
    let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
    let definition = try MongoDBDatabaseAdapterFixtures.definition(
        username: "reader",
        authentication: DatabaseAuthentication(
            kind: .usernameAndPassword,
            secretReferences: [reference]))
    #expect(throws: DatabaseAdapterFailure.self) {
        try MongoDBDatabaseAdapterSupport.connectionPlan(
            try MongoDBDatabaseAdapterFixtures.resolved(definition))
    }
    let unauthenticated = try MongoDBDatabaseAdapterFixtures.definition()
    #expect(throws: DatabaseAdapterFailure.self) {
        try MongoDBDatabaseAdapterSupport.connectionPlan(
            try MongoDBDatabaseAdapterFixtures.resolved(
                unauthenticated,
                secrets: [reference: Data("unexpected".utf8)]))
    }
}

@Test func mongoReadingCapabilitiesAreHonestAndReadOnly() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, _) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let report = try await session.discoverCapabilities(
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(report.productIdentity.product == .mongoDB)
    #expect(report.supports(.browse))
    #expect(report.supports(.query))
    #expect(report.supports(.queryCancellation))
    #expect(!report.supports(.objectDiscovery))
    #expect(!report.supports(.insert))
    #expect(!report.supports(.update))
    #expect(!report.supports(.delete))
    #expect(report.pagingModes == [.keyset])
    #expect(report.mutationModes == [.unsupported])
    #expect(report.cancellationModes == [.cooperative])
    #expect(report.safetyLimitations.contains(where: { $0.contains("requires reconnecting") }))
    await session.disconnect()
}

@Test func mongoReadingBrowseBuildsBoundedProjectionFilterSortAndCanonicalValues() async throws {
    var first = MongoDBDatabaseAdapterFixtures.document(index: 0)
    first["active"] = true
    first["createdAt"] = Date(timeIntervalSince1970: 1_700_000_000.125)
    first["payload"] = MongoDBDatabaseAdapterFixtures.binary(Data([1, 2, 3]))
    var nested = Document()
    nested["region"] = "東京"
    first["nested"] = nested
    let documents = [
        first,
        MongoDBDatabaseAdapterFixtures.document(index: 1),
        MongoDBDatabaseAdapterFixtures.document(index: 2),
    ]
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: documents,
                    hasMore: false,
                    bytesReceived: UInt64(documents.reduce(0) { $0 + $1.makeData().count })))
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let projection = DatabaseProjection(
        mode: .include,
        fields: [
            DatabaseProjectedField(path: DatabaseFieldPath("name")),
            DatabaseProjectedField(path: DatabaseFieldPath("active")),
            DatabaseProjectedField(path: DatabaseFieldPath("createdAt")),
            DatabaseProjectedField(path: DatabaseFieldPath("payload")),
            DatabaseProjectedField(path: DatabaseFieldPath("nested")),
        ])
    let filter = DatabaseFilter.predicate(
        DatabaseFilterPredicate(
            field: DatabaseFieldPath("sequence"),
            operation: .greaterThanOrEqual,
            values: [.signedInteger(0)]))
    let request = try MongoDBDatabaseAdapterFixtures.request(
        connectionID: definition.id,
        projection: projection,
        filter: filter)
    let page = try await session.readPage(
        request,
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(page.records.count == 2)
    #expect(page.nextContinuation != nil)
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.records[0].fields.contains(where: { $0.name == "name" }))
    #expect(!page.records[0].fields.contains(where: { $0.name == "_id" }))
    #expect(page.records[0].identity?.kind == .documentID)
    #expect(page.fields.contains(where: { $0.path == DatabaseFieldPath("createdAt") }))
    let plans = await client.plans()
    let plan = try #require(plans.first)
    #expect(plan.limit == 3)
    #expect(plan.batchSize == 3)
    #expect((plan.projection?["name"] as? Int32) == 1)
    #expect((plan.sort["_id"] as? Int32) == 1)
    let sequence = try #require(plan.filter["sequence"] as? Document)
    #expect((sequence["$gte"] as? Int) == 0)
    await session.disconnect()
}

@Test func mongoReadingContinuationUsesOnlyObjectIDKeysetBoundary() async throws {
    let firstDocuments = [
        MongoDBDatabaseAdapterFixtures.document(index: 0),
        MongoDBDatabaseAdapterFixtures.document(index: 1),
        MongoDBDatabaseAdapterFixtures.document(index: 2),
    ]
    let secondDocuments = [MongoDBDatabaseAdapterFixtures.document(index: 2)]
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: firstDocuments,
                    hasMore: false,
                    bytesReceived: 100)),
            .result(
                MongoDBDatabaseReadResult(
                    documents: secondDocuments,
                    hasMore: false,
                    bytesReceived: 40)),
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let firstRequest = try MongoDBDatabaseAdapterFixtures.request(
        connectionID: definition.id)
    let firstPage = try await session.readPage(
        firstRequest,
        context: MongoDBDatabaseAdapterFixtures.context())
    let continuation = try #require(firstPage.nextContinuation)
    #expect(continuation.mode == .keyset)
    let payload = try JSONDecoder().decode(
        MongoDBDatabaseAdapterContinuationPayload.self,
        from: continuation.payload)
    #expect(payload.objectID == MongoDBDatabaseAdapterFixtures.objectIDs[1].hexString)
    #expect(payload.direction == .ascending)
    #expect(!String(decoding: continuation.payload, as: UTF8.self).contains("cursor"))

    let secondRequest = try MongoDBDatabaseAdapterFixtures.request(
        connectionID: definition.id,
        continuation: continuation)
    _ = try await session.readPage(
        secondRequest,
        context: MongoDBDatabaseAdapterFixtures.context())
    let plans = await client.plans()
    #expect(plans.count == 2)
    let boundary = try #require(plans[1].filter["_id"] as? Document)
    #expect((boundary["$gt"] as? ObjectId) == MongoDBDatabaseAdapterFixtures.objectIDs[1])
    await session.disconnect()
}

@Test func mongoReadingContinuationIsUnavailableWithoutProvablyUniqueBoundary() async throws {
    let documents = [
        MongoDBDatabaseAdapterFixtures.document(index: 0, includeObjectID: false, stringID: "a"),
        MongoDBDatabaseAdapterFixtures.document(index: 1, includeObjectID: false, stringID: "b"),
        MongoDBDatabaseAdapterFixtures.document(index: 2, includeObjectID: false, stringID: "c"),
    ]
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: documents,
                    hasMore: false,
                    bytesReceived: 100))
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let page = try await session.readPage(
        try MongoDBDatabaseAdapterFixtures.request(connectionID: definition.id),
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(page.records.count == 2)
    #expect(page.nextContinuation == nil)
    #expect(page.metadata.completeness.state == .truncated)
    await session.disconnect()
}

@Test func mongoReadingGeneralSortNeverEmitsAContinuation() async throws {
    let documents = [
        MongoDBDatabaseAdapterFixtures.document(index: 0),
        MongoDBDatabaseAdapterFixtures.document(index: 1),
        MongoDBDatabaseAdapterFixtures.document(index: 2),
    ]
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: documents,
                    hasMore: false,
                    bytesReceived: 100))
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let request = try MongoDBDatabaseAdapterFixtures.request(
        connectionID: definition.id,
        sorts: [
            DatabaseSort(field: DatabaseFieldPath("name"), direction: .ascending)
        ])
    let page = try await session.readPage(
        request,
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(page.nextContinuation == nil)
    #expect(page.metadata.completeness.state == .truncated)
    let plans = await client.plans()
    #expect((plans[0].sort["name"] as? Int32) == 1)
    await session.disconnect()
}

@Test func mongoReadingRejectsTamperedExpiredAndSortMismatchedContinuations() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let target = MongoDBDatabaseAdapterFixtures.target(connectionID: definition.id)
    let malformed = try DatabaseAdapterContinuation(mode: .keyset, payload: Data("{}".utf8))
    let expiredPayload = try JSONEncoder().encode(
        MongoDBDatabaseAdapterContinuationPayload(
            version: 1,
            kind: .browse,
            database: "edith_scale",
            collection: "events",
            direction: .ascending,
            objectID: MongoDBDatabaseAdapterFixtures.objectIDs[0].hexString))
    let expired = try DatabaseAdapterContinuation(
        mode: .keyset,
        payload: expiredPayload,
        expiresAt: Date(timeIntervalSince1970: 1))
    for continuation in [malformed, expired] {
        let request = try DatabaseAdapterPageRequest(
            target: target,
            page: DatabasePageRequest(pageSize: try DatabasePageSize(2)),
            continuation: continuation)
        do {
            _ = try await session.readPage(
                request,
                context: MongoDBDatabaseAdapterFixtures.context())
            Issue.record("Expected invalid continuation")
        } catch let failure {
            #expect(MongoDBDatabaseAdapterFixtures.reportedCode(failure) == "mongodb.continuation.invalid")
        }
    }
    let mismatchedSortRequest = try DatabaseAdapterPageRequest(
        target: target,
        page: DatabasePageRequest(
            pageSize: try DatabasePageSize(2),
            sorts: [DatabaseSort(field: DatabaseFieldPath("name"), direction: .ascending)]),
        continuation: try DatabaseAdapterContinuation(
            mode: .keyset,
            payload: expiredPayload,
            expiresAt: Date().addingTimeInterval(60)))
    do {
        _ = try await session.readPage(
            mismatchedSortRequest,
            context: MongoDBDatabaseAdapterFixtures.context())
        Issue.record("Expected sort mismatch rejection")
    } catch let failure {
        #expect(MongoDBDatabaseAdapterFixtures.reportedCode(failure) == "mongodb.continuation.invalid")
    }
    await session.disconnect()
}

@Test func mongoReadingTypedFiltersAreBoundedAndEscaped() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let filter = DatabaseFilter.all([
        .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("name"),
                operation: .startsWith,
                values: [.string("a.*")],
                caseSensitivity: .insensitive)),
        .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("sequence"),
                operation: .between,
                values: [.signedInteger(1), .signedInteger(9)])),
        .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("missing"),
                operation: .isMissing)),
    ])
    _ = try await session.readPage(
        try MongoDBDatabaseAdapterFixtures.request(
            connectionID: definition.id,
            filter: filter),
        context: MongoDBDatabaseAdapterFixtures.context())
    let plan = try #require(await client.plans().first)
    let clauses = try #require(plan.filter["$and"] as? Document)
    #expect(clauses.isArray)
    #expect(clauses.count == 3)
    let nameClause = try #require(clauses["0"] as? Document)
    let expression = try #require(nameClause["name"] as? RegularExpression)
    #expect(expression.pattern == "^a\\.\\*")
    #expect(expression.options == "i")
    await session.disconnect()
}

@Test func mongoReadingQueryAllowsOnlyTypedFindAndSafeOperators() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let unsafeBodies: [MongoAdapterValue] = [
        .object([DatabaseObjectField(name: "$where", value: .string("return true"))]),
        .object([DatabaseObjectField(name: "$expr", value: .object([]))]),
        .object([
            DatabaseObjectField(
                name: "field",
                value: .object([
                    DatabaseObjectField(name: "$function", value: .string("x"))
                ]))
        ]),
    ]
    for command in ["insert", "update", "delete", "aggregate", "find ", "Find"] {
        do {
            _ = try await session.query(
                try MongoDBDatabaseAdapterFixtures.query(
                    connectionID: definition.id,
                    command: command),
                context: MongoDBDatabaseAdapterFixtures.context())
            Issue.record("Expected command rejection")
        } catch let failure as DatabaseAdapterFailure {
            #expect(MongoDBDatabaseAdapterFixtures.reportedCode(failure) == "mongodb.query.invalid")
        }
    }
    for body in unsafeBodies {
        do {
            _ = try await session.query(
                try MongoDBDatabaseAdapterFixtures.query(
                    connectionID: definition.id,
                    body: body),
                context: MongoDBDatabaseAdapterFixtures.context())
            Issue.record("Expected operator rejection")
        } catch let failure as DatabaseAdapterFailure {
            #expect(MongoDBDatabaseAdapterFixtures.reportedCode(failure) == "mongodb.query.invalid")
        }
    }
    let plans = await client.plans()
    #expect(plans.isEmpty)
    await session.disconnect()
}

@Test func mongoReadingSafeNativeQueryCombinesWithTypedPageFilter() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let body = MongoAdapterValue.object([
        DatabaseObjectField(
            name: "sequence",
            value: .object([
                DatabaseObjectField(name: "$gte", value: .signedInteger(10)),
                DatabaseObjectField(name: "$lt", value: .signedInteger(20)),
            ]))
    ])
    let page = DatabasePageRequest(
        pageSize: try DatabasePageSize(5),
        filter: .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("active"),
                operation: .equal,
                values: [.boolean(true)])))
    _ = try await session.query(
        try MongoDBDatabaseAdapterFixtures.query(
            connectionID: definition.id,
            body: body,
            page: page),
        context: MongoDBDatabaseAdapterFixtures.context())
    let plan = try #require(await client.plans().first)
    let clauses = try #require(plan.filter["$and"] as? Document)
    #expect(clauses.count == 2)
    #expect(plan.limit == 6)
    await session.disconnect()
}

@Test func mongoReadingPagePreviewsLargeValuesWithinContractBounds() async throws {
    var document = MongoDBDatabaseAdapterFixtures.document(index: 0)
    document["largeText"] = String(repeating: "x", count: 1_000_000)
    document["largeBinary"] = MongoDBDatabaseAdapterFixtures.binary(
        Data(repeating: 3, count: 1_000_000))
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: [document],
                    hasMore: false,
                    bytesReceived: UInt64(document.makeData().count)))
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let page = try await session.readPage(
        try MongoDBDatabaseAdapterFixtures.request(
            connectionID: definition.id,
            pageSize: 1),
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(page.records.count == 1)
    #expect(page.metadata.completeness.state == .truncated)
    #expect(page.metadata.warnings.map(\.code).contains("mongodb.value.preview"))
    #expect(try JSONEncoder().encode(page.records).count < DatabaseAdapterBounds.maximumPageBytes)
    await session.disconnect()
}

@Test func mongoReadingCancellationRemainsCancelledAndClosesSession() async throws {
    let operationID = DatabaseOperationID()
    let client = MongoDBDatabaseAdapterTestClient(suspendsReads: true)
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let context = MongoDBDatabaseAdapterFixtures.context(operationID: operationID)
    let request = try MongoDBDatabaseAdapterFixtures.request(connectionID: definition.id)
    let task = Task {
        try await session.readPage(request, context: context)
    }
    for _ in 0..<200 where await client.plans().isEmpty {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let cancellation = await session.cancel(operationID)
    #expect(cancellation.support == .cooperative)
    #expect(cancellation.disposition == .accepted)
    do {
        _ = try await task.value
        Issue.record("Expected cancellation")
    } catch let failure as DatabaseAdapterFailure {
        #expect(failure == .cancelled)
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnectCount() == 1)
}

@Test func mongoReadingDeadlineAndServerTimeoutMapToTimeout() async throws {
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [.failure(.timeout)])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    do {
        _ = try await session.readPage(
            try MongoDBDatabaseAdapterFixtures.request(connectionID: definition.id),
            context: MongoDBDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(1)))
        Issue.record("Expected timeout")
    } catch let failure as DatabaseAdapterFailure {
        #expect(MongoDBDatabaseAdapterFixtures.reportedCategory(failure) == .timeout)
    }
    let secondClient = MongoDBDatabaseAdapterTestClient()
    let (secondSession, secondDefinition) = try await MongoDBDatabaseAdapterFixtures.connect(
        client: secondClient)
    do {
        _ = try await secondSession.readPage(
            try MongoDBDatabaseAdapterFixtures.request(connectionID: secondDefinition.id),
            context: MongoDBDatabaseAdapterFixtures.context(
                deadline: Date(timeIntervalSince1970: 1)))
        Issue.record("Expected expired deadline rejection")
    } catch let failure as DatabaseAdapterFailure {
        #expect(MongoDBDatabaseAdapterFixtures.reportedCategory(failure) == .timeout)
    }
    #expect(await secondClient.plans().isEmpty)
    await session.disconnect()
    await secondSession.disconnect()
}

@Test func mongoReadingMutationRequestsNeverReachTheDriver() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let request = DatabaseDestructiveRequest(
        target: MongoDBDatabaseAdapterFixtures.target(connectionID: definition.id),
        payload: .document(
            product: .mongoDB,
            operation: "deleteMany",
            parameters: [],
            body: .object([])))
    do {
        _ = try await session.normalizeMutation(
            request,
            context: MongoDBDatabaseAdapterFixtures.context())
        Issue.record("Expected read-only rejection")
    } catch let failure {
        #expect(MongoDBDatabaseAdapterFixtures.reportedCategory(failure) == .readOnlyViolation)
    }
    #expect(await client.plans().isEmpty)
    await session.disconnect()
}

private enum MongoDBDatabaseLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let requiredKeys = [
        "EDITH_DATABASE_MONGODB_HOST",
        "EDITH_DATABASE_MONGODB_PORT",
        "EDITH_DATABASE_MONGODB_DATABASE",
        "EDITH_DATABASE_MONGODB_AUTH_SOURCE",
        "EDITH_DATABASE_MONGODB_USERNAME",
        "EDITH_DATABASE_MONGODB_PASSWORD",
    ]
    static let isEnabled = requiredKeys.allSatisfy { values[$0]?.isEmpty == false }
}

@Test(.enabled(if: MongoDBDatabaseLiveEnvironment.isEnabled))
func mongoReadingLiveAuthenticatedBrowseAndQuery() async throws {
    let environment = MongoDBDatabaseLiveEnvironment.values
    let host = try #require(environment["EDITH_DATABASE_MONGODB_HOST"])
    let portText = try #require(environment["EDITH_DATABASE_MONGODB_PORT"])
    let port = try #require(Int(portText))
    let database = try #require(environment["EDITH_DATABASE_MONGODB_DATABASE"])
    let authSource = try #require(environment["EDITH_DATABASE_MONGODB_AUTH_SOURCE"])
    let username = try #require(environment["EDITH_DATABASE_MONGODB_USERNAME"])
    let password = try #require(environment["EDITH_DATABASE_MONGODB_PASSWORD"])
    let passwordReference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
    let definition = try MongoDBDatabaseAdapterFixtures.definition(
        location: .network([
            DatabaseNetworkEndpoint(
                host: host,
                port: try DatabasePort(port),
                role: .seed)
        ]),
        username: username,
        database: database,
        authentication: DatabaseAuthentication(
            kind: .scram,
            secretReferences: [passwordReference],
            source: authSource))
    let session = try await MongoDBDatabaseAdapter().connect(
        try MongoDBDatabaseAdapterFixtures.resolved(
            definition,
            secrets: [passwordReference: Data(password.utf8)]),
        context: MongoDBDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(15)))
    let report = try await session.discoverCapabilities(
        context: MongoDBDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(15)))
    #expect(report.productIdentity.product == .mongoDB)
    #expect(report.supports(.browse))
    let target = MongoDBDatabaseAdapterFixtures.target(
        connectionID: definition.id,
        database: database)
    let pageRequest = try DatabaseAdapterPageRequest(
        target: target,
        page: DatabasePageRequest(pageSize: try DatabasePageSize(3)),
        continuation: nil)
    let page = try await session.readPage(
        pageRequest,
        context: MongoDBDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(15)))
    #expect(!page.records.isEmpty)
    #expect(page.records.count <= 3)
    #expect(page.records.allSatisfy { $0.identity?.kind == .documentID })
    let query = try DatabaseAdapterQueryRequest(
        request: DatabaseQueryRequest(
            target: target,
            language: .mongoQuery,
            command: "find",
            body: .object([
                DatabaseObjectField(
                    name: "_id",
                    value: .object([
                        DatabaseObjectField(name: "$exists", value: .boolean(true))
                    ]))
            ]),
            page: DatabasePageRequest(pageSize: try DatabasePageSize(2))),
        continuation: nil)
    let queryPage = try await session.query(
        query,
        context: MongoDBDatabaseAdapterFixtures.context(
            deadline: Date().addingTimeInterval(15)))
    #expect(!queryPage.records.isEmpty)
    #expect(queryPage.records.count <= 2)
    print(
        "mongodb live verified version=\(report.productIdentity.version?.string ?? "unknown") browse=\(page.records.count) query=\(queryPage.records.count)")
    await session.disconnect()
}
