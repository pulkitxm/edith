import Foundation
import MongoCore
import MongoKitten
import NIOCore
import NIOPosix
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
        options: [DatabaseNonSecretOption] = [],
        connectionTimeoutMilliseconds: UInt64 = 2_000
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
                connectionTimeout: try DatabaseTimeout(
                    milliseconds: connectionTimeoutMilliseconds),
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

    static func identifiedTarget(
        connectionID: DatabaseConnectionID,
        identifier: MongoAdapterValue = .productSpecific(
            DatabaseProductValue(
                product: .mongoDB,
                typeName: "objectId",
                textRepresentation: objectIDs[0].hexString))
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(
                kind: .collection,
                path: ["edith_scale", "events"]),
            record: DatabaseRecordIdentity(
                kind: .documentID,
                components: [
                    DatabaseIdentityComponent(name: "_id", value: identifier)
                ]))
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
        let adapter = MongoDBDatabaseAdapter { plan, _ in
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
    private let failsDisconnect: Bool
    private let cancellationAfterRead: DatabaseAdapterCancellationSignal?
    private let collectionNames: [String]
    private var mutationResults: [MongoDBDatabaseMutationResult]
    private var disconnected = false
    private var readPlans: [MongoDBDatabaseReadPlan] = []
    private var collectionPlans: [MongoDBDatabaseCollectionPlan] = []
    private var mutationPlans: [MongoDBDatabaseMutationPlan] = []
    private var disconnects = 0

    init(
        identity: DatabaseProductIdentity = MongoDBDatabaseAdapterFixtures.identity,
        outcomes: [Outcome] = [],
        suspendsReads: Bool = false,
        failsDisconnect: Bool = false,
        cancellationAfterRead: DatabaseAdapterCancellationSignal? = nil,
        collectionNames: [String] = [],
        mutationResults: [MongoDBDatabaseMutationResult] = []
    ) {
        self.identity = identity
        self.outcomes = outcomes
        self.suspendsReads = suspendsReads
        self.failsDisconnect = failsDisconnect
        self.cancellationAfterRead = cancellationAfterRead
        self.collectionNames = collectionNames
        self.mutationResults = mutationResults
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
            if let cancellationAfterRead {
                await cancellationAfterRead.cancel(.userRequested)
            }
            return result
        case let .failure(failure):
            throw failure
        case .cancelled:
            throw CancellationError()
        }
    }

    func listCollections(
        _ plan: MongoDBDatabaseCollectionPlan
    ) async throws -> MongoDBDatabaseCollectionResult {
        collectionPlans.append(plan)
        let names = Array(collectionNames.prefix(plan.limit))
        return MongoDBDatabaseCollectionResult(
            names: names,
            hasMore: collectionNames.count > names.count)
    }

    func mutate(
        _ plan: MongoDBDatabaseMutationPlan
    ) async throws -> MongoDBDatabaseMutationResult {
        mutationPlans.append(plan)
        guard !mutationResults.isEmpty else {
            return MongoDBDatabaseMutationResult(
                insertedCount: 0,
                matchedCount: 0,
                modifiedCount: 0,
                deletedCount: 0)
        }
        return mutationResults.removeFirst()
    }

    func disconnect() async throws {
        disconnected = true
        disconnects += 1
        if failsDisconnect {
            throw MongoDBDatabaseDriverFailure.connection
        }
    }

    func plans() -> [MongoDBDatabaseReadPlan] {
        readPlans
    }

    func discoveredCollectionPlans() -> [MongoDBDatabaseCollectionPlan] {
        collectionPlans
    }

    func mutations() -> [MongoDBDatabaseMutationPlan] {
        mutationPlans
    }

    func disconnectCount() -> Int {
        disconnects
    }
}

@Test func mongoReadingDiscoversCollectionsWithBoundedContinuation() async throws {
    let client = MongoDBDatabaseAdapterTestClient(
        collectionNames: ["events", "users", "audit"])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let target = DatabaseTargetIdentifier(
        connectionID: definition.id,
        object: DatabaseObjectIdentifier(kind: .database, path: ["edith_scale"]))
    let firstRequest = try DatabaseAdapterPageRequest(
        target: target,
        page: DatabasePageRequest(pageSize: try DatabasePageSize(2)),
        continuation: nil)

    let first = try await session.readPage(
        firstRequest,
        context: MongoDBDatabaseAdapterFixtures.context())

    #expect(
        first.records.compactMap { record in
            guard
                case .string(let value)? = record.fields.first(where: { $0.name == "name" })?.value
            else { return nil }
            return value
        } == ["events", "users"])
    let continuation = try #require(first.nextContinuation)
    let secondRequest = try DatabaseAdapterPageRequest(
        target: target,
        page: DatabasePageRequest(pageSize: try DatabasePageSize(2)),
        continuation: continuation)

    let second = try await session.readPage(
        secondRequest,
        context: MongoDBDatabaseAdapterFixtures.context())

    #expect(
        second.records.compactMap { record in
            guard
                case .string(let value)? = record.fields.first(where: { $0.name == "name" })?.value
            else { return nil }
            return value
        } == ["audit"])
    #expect(second.nextContinuation == nil)
    let plans = await client.discoveredCollectionPlans()
    #expect(plans.map(\.limit) == [3, 5])
    await session.disconnect()
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

private actor MongoDBDatabaseConversionCancellationProbe {
    private var remainingChecks: Int

    init(remainingChecks: Int) {
        self.remainingChecks = remainingChecks
    }

    func check(signal: DatabaseAdapterCancellationSignal) async {
        remainingChecks -= 1
        if remainingChecks == 0 {
            await signal.cancel(.userRequested)
        }
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
    guard case let .scramSha256(username, password) = plan.settings.authentication else {
        Issue.record("Expected SCRAM-SHA-256 authentication")
        return
    }
    #expect(username == "reader")
    #expect(password == "fixture-password")
    await session.disconnect()
}

@Test func mongoReadingStalledHandshakeHonorsTheConfiguredWallTime() async throws {
    let serverGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let server = try await ServerBootstrap(group: serverGroup)
        .childChannelInitializer { channel in
            channel.eventLoop.makeSucceededVoidFuture()
        }
        .bind(host: "127.0.0.1", port: 0)
        .get()
    guard let port = server.localAddress?.port else {
        try await server.close().get()
        try await serverGroup.shutdownGracefully()
        Issue.record("Expected a bound server port")
        return
    }
    let definition = try MongoDBDatabaseAdapterFixtures.definition(
        location: .network([
            DatabaseNetworkEndpoint(
                host: "localhost",
                port: try DatabasePort(port),
                role: .seed)
        ]),
        connectionTimeoutMilliseconds: 200)
    let started = ContinuousClock.now
    var observedFailure: DatabaseAdapterFailure?
    do {
        _ = try await MongoDBDatabaseAdapter().connect(
            try MongoDBDatabaseAdapterFixtures.resolved(definition),
            context: MongoDBDatabaseAdapterFixtures.context(
                deadline: Date().addingTimeInterval(3)))
        Issue.record("Expected the stalled handshake to time out")
    } catch let failure {
        observedFailure = failure
    }
    let elapsed = started.duration(to: .now)
    try await server.close().get()
    try await serverGroup.shutdownGracefully()
    #expect(
        observedFailure.map(MongoDBDatabaseAdapterFixtures.reportedCategory) == .timeout)
    #expect(elapsed < .seconds(2))
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
            location: .network([
                DatabaseNetworkEndpoint(
                    host: String(repeating: "a", count: 64) + ".test",
                    port: try DatabasePort(27_017))
            ])),
        try MongoDBDatabaseAdapterFixtures.definition(
            location: .network([
                DatabaseNetworkEndpoint(
                    host: "mongo.exámple.test",
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

@Test func mongoReadingConnectionRejectsUnsupportedSCRAMPasswordsBeforeNetwork() throws {
    let reference = DatabaseSecretReference(identifier: UUID(), purpose: .password)
    let definition = try MongoDBDatabaseAdapterFixtures.definition(
        username: "reader",
        authentication: DatabaseAuthentication(
            kind: .scram,
            secretReferences: [reference]))
    #expect(throws: DatabaseAdapterFailure.self) {
        try MongoDBDatabaseAdapterSupport.connectionPlan(
            try MongoDBDatabaseAdapterFixtures.resolved(
                definition,
                secrets: [reference: Data("password\u{00AD}".utf8)]))
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

@Test func mongoReadingCapabilitiesExposeGuardedSingleDocumentMutations() async throws {
    let client = MongoDBDatabaseAdapterTestClient()
    let (session, _) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let report = try await session.discoverCapabilities(
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(report.productIdentity.product == .mongoDB)
    #expect(report.supports(.browse))
    #expect(report.supports(.query))
    #expect(report.supports(.queryCancellation))
    #expect(!report.supports(.objectDiscovery))
    #expect(report.supports(.insert))
    #expect(report.supports(.update))
    #expect(report.supports(.delete))
    #expect(!report.supports(.bulkMutation))
    #expect(report.pagingModes == [.keyset])
    #expect(report.mutationModes == [.singleRecord])
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
            #expect(
                MongoDBDatabaseAdapterFixtures.reportedCode(failure)
                    == "mongodb.continuation.invalid")
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
        #expect(
            MongoDBDatabaseAdapterFixtures.reportedCode(failure)
                == "mongodb.continuation.invalid")
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

@Test func mongoReadingConversionChecksCancellationWithinNestedValues() async throws {
    var nested = Document()
    for index in 0..<256 {
        nested["field-\(index)"] = String(repeating: "x", count: 512)
    }
    var document = MongoDBDatabaseAdapterFixtures.document(index: 0)
    document["nested"] = nested
    let signal = DatabaseAdapterCancellationSignal()
    let context = MongoDBDatabaseAdapterFixtures.context(cancellation: signal)
    let probe = MongoDBDatabaseConversionCancellationProbe(remainingChecks: 20)
    do {
        _ = try await MongoDBDatabaseValueCodec.convertedRecord(
            document,
            hidesObjectID: false,
            cancellationCheck: {
                await probe.check(signal: signal)
                try await MongoDBDatabaseAdapterSupport.check(context)
            })
        Issue.record("Expected cancellation during BSON conversion")
    } catch let failure as DatabaseAdapterFailure {
        #expect(failure == .cancelled)
    }
}

@Test func mongoReadingConversionChecksCancellationWithinScalarPreviews() async throws {
    var document = Document()
    document["payload"] = String(repeating: "x", count: 1_000_000)
    let signal = DatabaseAdapterCancellationSignal()
    let context = MongoDBDatabaseAdapterFixtures.context(cancellation: signal)
    let probe = MongoDBDatabaseConversionCancellationProbe(remainingChecks: 7)
    do {
        _ = try await MongoDBDatabaseValueCodec.convertedRecord(
            document,
            hidesObjectID: false,
            cancellationCheck: {
                await probe.check(signal: signal)
                try await MongoDBDatabaseAdapterSupport.check(context)
            })
        Issue.record("Expected cancellation during the scalar preview")
    } catch let failure as DatabaseAdapterFailure {
        #expect(failure == .cancelled)
    }
}

@Test func mongoReadingConversionCancellationFailsTheActiveSessionClosed() async throws {
    let signal = DatabaseAdapterCancellationSignal()
    let client = MongoDBDatabaseAdapterTestClient(
        outcomes: [
            .result(
                MongoDBDatabaseReadResult(
                    documents: [MongoDBDatabaseAdapterFixtures.document(index: 0)],
                    hasMore: false,
                    bytesReceived: 64))
        ],
        cancellationAfterRead: signal)
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    do {
        _ = try await session.readPage(
            try MongoDBDatabaseAdapterFixtures.request(connectionID: definition.id),
            context: MongoDBDatabaseAdapterFixtures.context(cancellation: signal))
        Issue.record("Expected cancellation before BSON conversion")
    } catch let failure as DatabaseAdapterFailure {
        #expect(failure == .cancelled)
    }
    #expect(await session.lifecycleState() == .failed)
    #expect(await client.disconnectCount() == 1)
}

@Test func mongoReadingDisconnectFailureKeepsTheSessionFailedAndRetryable() async throws {
    let client = MongoDBDatabaseAdapterTestClient(failsDisconnect: true)
    let (session, _) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let concreteSession = try #require(session as? MongoDBDatabaseAdapterSession)
    await session.disconnect()
    #expect(await session.lifecycleState() == .failed)
    #expect(await concreteSession.resourceIsOpen())
    #expect(await client.disconnectCount() == 1)
    await session.disconnect()
    #expect(await client.disconnectCount() == 2)
}

@Test func mongoReadingOversizedDriverResultMapsToResourceLimit() {
    let failure = MongoDBDatabaseAdapterSupport.map(
        .responseTooLarge,
        fallback: MongoDBDatabaseAdapterSupport.readFailed)
    #expect(MongoDBDatabaseAdapterFixtures.reportedCategory(failure) == .resourceLimit)
    #expect(MongoDBDatabaseAdapterFixtures.reportedCode(failure) == "mongodb.result.too_large")
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

@Test func mongoDocumentMutationRequestsAreCanonicalAndIdentityBound() throws {
    let connectionID = DatabaseConnectionID()
    let collection = MongoDBDatabaseAdapterFixtures.target(connectionID: connectionID)
    let identified = MongoDBDatabaseAdapterFixtures.identifiedTarget(
        connectionID: connectionID)
    let insert = try DatabaseDocumentMutationRequests.mongoDBInsert(
        target: collection,
        document: .object([
            DatabaseObjectField(name: "name", value: .string("created")),
            DatabaseObjectField(name: "sequence", value: .signedInteger(8)),
        ]))
    #expect(insert.payload.command == "insertOne")
    #expect(insert.target.record == nil)
    let update = try DatabaseDocumentMutationRequests.mongoDBUpdate(
        target: identified,
        values: [DatabaseObjectField(name: "name", value: .string("updated"))])
    #expect(update.payload.command == "updateOne")
    #expect(update.target.record?.kind == .documentID)
    let delete = try DatabaseDocumentMutationRequests.mongoDBDelete(target: identified)
    #expect(delete.payload.command == "deleteOne")
    #expect(delete.payload.body == .null)
    #expect(throws: DatabaseDocumentMutationRequestError.self) {
        try DatabaseDocumentMutationRequests.mongoDBUpdate(
            target: identified,
            values: [DatabaseObjectField(name: "_id", value: .string("replacement"))])
    }
    #expect(throws: DatabaseDocumentMutationRequestError.self) {
        try DatabaseDocumentMutationRequests.mongoDBInsert(
            target: collection,
            document: .object([
                DatabaseObjectField(name: "$where", value: .string("unsafe"))
            ]))
    }
}

@Test func mongoDocumentMutationsNormalizeAndExecuteOneDocument() async throws {
    let client = MongoDBDatabaseAdapterTestClient(
        mutationResults: [
            MongoDBDatabaseMutationResult(
                insertedCount: 1,
                matchedCount: 0,
                modifiedCount: 0,
                deletedCount: 0),
            MongoDBDatabaseMutationResult(
                insertedCount: 0,
                matchedCount: 1,
                modifiedCount: 1,
                deletedCount: 0),
            MongoDBDatabaseMutationResult(
                insertedCount: 0,
                matchedCount: 0,
                modifiedCount: 0,
                deletedCount: 1),
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let collection = MongoDBDatabaseAdapterFixtures.target(connectionID: definition.id)
    let identified = MongoDBDatabaseAdapterFixtures.identifiedTarget(
        connectionID: definition.id)
    let requests = [
        try DatabaseDocumentMutationRequests.mongoDBInsert(
            target: collection,
            document: .object([
                DatabaseObjectField(name: "name", value: .string("created"))
            ])),
        try DatabaseDocumentMutationRequests.mongoDBUpdate(
            target: identified,
            values: [DatabaseObjectField(name: "name", value: .string("updated"))]),
        try DatabaseDocumentMutationRequests.mongoDBDelete(target: identified),
    ]
    let expectedActions: [DatabaseDestructiveAction] = [.insert, .update, .delete]
    for (request, action) in zip(requests, expectedActions) {
        let plan = try await session.normalizeMutation(
            request,
            context: MongoDBDatabaseAdapterFixtures.context())
        #expect(plan.action == action)
        #expect(plan.impact.count == DatabaseCountMetadata(value: 1, accuracy: .exact))
        #expect(plan.transactionBehavior == .nontransactional)
        #expect(plan.rollbackAvailability == .unavailable)
        let result = try await session.executeMutation(
            plan,
            context: MongoDBDatabaseAdapterFixtures.context())
        #expect(result.disposition == .completed)
        #expect(result.effect == .applied)
        #expect(result.affectedRecords.value == 1)
    }
    let plans = await client.mutations()
    #expect(plans.count == 3)
    #expect(plans.allSatisfy { $0.database == "edith_scale" })
    #expect(plans.allSatisfy { $0.collection == "events" })
    guard case let .update(filter, values) = plans[1].operation else {
        Issue.record("Expected a MongoDB update plan")
        return
    }
    #expect(filter["_id"] as? ObjectId == MongoDBDatabaseAdapterFixtures.objectIDs[0])
    #expect(values["name"] as? String == "updated")
    await session.disconnect()
}

@Test func mongoDocumentMutationMissingIdentityReturnsExactConflict() async throws {
    let client = MongoDBDatabaseAdapterTestClient(
        mutationResults: [
            MongoDBDatabaseMutationResult(
                insertedCount: 0,
                matchedCount: 0,
                modifiedCount: 0,
                deletedCount: 0)
        ])
    let (session, definition) = try await MongoDBDatabaseAdapterFixtures.connect(client: client)
    let request = try DatabaseDocumentMutationRequests.mongoDBDelete(
        target: MongoDBDatabaseAdapterFixtures.identifiedTarget(
            connectionID: definition.id))
    let plan = try await session.normalizeMutation(
        request,
        context: MongoDBDatabaseAdapterFixtures.context())
    let result = try await session.executeMutation(
        plan,
        context: MongoDBDatabaseAdapterFixtures.context())
    #expect(result.effect == .notApplied)
    #expect(result.affectedRecords == DatabaseCountMetadata(value: 0, accuracy: .exact))
    #expect(result.error?.category == .conflict)
    await session.disconnect()
}

@Test func mongoDocumentMutationRejectsNonCanonicalRequestsBeforeTheDriver() async throws {
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
        Issue.record("Expected invalid mutation rejection")
    } catch let failure {
        #expect(MongoDBDatabaseAdapterFixtures.reportedCategory(failure) == .invalidRequest)
    }
    #expect(await client.mutations().isEmpty)
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
        database: database,
        collection: "records")
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
    let version = report.productIdentity.version?.string ?? "unknown"
    print(
        "mongodb live verified version=\(version) "
            + "browse=\(page.records.count) query=\(queryPage.records.count)")
    await session.disconnect()
}
