import Foundation
import Testing

@testable import EdithDatabase

private enum ElasticsearchDatabaseReadingFixtures {
    static let identity = DatabaseProductIdentity(
        product: .elasticsearch,
        version: DatabaseVersion(string: "9.5.2", major: 9, minor: 5, patch: 2),
        distribution: "Elasticsearch",
        topology: DatabaseTopology(
            kind: .standalone,
            name: "edith-search",
            localRole: "data",
            nodeCount: 1),
        serverIdentifier: "cluster-reading-fixture")

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        product: DatabaseProduct = .elasticsearch,
        endpoints: [DatabaseNetworkEndpoint]? = nil,
        username: String? = "reader",
        authentication: DatabaseAuthentication? = nil,
        tls: DatabaseTLSConfiguration = DatabaseTLSConfiguration(
            mode: .disabled,
            verification: .none),
        namespaces: DatabaseNamespaceDefaults = DatabaseNamespaceDefaults(),
        deploymentMode: DatabaseDeploymentMode = .automatic,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .required,
        productionPolicy: DatabaseProductionPolicy = .prohibitMutations,
        options: [DatabaseNonSecretOption] = []
    ) throws -> DatabaseConnectionDefinition {
        let password = DatabaseSecretReference(
            identifier: UUID(uuidString: "84E5657F-E315-45A4-9CDD-82ED91297B20")!,
            purpose: .password)
        return DatabaseConnectionDefinition(
            id: id,
            displayName: "Elasticsearch reading fixture",
            productHint: product,
            location: .network(
                try endpoints ?? [
                    DatabaseNetworkEndpoint(
                        host: "127.0.0.1",
                        port: DatabasePort(59_200),
                        role: .node)
                ]),
            username: username,
            namespaces: namespaces,
            deploymentMode: deploymentMode,
            authentication: authentication
                ?? DatabaseAuthentication(
                    kind: .usernameAndPassword,
                    secretReferences: [password]),
            tls: tls,
            limits: DatabaseConnectionLimits(
                connectionTimeout: try DatabaseTimeout(milliseconds: 2_000),
                operationTimeout: try DatabaseTimeout(milliseconds: 3_000),
                poolSize: try DatabasePoolSize(1)),
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
        _ definition: DatabaseConnectionDefinition
    ) throws -> DatabaseResolvedConnection {
        guard let reference = definition.authentication.secretReferences.first else {
            return try DatabaseResolvedConnection(definition: definition, secrets: [:])
        }
        return try DatabaseResolvedConnection(
            definition: definition,
            secrets: [reference: Data("fixture-password".utf8)])
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
        name: String = "edith-documents-v1",
        kind: DatabaseObjectKind = .index
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: kind, path: [name]))
    }

    static func discoveryTarget(
        connectionID: DatabaseConnectionID
    ) -> DatabaseTargetIdentifier {
        DatabaseTargetIdentifier(
            connectionID: connectionID,
            object: DatabaseObjectIdentifier(kind: .server, path: ["indices"]))
    }

    static func pageRequest(
        target: DatabaseTargetIdentifier,
        pageSize: Int = 2,
        continuation: DatabaseAdapterContinuation? = nil,
        projection: DatabaseProjection? = nil,
        filter: DatabaseFilter? = nil,
        sorts: [DatabaseSort] = []
    ) throws -> DatabaseAdapterPageRequest {
        try DatabaseAdapterPageRequest(
            target: target,
            page: DatabasePageRequest(
                pageSize: DatabasePageSize(pageSize),
                projection: projection,
                filter: filter,
                sorts: sorts),
            continuation: continuation)
    }

    static func queryRequest(
        source: DatabaseAdapterPageRequest,
        command: String,
        body: DatabaseValue?
    ) throws -> DatabaseAdapterQueryRequest {
        try DatabaseAdapterQueryRequest(
            request: DatabaseQueryRequest(
                target: source.target,
                language: .searchQueryDSL,
                command: command,
                parameters: [],
                body: body,
                page: DatabasePageRequest(
                    pageSize: source.pageSize,
                    projection: source.projection,
                    filter: source.filter,
                    sorts: source.sorts,
                    consistency: source.consistency)),
            continuation: source.continuation)
    }

    static let mapping = ElasticsearchDatabaseMappingResponse.Index(
        mappings: ElasticsearchDatabaseMappingResponse.Mapping(
            dynamic: .string("strict"),
            properties: [
                "category": ElasticsearchDatabaseMappingResponse.Field(
                    type: "keyword",
                    index: true,
                    enabled: nil,
                    docValues: true,
                    properties: nil,
                    fields: nil),
                "title": ElasticsearchDatabaseMappingResponse.Field(
                    type: "text",
                    index: true,
                    enabled: nil,
                    docValues: false,
                    properties: nil,
                    fields: [
                        "raw": ElasticsearchDatabaseMappingResponse.Field(
                            type: "keyword",
                            index: true,
                            enabled: nil,
                            docValues: true,
                            properties: nil,
                            fields: nil)
                    ]),
                "metrics": ElasticsearchDatabaseMappingResponse.Field(
                    type: "object",
                    index: nil,
                    enabled: true,
                    docValues: nil,
                    properties: [
                        "count": ElasticsearchDatabaseMappingResponse.Field(
                            type: "integer",
                            index: true,
                            enabled: nil,
                            docValues: true,
                            properties: nil,
                            fields: nil)
                    ],
                    fields: nil),
            ],
            runtime: nil))

    static func hit(
        id: String,
        category: String = "books",
        title: String? = nil,
        sort: Int64,
        highlight: [String: [String]]? = nil
    ) -> ElasticsearchDatabaseSearchResponse.Hit {
        var source: [String: ElasticsearchDatabaseJSONValue] = [
            "category": .string(category),
            "doc_id": .string(id),
        ]
        if let title { source["title"] = .string(title) }
        return ElasticsearchDatabaseSearchResponse.Hit(
            index: "edith-documents-v1",
            identifier: id,
            sequenceNumber: sort,
            primaryTerm: 1,
            source: .object(source),
            sort: [.signedInteger(sort)],
            highlight: highlight)
    }

    static func response(
        hits: [ElasticsearchDatabaseSearchResponse.Hit],
        total: UInt64 = 5,
        relation: ElasticsearchDatabaseSearchResponse.Relation = .equal,
        pit: String = "pit-refreshed",
        timedOut: Bool = false,
        shards: ElasticsearchDatabaseSearchResponse.Shards? = nil,
        aggregations: [String: ElasticsearchDatabaseJSONValue]? = nil
    ) -> ElasticsearchDatabaseSearchResponse {
        ElasticsearchDatabaseSearchResponse(
            took: 7,
            timedOut: timedOut,
            pointInTimeID: pit,
            shards: shards
                ?? ElasticsearchDatabaseSearchResponse.Shards(
                    total: 1,
                    successful: 1,
                    skipped: 0,
                    failed: 0,
                    failures: nil),
            hits: ElasticsearchDatabaseSearchResponse.Hits(
                total: ElasticsearchDatabaseSearchResponse.Total(
                    value: total,
                    relation: relation),
                hits: hits),
            aggregations: aggregations)
    }
}

private enum ElasticsearchDatabaseReadingOutcome: Sendable {
    case response(ElasticsearchDatabaseSearchResponse)
    case failure(ElasticsearchDatabaseDriverFailure)
    case stalled
}

private actor ElasticsearchDatabaseReadingClient: ElasticsearchDatabaseClient {
    private var identities: [DatabaseProductIdentity]
    private var outcomes: [ElasticsearchDatabaseReadingOutcome]
    private var pointInTimeIDs: [String]
    private let resolveFailure: ElasticsearchDatabaseDriverFailure?
    private let mappingFailure: ElasticsearchDatabaseDriverFailure?
    private var disconnected = false
    private var resolveCount = 0
    private var mappingCount = 0
    private var searches: [(Data, String)] = []
    private var closed: [String] = []
    private var disconnectCount = 0

    init(
        identities: [DatabaseProductIdentity] = [ElasticsearchDatabaseReadingFixtures.identity],
        outcomes: [ElasticsearchDatabaseReadingOutcome] = [],
        pointInTimeIDs: [String] = ["pit-opened"],
        resolveFailure: ElasticsearchDatabaseDriverFailure? = nil,
        mappingFailure: ElasticsearchDatabaseDriverFailure? = nil
    ) {
        self.identities = identities
        self.outcomes = outcomes
        self.pointInTimeIDs = pointInTimeIDs
        self.resolveFailure = resolveFailure
        self.mappingFailure = mappingFailure
    }

    func discoverIdentity() throws -> DatabaseProductIdentity {
        guard !disconnected, !identities.isEmpty else {
            throw ElasticsearchDatabaseDriverFailure.connection
        }
        if identities.count == 1 { return identities[0] }
        return identities.removeFirst()
    }

    func resolveIndexes() throws -> ElasticsearchDatabaseResolveResponse {
        resolveCount += 1
        if let resolveFailure { throw resolveFailure }
        return ElasticsearchDatabaseResolveResponse(
            indices: [
                ElasticsearchDatabaseResolveResponse.Index(
                    name: "edith-documents-v1",
                    aliases: ["edith_documents"],
                    attributes: ["open"],
                    dataStream: nil,
                    mode: "standard")
            ],
            aliases: [
                ElasticsearchDatabaseResolveResponse.Alias(
                    name: "edith_documents",
                    indices: ["edith-documents-v1"])
            ],
            dataStreams: [])
    }

    func mapping(
        target: String
    ) throws -> ElasticsearchDatabaseMappingResponse {
        mappingCount += 1
        if let mappingFailure { throw mappingFailure }
        return ElasticsearchDatabaseMappingResponse(indices: [
            target: ElasticsearchDatabaseReadingFixtures.mapping
        ])
    }

    func openPointInTime(
        target: String,
        keepAlive: String
    ) throws -> String {
        guard !disconnected, keepAlive == "60s", !pointInTimeIDs.isEmpty else {
            throw ElasticsearchDatabaseDriverFailure.connection
        }
        return pointInTimeIDs.removeFirst()
    }

    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> ElasticsearchDatabaseSearchResponse {
        searches.append((body, pointInTimeID))
        guard !outcomes.isEmpty else { throw ElasticsearchDatabaseDriverFailure.connection }
        let outcome = outcomes.removeFirst()
        switch outcome {
        case let .response(response):
            return response
        case let .failure(failure):
            throw failure
        case .stalled:
            while !disconnected {
                try await Task.sleep(for: .milliseconds(5))
            }
            throw ElasticsearchDatabaseDriverFailure.connection
        }
    }

    func closePointInTime(_ identifier: String) {
        closed.append(identifier)
    }

    func disconnect() {
        disconnected = true
        disconnectCount += 1
    }

    func snapshot() -> (
        resolve: Int, mapping: Int, searches: [(Data, String)], closed: [String], disconnects: Int
    ) {
        (resolveCount, mappingCount, searches, closed, disconnectCount)
    }
}

private func elasticsearchReadingSession(
    client: ElasticsearchDatabaseReadingClient,
    definition: DatabaseConnectionDefinition
) async throws -> any DatabaseAdapterSession {
    try await ElasticsearchDatabaseAdapter { _ in client }.connect(
        ElasticsearchDatabaseReadingFixtures.resolved(definition),
        context: ElasticsearchDatabaseReadingFixtures.context())
}

@Test func elasticsearchReadingBuildsStrictAuthenticatedConnectionPlan() throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let plan = try ElasticsearchDatabaseAdapterSupport.connectionPlan(
        ElasticsearchDatabaseReadingFixtures.resolved(definition),
        context: ElasticsearchDatabaseReadingFixtures.context(
            deadline: Date().addingTimeInterval(10)))
    #expect(plan.endpoint.absoluteString == "http://127.0.0.1:59200")
    #expect(plan.connectTimeoutMilliseconds == 2_000)
    #expect(plan.requestTimeoutMilliseconds == 3_000)
    #expect(plan.maximumResponseBytes == 16_777_216)
    #expect(
        plan.authorization
            == .basic(username: "reader", password: "fixture-password"))
}

@Test func elasticsearchReadingRejectsAmbiguousOrWritableConnections() throws {
    let endpoint = try DatabaseNetworkEndpoint(
        host: "127.0.0.1",
        port: DatabasePort(59_200),
        role: .node)
    for definition in [
        try ElasticsearchDatabaseReadingFixtures.definition(endpoints: [endpoint, endpoint]),
        try ElasticsearchDatabaseReadingFixtures.definition(
            namespaces: DatabaseNamespaceDefaults(database: "unsupported")),
        try ElasticsearchDatabaseReadingFixtures.definition(
            readOnlyPolicy: .disabled,
            productionPolicy: .standard),
        try ElasticsearchDatabaseReadingFixtures.definition(
            options: [DatabaseNonSecretOption(name: "path", value: .string("unsafe"))]),
        try ElasticsearchDatabaseReadingFixtures.definition(
            tls: DatabaseTLSConfiguration(mode: .preferred, verification: .none)),
    ] {
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try ElasticsearchDatabaseAdapterSupport.connectionPlan(
                ElasticsearchDatabaseReadingFixtures.resolved(definition),
                context: ElasticsearchDatabaseReadingFixtures.context())
        }
    }
}

@Test func elasticsearchReadingReportsBoundedReadOnlyCapabilities() throws {
    let report = ElasticsearchDatabaseAdapterSupport.capabilityReport(
        identity: ElasticsearchDatabaseReadingFixtures.identity,
        discoveredAt: Date(timeIntervalSince1970: 1_800_000_000))
    try DatabaseAdapterBounds.validate(
        report: report,
        identity: ElasticsearchDatabaseReadingFixtures.identity)
    #expect(report.supports(.connectionTest))
    #expect(report.supports(.browse))
    #expect(report.supports(.query))
    #expect(report.status(for: .objectDiscovery)?.availability == .degraded)
    #expect(report.status(for: .insert)?.reason?.category == .unsafe)
    #expect(report.pagingModes == [.pointInTime])
    #expect(report.mutationModes == [.unsupported])
    #expect(Set(report.capabilities.map(\.id)).count == report.capabilities.count)
}

@Test func elasticsearchReadingDiscoversIndexesAndAliasesLazily() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let client = ElasticsearchDatabaseReadingClient()
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    #expect(await client.snapshot().resolve == 0)
    let request = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: ElasticsearchDatabaseReadingFixtures.discoveryTarget(connectionID: definition.id),
        pageSize: 10)
    let page = try await session.readPage(
        request,
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(page.records.count == 2)
    #expect(page.metadata.completeness.state == .complete)
    #expect(page.metadata.count.value == 2)
    #expect(await client.snapshot().resolve == 1)
    #expect(await client.snapshot().mapping == 0)
    await session.disconnect()
}

@Test func elasticsearchReadingDegradesMetadataPermissionWithoutLeakingDetails() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let client = ElasticsearchDatabaseReadingClient(resolveFailure: .permission(403))
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let request = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: ElasticsearchDatabaseReadingFixtures.discoveryTarget(connectionID: definition.id))
    let page = try await session.readPage(
        request,
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(page.records.isEmpty)
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.metadata.warnings.first?.code == "elasticsearch.metadata.permission")
    #expect(!String(describing: page).contains("fixture-password"))
    await session.disconnect()
}

@Test func elasticsearchReadingUsesStablePITPagesAndMappingCache() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let firstResponse = ElasticsearchDatabaseReadingFixtures.response(
        hits: [
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1),
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-2", sort: 2),
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3),
        ],
        pit: "pit-second")
    let secondResponse = ElasticsearchDatabaseReadingFixtures.response(
        hits: [ElasticsearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3)],
        pit: "pit-final")
    let client = ElasticsearchDatabaseReadingClient(
        outcomes: [.response(firstResponse), .response(secondResponse)])
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let target = ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let firstRequest = try ElasticsearchDatabaseReadingFixtures.pageRequest(target: target)
    let first = try await session.readPage(
        firstRequest,
        context: ElasticsearchDatabaseReadingFixtures.context())
    let continuation = try #require(first.nextContinuation)
    #expect(
        first.records.map { $0.identity?.components[1].value } == [
            .string("doc-1"), .string("doc-2"),
        ])
    #expect(first.fields.contains { $0.displayName == "title.raw" && $0.isSortable })
    #expect(first.fields.contains { $0.displayName == "title" && !$0.isSortable })
    #expect(
        first.records[0].identity?.concurrencyTokens.map(\.name) == ["_seq_no", "_primary_term"])
    let secondRequest = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: target,
        continuation: continuation)
    let second = try await session.readPage(
        secondRequest,
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(second.records.map { $0.identity?.components[1].value } == [.string("doc-3")])
    #expect(second.nextContinuation == nil)
    let snapshot = await client.snapshot()
    #expect(snapshot.mapping == 1)
    #expect(snapshot.searches.map(\.1) == ["pit-opened", "pit-second"])
    #expect(snapshot.closed == ["pit-final"])
    await session.disconnect()
}

@Test func elasticsearchReadingCompilesProjectionFilterSortAndHighlight() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let response = ElasticsearchDatabaseReadingFixtures.response(
        hits: [
            ElasticsearchDatabaseReadingFixtures.hit(
                id: "doc-7",
                title: "Search systems",
                sort: 7,
                highlight: ["title": ["<em>Search</em> systems"]])
        ],
        total: 1)
    let client = ElasticsearchDatabaseReadingClient(outcomes: [.response(response)])
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let target = ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let source = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: target,
        projection: DatabaseProjection(
            mode: .include,
            fields: [DatabaseProjectedField(path: DatabaseFieldPath("title"))]),
        filter: .predicate(
            DatabaseFilterPredicate(
                field: DatabaseFieldPath("category"),
                operation: .equal,
                values: [.string("books")])),
        sorts: [
            DatabaseSort(field: DatabaseFieldPath(["title", "raw"]), direction: .ascending)
        ])
    let body: DatabaseValue = .object([
        DatabaseObjectField(
            name: "query",
            value: .object([
                DatabaseObjectField(
                    name: "match",
                    value: .object([
                        DatabaseObjectField(name: "title", value: .string("Search"))
                    ]))
            ])),
        DatabaseObjectField(
            name: "highlight",
            value: .object([
                DatabaseObjectField(
                    name: "fields",
                    value: .object([
                        DatabaseObjectField(name: "title", value: .object([]))
                    ])),
                DatabaseObjectField(name: "fragment_size", value: .signedInteger(120)),
            ])),
    ])
    let request = try ElasticsearchDatabaseReadingFixtures.queryRequest(
        source: source,
        command: "search",
        body: body)
    let page = try await session.query(
        request,
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(page.records[0].fields.contains { $0.name == "_highlight" })
    let submitted = try #require(await client.snapshot().searches.first?.0)
    let json = try JSONSerialization.jsonObject(with: submitted) as? [String: Any]
    #expect(json?["_source"] != nil)
    #expect(json?["query"] != nil)
    #expect((json?["sort"] as? [Any])?.count == 2)
    #expect(json?["highlight"] != nil)
    #expect(json?["from"] == nil)
    await session.disconnect()
}

@Test func elasticsearchReadingReturnsBoundedAggregations() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let response = ElasticsearchDatabaseReadingFixtures.response(
        hits: [],
        total: 0,
        aggregations: [
            "categories": .object([
                "buckets": .array([
                    .object(["key": .string("books"), "doc_count": .signedInteger(42)])
                ])
            ])
        ])
    let client = ElasticsearchDatabaseReadingClient(outcomes: [.response(response)])
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let source = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id))
    let body: DatabaseValue = .object([
        DatabaseObjectField(
            name: "aggs",
            value: .object([
                DatabaseObjectField(
                    name: "categories",
                    value: .object([
                        DatabaseObjectField(
                            name: "terms",
                            value: .object([
                                DatabaseObjectField(name: "field", value: .string("category")),
                                DatabaseObjectField(name: "size", value: .signedInteger(10)),
                            ]))
                    ]))
            ]))
    ])
    let page = try await session.query(
        ElasticsearchDatabaseReadingFixtures.queryRequest(
            source: source,
            command: "aggregate",
            body: body),
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(page.records.count == 1)
    #expect(page.records[0].fields.first?.name == "categories")
    #expect(page.nextContinuation == nil)
    #expect(await client.snapshot().closed == ["pit-refreshed"])
    await session.disconnect()
}

@Test func elasticsearchReadingRejectsDangerousDSLAndTargets() throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let source = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id))
    for field in ["script", "from", "search_after", "runtime_mappings"] {
        let body: DatabaseValue = .object([
            DatabaseObjectField(
                name: "query",
                value: .object([
                    DatabaseObjectField(name: field, value: .object([]))
                ]))
        ])
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try ElasticsearchDatabaseReadCompiler.compileQuery(
                ElasticsearchDatabaseReadingFixtures.queryRequest(
                    source: source,
                    command: "search",
                    body: body),
                sessionID: DatabaseAdapterSessionID(),
                requestTimeoutMilliseconds: 1_000)
        }
    }
    for command in ["scroll", "delete", "_search", "update_by_query"] {
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try ElasticsearchDatabaseReadCompiler.compileQuery(
                ElasticsearchDatabaseReadingFixtures.queryRequest(
                    source: source,
                    command: command,
                    body: nil),
                sessionID: DatabaseAdapterSessionID(),
                requestTimeoutMilliseconds: 1_000)
        }
    }
    let unsafeTarget = ElasticsearchDatabaseReadingFixtures.target(
        connectionID: definition.id,
        name: "_all")
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try ElasticsearchDatabaseReadCompiler.compileBrowse(
            ElasticsearchDatabaseReadingFixtures.pageRequest(target: unsafeTarget),
            sessionID: DatabaseAdapterSessionID(),
            requestTimeoutMilliseconds: 1_000)
    }
}

@Test func elasticsearchReadingBindsAndExpiresContinuations() throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let sessionID = DatabaseAdapterSessionID()
    let target = ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let request = try ElasticsearchDatabaseReadingFixtures.pageRequest(target: target)
    let first = try ElasticsearchDatabaseReadCompiler.compileBrowse(
        request,
        sessionID: sessionID,
        requestTimeoutMilliseconds: 1_000,
        now: Date(timeIntervalSince1970: 100))
    let continuation = try ElasticsearchDatabaseReadCompiler.nextContinuation(
        sessionID: sessionID,
        request: request,
        digest: first.requestDigest,
        pointInTimeID: "pit-bound",
        sort: [.signedInteger(2)],
        now: Date(timeIntervalSince1970: 100))
    let resumed = try ElasticsearchDatabaseReadingFixtures.pageRequest(
        target: target,
        continuation: continuation)
    _ = try ElasticsearchDatabaseReadCompiler.compileBrowse(
        resumed,
        sessionID: sessionID,
        requestTimeoutMilliseconds: 1_000,
        now: Date(timeIntervalSince1970: 120))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try ElasticsearchDatabaseReadCompiler.compileBrowse(
            resumed,
            sessionID: DatabaseAdapterSessionID(),
            requestTimeoutMilliseconds: 1_000,
            now: Date(timeIntervalSince1970: 120))
    }
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try ElasticsearchDatabaseReadCompiler.compileBrowse(
            resumed,
            sessionID: sessionID,
            requestTimeoutMilliseconds: 1_000,
            now: Date(timeIntervalSince1970: 161))
    }
    let malformed = try DatabaseAdapterContinuation(
        mode: .pointInTime,
        payload: Data("not-json".utf8),
        expiresAt: Date(timeIntervalSince1970: 200))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try ElasticsearchDatabaseReadCompiler.compileBrowse(
            ElasticsearchDatabaseReadingFixtures.pageRequest(
                target: target,
                continuation: malformed),
            sessionID: sessionID,
            requestTimeoutMilliseconds: 1_000,
            now: Date(timeIntervalSince1970: 120))
    }
}

@Test func elasticsearchReadingLabelsPartialAndLowerBoundResults() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let shards = ElasticsearchDatabaseSearchResponse.Shards(
        total: 2,
        successful: 1,
        skipped: 0,
        failed: 1,
        failures: [
            ElasticsearchDatabaseSearchResponse.Failure(index: "private-index", shard: 1)
        ])
    let response = ElasticsearchDatabaseReadingFixtures.response(
        hits: [ElasticsearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1)],
        total: 10_000,
        relation: .greaterThanOrEqual,
        timedOut: true,
        shards: shards)
    let client = ElasticsearchDatabaseReadingClient(
        outcomes: [.response(response)],
        mappingFailure: .permission(403))
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let page = try await session.readPage(
        ElasticsearchDatabaseReadingFixtures.pageRequest(
            target: ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)),
        context: ElasticsearchDatabaseReadingFixtures.context())
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.metadata.count.accuracy == .lowerBound)
    #expect(page.metadata.partialFailures.count == 1)
    #expect(page.metadata.warnings.map(\.code).contains("elasticsearch.mapping.permission"))
    let encoded = String(data: try JSONEncoder().encode(page.metadata), encoding: .utf8) ?? ""
    #expect(!encoded.contains("private-index"))
    #expect(!encoded.contains("fixture-password"))
    await session.disconnect()
}

@Test func elasticsearchReadingRejectsMalformedSortAndResponseOverflow() throws {
    let malformed = ElasticsearchDatabaseReadingFixtures.response(
        hits: [
            ElasticsearchDatabaseSearchResponse.Hit(
                index: "edith-documents-v1",
                identifier: "doc-1",
                sequenceNumber: 1,
                primaryTerm: 1,
                source: .object([:]),
                sort: [.object(["unsafe": .string("token")])],
                highlight: nil)
        ])
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidResponse) {
        try ElasticsearchDatabaseDriverSupport.validate(malformed)
    }
    let excessiveHits = (0...(DatabasePageSize.range.upperBound + 1)).map {
        ElasticsearchDatabaseReadingFixtures.hit(id: "doc-" + String($0), sort: Int64($0))
    }
    let excessive = ElasticsearchDatabaseReadingFixtures.response(hits: excessiveHits)
    #expect(throws: ElasticsearchDatabaseDriverFailure.invalidResponse) {
        try ElasticsearchDatabaseDriverSupport.validate(excessive)
    }
}

@Test func elasticsearchReadingMapsPITExpiryAndCleansTheCursor() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let firstResponse = ElasticsearchDatabaseReadingFixtures.response(
        hits: [
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1),
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-2", sort: 2),
            ElasticsearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3),
        ],
        pit: "pit-expiring")
    let client = ElasticsearchDatabaseReadingClient(
        outcomes: [.response(firstResponse), .failure(.server(404))])
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let target = ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let first = try await session.readPage(
        ElasticsearchDatabaseReadingFixtures.pageRequest(target: target),
        context: ElasticsearchDatabaseReadingFixtures.context())
    let continuation = try #require(first.nextContinuation)
    await #expect(throws: ElasticsearchDatabaseAdapterSupport.invalidContinuation) {
        _ = try await session.readPage(
            ElasticsearchDatabaseReadingFixtures.pageRequest(
                target: target,
                continuation: continuation),
            context: ElasticsearchDatabaseReadingFixtures.context())
    }
    #expect(await client.snapshot().closed.contains("pit-expiring"))
    await session.disconnect()
}

@Test func elasticsearchReadingCancelsPromptlyAndReconnects() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let operationID = DatabaseOperationID()
    let client = ElasticsearchDatabaseReadingClient(outcomes: [.stalled])
    let session = try await elasticsearchReadingSession(client: client, definition: definition)
    let task = Task {
        try await session.readPage(
            ElasticsearchDatabaseReadingFixtures.pageRequest(
                target: ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)),
            context: ElasticsearchDatabaseReadingFixtures.context(operationID: operationID))
    }
    while await client.snapshot().searches.isEmpty {
        try await Task.sleep(for: .milliseconds(2))
    }
    let startedAt = ContinuousClock.now
    let result = await session.cancel(operationID)
    #expect(result.disposition == .accepted)
    await #expect(throws: DatabaseAdapterFailure.cancelled) {
        _ = try await task.value
    }
    #expect(ContinuousClock.now - startedAt < .seconds(1))
    #expect(await session.lifecycleState() == .failed)
    let replacementClient = ElasticsearchDatabaseReadingClient()
    let replacement = try await elasticsearchReadingSession(
        client: replacementClient,
        definition: definition)
    #expect(replacement.productIdentity.product == .elasticsearch)
    await replacement.disconnect()
}

@Test func elasticsearchReadingEnforcesDeadlineAndIdentityStability() async throws {
    let definition = try ElasticsearchDatabaseReadingFixtures.definition()
    let deadlineClient = ElasticsearchDatabaseReadingClient(outcomes: [.stalled])
    let deadlineSession = try await elasticsearchReadingSession(
        client: deadlineClient,
        definition: definition)
    let startedAt = ContinuousClock.now
    await #expect(throws: ElasticsearchDatabaseAdapterSupport.deadlineExceeded) {
        _ = try await deadlineSession.readPage(
            ElasticsearchDatabaseReadingFixtures.pageRequest(
                target: ElasticsearchDatabaseReadingFixtures.target(connectionID: definition.id)),
            context: ElasticsearchDatabaseReadingFixtures.context(
                deadline: Date().addingTimeInterval(0.05)))
    }
    #expect(ContinuousClock.now - startedAt < .seconds(1))
    let drifted = DatabaseProductIdentity(
        product: .elasticsearch,
        version: DatabaseVersion(string: "9.5.3", major: 9, minor: 5, patch: 3),
        distribution: "Elasticsearch",
        topology: DatabaseTopology(kind: .standalone),
        serverIdentifier: "other-cluster")
    let driftClient = ElasticsearchDatabaseReadingClient(
        identities: [ElasticsearchDatabaseReadingFixtures.identity, drifted])
    let driftSession = try await elasticsearchReadingSession(
        client: driftClient,
        definition: definition)
    await #expect(throws: DatabaseAdapterFailure.self) {
        _ = try await driftSession.discoverCapabilities(
            context: ElasticsearchDatabaseReadingFixtures.context())
    }
    #expect(await driftSession.lifecycleState() == .failed)
    #expect(await driftClient.snapshot().disconnects == 1)
}
