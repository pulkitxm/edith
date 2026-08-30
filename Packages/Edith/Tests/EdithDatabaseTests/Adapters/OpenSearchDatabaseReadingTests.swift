import CryptoKit
import Foundation
import Testing

@testable import EdithDatabase

private enum OpenSearchDatabaseReadingFixtures {
    static let identity = DatabaseProductIdentity(
        product: .openSearch,
        version: DatabaseVersion(string: "3.8.0", major: 3, minor: 8, patch: 0),
        distribution: "OpenSearch",
        topology: DatabaseTopology(
            kind: .standalone,
            name: "edith-search",
            localRole: "data",
            nodeCount: 1),
        serverIdentifier: "cluster-reading-fixture")

    static func definition(
        id: DatabaseConnectionID = DatabaseConnectionID(),
        product: DatabaseProduct = .openSearch,
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
            displayName: "OpenSearch reading fixture",
            productHint: product,
            location: .network(
                try endpoints ?? [
                    DatabaseNetworkEndpoint(
                        host: "127.0.0.1",
                        port: DatabasePort(59_201),
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

    static let mapping = OpenSearchDatabaseMappingResponse.Index(
        mappings: OpenSearchDatabaseMappingResponse.Mapping(
            dynamic: .string("strict"),
            properties: [
                "category": OpenSearchDatabaseMappingResponse.Field(
                    type: "keyword",
                    index: true,
                    enabled: nil,
                    docValues: true,
                    properties: nil,
                    fields: nil),
                "title": OpenSearchDatabaseMappingResponse.Field(
                    type: "text",
                    index: true,
                    enabled: nil,
                    docValues: false,
                    properties: nil,
                    fields: [
                        "raw": OpenSearchDatabaseMappingResponse.Field(
                            type: "keyword",
                            index: true,
                            enabled: nil,
                            docValues: true,
                            properties: nil,
                            fields: nil)
                    ]),
                "metrics": OpenSearchDatabaseMappingResponse.Field(
                    type: "object",
                    index: nil,
                    enabled: true,
                    docValues: nil,
                    properties: [
                        "count": OpenSearchDatabaseMappingResponse.Field(
                            type: "integer",
                            index: true,
                            enabled: nil,
                            docValues: true,
                            properties: nil,
                            fields: nil)
                    ],
                    fields: nil),
            ],
            runtime: nil,
            derived: nil))

    static func hit(
        id: String,
        category: String = "books",
        title: String? = nil,
        sort: Int64,
        highlight: [String: [String]]? = nil
    ) -> OpenSearchDatabaseSearchResponse.Hit {
        var source: [String: OpenSearchDatabaseJSONValue] = [
            "category": .string(category),
            "doc_id": .string(id),
        ]
        if let title { source["title"] = .string(title) }
        return OpenSearchDatabaseSearchResponse.Hit(
            index: "edith-documents-v1",
            identifier: id,
            sequenceNumber: sort,
            primaryTerm: 1,
            source: .object(source),
            sort: [.signedInteger(sort)],
            highlight: highlight)
    }

    static func response(
        hits: [OpenSearchDatabaseSearchResponse.Hit],
        total: UInt64 = 5,
        relation: OpenSearchDatabaseSearchResponse.Relation = .equal,
        pit: String = "pit-refreshed",
        timedOut: Bool = false,
        shards: OpenSearchDatabaseSearchResponse.Shards? = nil,
        aggregations: [String: OpenSearchDatabaseJSONValue]? = nil
    ) -> OpenSearchDatabaseSearchResponse {
        OpenSearchDatabaseSearchResponse(
            took: 7,
            timedOut: timedOut,
            pointInTimeID: pit,
            shards: shards
                ?? OpenSearchDatabaseSearchResponse.Shards(
                    total: 1,
                    successful: 1,
                    skipped: 0,
                    failed: 0,
                    failures: nil),
            hits: OpenSearchDatabaseSearchResponse.Hits(
                total: OpenSearchDatabaseSearchResponse.Total(
                    value: total,
                    relation: relation),
                hits: hits),
            aggregations: aggregations)
    }
}

private enum OpenSearchDatabaseReadingOutcome: Sendable {
    case response(OpenSearchDatabaseSearchResponse)
    case failure(OpenSearchDatabaseDriverFailure)
    case stalled
}

private actor OpenSearchDatabaseReadingClient: OpenSearchDatabaseClient {
    private var identities: [DatabaseProductIdentity]
    private var outcomes: [OpenSearchDatabaseReadingOutcome]
    private var pointInTimeIDs: [String]
    private let resolveFailure: OpenSearchDatabaseDriverFailure?
    private let mappingFailure: OpenSearchDatabaseDriverFailure?
    private var disconnected = false
    private var resolveCount = 0
    private var mappingCount = 0
    private var searches: [(Data, String)] = []
    private var closed: [String] = []
    private var disconnectCount = 0

    init(
        identities: [DatabaseProductIdentity] = [OpenSearchDatabaseReadingFixtures.identity],
        outcomes: [OpenSearchDatabaseReadingOutcome] = [],
        pointInTimeIDs: [String] = ["pit-opened"],
        resolveFailure: OpenSearchDatabaseDriverFailure? = nil,
        mappingFailure: OpenSearchDatabaseDriverFailure? = nil
    ) {
        self.identities = identities
        self.outcomes = outcomes
        self.pointInTimeIDs = pointInTimeIDs
        self.resolveFailure = resolveFailure
        self.mappingFailure = mappingFailure
    }

    func discoverIdentity() throws -> DatabaseProductIdentity {
        guard !disconnected, !identities.isEmpty else {
            throw OpenSearchDatabaseDriverFailure.connection
        }
        if identities.count == 1 { return identities[0] }
        return identities.removeFirst()
    }

    func resolveIndexes() throws -> OpenSearchDatabaseResolveResponse {
        resolveCount += 1
        if let resolveFailure { throw resolveFailure }
        return OpenSearchDatabaseResolveResponse(
            indices: [
                OpenSearchDatabaseResolveResponse.Index(
                    name: "edith-documents-v1",
                    aliases: ["edith_documents"],
                    attributes: ["open"],
                    dataStream: nil,
                    mode: "standard")
            ],
            aliases: [
                OpenSearchDatabaseResolveResponse.Alias(
                    name: "edith_documents",
                    indices: ["edith-documents-v1"])
            ],
            dataStreams: [])
    }

    func mapping(
        target: String
    ) throws -> OpenSearchDatabaseMappingResponse {
        mappingCount += 1
        if let mappingFailure { throw mappingFailure }
        return OpenSearchDatabaseMappingResponse(indices: [
            target: OpenSearchDatabaseReadingFixtures.mapping
        ])
    }

    func settings(
        target: String
    ) throws -> OpenSearchDatabaseSettingsResponse {
        OpenSearchDatabaseSettingsResponse(indices: [
            target: OpenSearchDatabaseSettingsResponse.Index(settings: [
                "index.number_of_shards": "3",
                "index.number_of_replicas": "0",
            ])
        ])
    }

    func openPointInTime(
        target: String,
        keepAlive: String
    ) throws -> String {
        guard !disconnected, keepAlive == "60s", !pointInTimeIDs.isEmpty else {
            throw OpenSearchDatabaseDriverFailure.connection
        }
        return pointInTimeIDs.removeFirst()
    }

    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> OpenSearchDatabaseSearchResponse {
        searches.append((body, pointInTimeID))
        guard !outcomes.isEmpty else { throw OpenSearchDatabaseDriverFailure.connection }
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
            throw OpenSearchDatabaseDriverFailure.connection
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

private func opensearchReadingSession(
    client: OpenSearchDatabaseReadingClient,
    definition: DatabaseConnectionDefinition
) async throws -> any DatabaseAdapterSession {
    try await OpenSearchDatabaseAdapter { _ in client }.connect(
        OpenSearchDatabaseReadingFixtures.resolved(definition),
        context: OpenSearchDatabaseReadingFixtures.context())
}

@Test func opensearchReadingReportsBoundedReadOnlyCapabilities() throws {
    let report = OpenSearchDatabaseAdapterSupport.capabilityReport(
        identity: OpenSearchDatabaseReadingFixtures.identity,
        discoveredAt: Date(timeIntervalSince1970: 1_800_000_000))
    try DatabaseAdapterBounds.validate(
        report: report,
        identity: OpenSearchDatabaseReadingFixtures.identity)
    #expect(report.supports(.connectionTest))
    #expect(report.supports(.browse))
    #expect(report.supports(.query))
    #expect(report.status(for: .objectDiscovery)?.availability == .degraded)
    #expect(report.status(for: .insert)?.reason?.category == .unsafe)
    #expect(report.pagingModes == [.pointInTime])
    #expect(report.mutationModes == [.unsupported])
    #expect(Set(report.capabilities.map(\.id)).count == report.capabilities.count)
}

@Test func opensearchReadingDiscoversIndexesAndAliasesLazily() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let client = OpenSearchDatabaseReadingClient()
    let session = try await opensearchReadingSession(client: client, definition: definition)
    #expect(await client.snapshot().resolve == 0)
    let request = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: OpenSearchDatabaseReadingFixtures.discoveryTarget(connectionID: definition.id),
        pageSize: 10)
    let page = try await session.readPage(
        request,
        context: OpenSearchDatabaseReadingFixtures.context())
    #expect(page.records.count == 2)
    #expect(page.metadata.completeness.state == .complete)
    #expect(page.metadata.count.value == 2)
    #expect(await client.snapshot().resolve == 1)
    #expect(await client.snapshot().mapping == 0)
    await session.disconnect()
}

@Test func opensearchReadingUsesStablePITPagesAndMappingCache() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let firstResponse = OpenSearchDatabaseReadingFixtures.response(
        hits: [
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1),
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-2", sort: 2),
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3),
        ],
        pit: "pit-second")
    let secondResponse = OpenSearchDatabaseReadingFixtures.response(
        hits: [OpenSearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3)],
        pit: "pit-final")
    let client = OpenSearchDatabaseReadingClient(
        outcomes: [.response(firstResponse), .response(secondResponse)])
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let target = OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let firstRequest = try OpenSearchDatabaseReadingFixtures.pageRequest(target: target)
    let first = try await session.readPage(
        firstRequest,
        context: OpenSearchDatabaseReadingFixtures.context())
    let continuation = try #require(first.nextContinuation)
    #expect(
        first.records.map { $0.identity?.components[1].value } == [
            .string("doc-1"), .string("doc-2"),
        ])
    #expect(first.fields.contains { $0.displayName == "title.raw" && $0.isSortable })
    #expect(first.fields.contains { $0.displayName == "title" && !$0.isSortable })
    #expect(
        first.records[0].identity?.concurrencyTokens.map(\.name) == ["_seq_no", "_primary_term"])
    let secondRequest = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: target,
        continuation: continuation)
    let second = try await session.readPage(
        secondRequest,
        context: OpenSearchDatabaseReadingFixtures.context())
    #expect(second.records.map { $0.identity?.components[1].value } == [.string("doc-3")])
    #expect(second.nextContinuation == nil)
    let snapshot = await client.snapshot()
    #expect(snapshot.mapping == 1)
    #expect(snapshot.searches.map(\.1) == ["pit-opened", "pit-second"])
    #expect(snapshot.closed == ["pit-final"])
    await session.disconnect()
}

@Test func opensearchReadingCompilesProjectionFilterSortAndHighlight() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let response = OpenSearchDatabaseReadingFixtures.response(
        hits: [
            OpenSearchDatabaseReadingFixtures.hit(
                id: "doc-7",
                title: "Search systems",
                sort: 7,
                highlight: ["title": ["<em>Search</em> systems"]])
        ],
        total: 1)
    let client = OpenSearchDatabaseReadingClient(outcomes: [.response(response)])
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let target = OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let source = try OpenSearchDatabaseReadingFixtures.pageRequest(
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
    let request = try OpenSearchDatabaseReadingFixtures.queryRequest(
        source: source,
        command: "search",
        body: body)
    let page = try await session.query(
        request,
        context: OpenSearchDatabaseReadingFixtures.context())
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

@Test func opensearchReadingReturnsBoundedAggregations() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let response = OpenSearchDatabaseReadingFixtures.response(
        hits: [],
        total: 0,
        aggregations: [
            "categories": .object([
                "buckets": .array([
                    .object(["key": .string("books"), "doc_count": .signedInteger(42)])
                ])
            ])
        ])
    let client = OpenSearchDatabaseReadingClient(outcomes: [.response(response)])
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let source = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id))
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
        OpenSearchDatabaseReadingFixtures.queryRequest(
            source: source,
            command: "aggregate",
            body: body),
        context: OpenSearchDatabaseReadingFixtures.context())
    #expect(page.records.count == 1)
    #expect(page.records[0].fields.first?.name == "categories")
    #expect(page.nextContinuation == nil)
    #expect(await client.snapshot().closed == ["pit-refreshed"])
    await session.disconnect()
}

@Test func opensearchReadingRejectsDangerousDSLAndTargets() throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let source = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id))
    for field in ["script", "from", "search_after", "runtime_mappings"] {
        let body: DatabaseValue = .object([
            DatabaseObjectField(
                name: "query",
                value: .object([
                    DatabaseObjectField(name: field, value: .object([]))
                ]))
        ])
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try OpenSearchDatabaseReadCompiler.compileQuery(
                OpenSearchDatabaseReadingFixtures.queryRequest(
                    source: source,
                    command: "search",
                    body: body),
                sessionID: DatabaseAdapterSessionID(),
                requestTimeoutMilliseconds: 1_000)
        }
    }
    for command in ["scroll", "delete", "_search", "update_by_query"] {
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try OpenSearchDatabaseReadCompiler.compileQuery(
                OpenSearchDatabaseReadingFixtures.queryRequest(
                    source: source,
                    command: command,
                    body: nil),
                sessionID: DatabaseAdapterSessionID(),
                requestTimeoutMilliseconds: 1_000)
        }
    }
    let unsafeTarget = OpenSearchDatabaseReadingFixtures.target(
        connectionID: definition.id,
        name: "_all")
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
            OpenSearchDatabaseReadingFixtures.pageRequest(target: unsafeTarget),
            sessionID: DatabaseAdapterSessionID(),
            requestTimeoutMilliseconds: 1_000)
    }
}

@Test func opensearchReadingBindsAndExpiresContinuations() throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let sessionID = DatabaseAdapterSessionID()
    let target = OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let request = try OpenSearchDatabaseReadingFixtures.pageRequest(target: target)
    let first = try OpenSearchDatabaseReadCompiler.compileBrowse(
        request,
        sessionID: sessionID,
        requestTimeoutMilliseconds: 1_000,
        now: Date(timeIntervalSince1970: 100))
    let continuation = try OpenSearchDatabaseReadCompiler.nextContinuation(
        sessionID: sessionID,
        request: request,
        digest: first.requestDigest,
        pointInTimeID: "pit-bound",
        sort: [.signedInteger(2)],
        now: Date(timeIntervalSince1970: 100))
    let resumed = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: target,
        continuation: continuation)
    _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
        resumed,
        sessionID: sessionID,
        requestTimeoutMilliseconds: 1_000,
        now: Date(timeIntervalSince1970: 120))
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
            resumed,
            sessionID: DatabaseAdapterSessionID(),
            requestTimeoutMilliseconds: 1_000,
            now: Date(timeIntervalSince1970: 120))
    }
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
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
        _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
            OpenSearchDatabaseReadingFixtures.pageRequest(
                target: target,
                continuation: malformed),
            sessionID: sessionID,
            requestTimeoutMilliseconds: 1_000,
            now: Date(timeIntervalSince1970: 120))
    }
}

@Test func opensearchReadingLabelsPartialAndLowerBoundResults() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let shards = OpenSearchDatabaseSearchResponse.Shards(
        total: 2,
        successful: 1,
        skipped: 0,
        failed: 1,
        failures: [
            OpenSearchDatabaseSearchResponse.Failure(index: "private-index", shard: 1)
        ])
    let response = OpenSearchDatabaseReadingFixtures.response(
        hits: [OpenSearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1)],
        total: 10_000,
        relation: .greaterThanOrEqual,
        timedOut: true,
        shards: shards)
    let client = OpenSearchDatabaseReadingClient(
        outcomes: [.response(response)],
        mappingFailure: .permission(403))
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let page = try await session.readPage(
        OpenSearchDatabaseReadingFixtures.pageRequest(
            target: OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)),
        context: OpenSearchDatabaseReadingFixtures.context())
    #expect(page.metadata.completeness.state == .partial)
    #expect(page.metadata.count.accuracy == .lowerBound)
    #expect(page.metadata.partialFailures.count == 1)
    #expect(page.metadata.warnings.map(\.code).contains("opensearch.mapping.permission"))
    let encoded = String(data: try JSONEncoder().encode(page.metadata), encoding: .utf8) ?? ""
    #expect(!encoded.contains("private-index"))
    #expect(!encoded.contains("fixture-password"))
    await session.disconnect()
}

@Test func opensearchReadingRejectsMalformedSortAndResponseOverflow() throws {
    let malformed = OpenSearchDatabaseReadingFixtures.response(
        hits: [
            OpenSearchDatabaseSearchResponse.Hit(
                index: "edith-documents-v1",
                identifier: "doc-1",
                sequenceNumber: 1,
                primaryTerm: 1,
                source: .object([:]),
                sort: [.object(["unsafe": .string("token")])],
                highlight: nil)
        ])
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidResponse) {
        try OpenSearchDatabaseDriverSupport.validate(malformed)
    }
    let excessiveHits = (0...(DatabasePageSize.range.upperBound + 1)).map {
        OpenSearchDatabaseReadingFixtures.hit(id: "doc-" + String($0), sort: Int64($0))
    }
    let excessive = OpenSearchDatabaseReadingFixtures.response(hits: excessiveHits)
    #expect(throws: OpenSearchDatabaseDriverFailure.invalidResponse) {
        try OpenSearchDatabaseDriverSupport.validate(excessive)
    }
}

@Test func opensearchReadingMapsPITExpiryAndCleansTheCursor() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let firstResponse = OpenSearchDatabaseReadingFixtures.response(
        hits: [
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-1", sort: 1),
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-2", sort: 2),
            OpenSearchDatabaseReadingFixtures.hit(id: "doc-3", sort: 3),
        ],
        pit: "pit-expiring")
    let client = OpenSearchDatabaseReadingClient(
        outcomes: [.response(firstResponse), .failure(.server(404))])
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let target = OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let first = try await session.readPage(
        OpenSearchDatabaseReadingFixtures.pageRequest(target: target),
        context: OpenSearchDatabaseReadingFixtures.context())
    let continuation = try #require(first.nextContinuation)
    await #expect(throws: OpenSearchDatabaseAdapterSupport.invalidContinuation) {
        _ = try await session.readPage(
            OpenSearchDatabaseReadingFixtures.pageRequest(
                target: target,
                continuation: continuation),
            context: OpenSearchDatabaseReadingFixtures.context())
    }
    #expect(await client.snapshot().closed.contains("pit-expiring"))
    await session.disconnect()
}

@Test func opensearchReadingCancelsPromptlyAndReconnects() async throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let operationID = DatabaseOperationID()
    let client = OpenSearchDatabaseReadingClient(outcomes: [.stalled])
    let session = try await opensearchReadingSession(client: client, definition: definition)
    let task = Task {
        try await session.readPage(
            OpenSearchDatabaseReadingFixtures.pageRequest(
                target: OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)),
            context: OpenSearchDatabaseReadingFixtures.context(operationID: operationID))
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
    let replacementClient = OpenSearchDatabaseReadingClient()
    let replacement = try await opensearchReadingSession(
        client: replacementClient,
        definition: definition)
    #expect(replacement.productIdentity.product == .openSearch)
    await replacement.disconnect()
}

@Test func opensearchReadingGatesStablePaginationByProductVersion() throws {
    let legacy = DatabaseProductIdentity(
        product: .openSearch,
        version: DatabaseVersion(string: "2.19.3", major: 2, minor: 19, patch: 3),
        distribution: "OpenSearch",
        topology: DatabaseTopology(kind: .standalone))
    let report = OpenSearchDatabaseAdapterSupport.capabilityReport(identity: legacy)
    #expect(!OpenSearchDatabaseAdapterSupport.supportsBoundedReading(legacy))
    #expect(report.status(for: .browse)?.availability == .unavailable)
    #expect(report.status(for: .browse)?.reason?.requiredVersion == "3.0")
    #expect(report.pagingModes.isEmpty)
    #expect(
        OpenSearchDatabaseAdapterSupport.supportsBoundedReading(
            OpenSearchDatabaseReadingFixtures.identity))
}

@Test func opensearchReadingInspectsProductSpecificMetadata() throws {
    let resolve = try JSONDecoder().decode(
        OpenSearchDatabaseResolveResponse.self,
        from: Data(
            """
            {"indices":[{"name":"logs-000001","attributes":["open"],"data_stream":"logs"}],"aliases":[],"data_streams":[{"name":"logs","backing_indices":["logs-000001"],"timestamp_field":"@timestamp"}]}
            """.utf8))
    try OpenSearchDatabaseDriverSupport.validate(resolve)
    #expect(resolve.indices[0].aliases.isEmpty)
    #expect(resolve.dataStreams[0].name == "logs")

    let mapping = try JSONDecoder().decode(
        OpenSearchDatabaseMappingResponse.self,
        from: Data(
            """
            {"logs-000001":{"mappings":{"properties":{"comments":{"type":"nested","properties":{"rating":{"type":"byte"}}}},"derived":{"latency_band":{"type":"keyword"}}}}}
            """.utf8))
    try OpenSearchDatabaseDriverSupport.validate(mapping)
    let fields = try OpenSearchDatabaseReadCompiler.fieldDescriptors(mapping)
    #expect(fields.first { $0.displayName == "comments.rating" }?.isFilterable == false)
    #expect(fields.first { $0.displayName == "comments.rating" }?.isSortable == false)
    #expect(fields.first { $0.displayName == "latency_band" }?.typeName == "derived:keyword")

    let settings = try JSONDecoder().decode(
        OpenSearchDatabaseSettingsResponse.self,
        from: Data(
            """
            {"logs-000001":{"settings":{"index.number_of_shards":"3","index.replication.type":"DOCUMENT"}}}
            """.utf8))
    try OpenSearchDatabaseDriverSupport.validate(settings, expectedTarget: "logs-000001")
    #expect(settings.indices["logs-000001"]?.settings["index.replication.type"] == "DOCUMENT")
}

@Test func opensearchReadingAllowsOnlyBoundedProductDSL() throws {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let target = OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id)
    let source = try OpenSearchDatabaseReadingFixtures.pageRequest(target: target)
    let nested: DatabaseValue = .object([
        DatabaseObjectField(
            name: "query",
            value: .object([
                DatabaseObjectField(
                    name: "nested",
                    value: .object([
                        DatabaseObjectField(name: "path", value: .string("comments")),
                        DatabaseObjectField(
                            name: "query",
                            value: .object([
                                DatabaseObjectField(
                                    name: "term",
                                    value: .object([
                                        DatabaseObjectField(
                                            name: "comments.rating",
                                            value: .signedInteger(2))
                                    ]))
                            ])),
                    ]))
            ]))
    ])
    _ = try OpenSearchDatabaseReadCompiler.compileQuery(
        OpenSearchDatabaseReadingFixtures.queryRequest(
            source: source,
            command: "search",
            body: nested),
        sessionID: DatabaseAdapterSessionID(),
        requestTimeoutMilliseconds: 1_000)
    for query in [
        DatabaseObjectField(name: "neural", value: .object([])),
        DatabaseObjectField(
            name: "terms",
            value: .object([
                DatabaseObjectField(
                    name: "category",
                    value: .object([
                        DatabaseObjectField(name: "index", value: .string("private")),
                        DatabaseObjectField(name: "id", value: .string("doc")),
                        DatabaseObjectField(name: "path", value: .string("terms")),
                    ]))
            ])),
    ] {
        let body: DatabaseValue = .object([
            DatabaseObjectField(name: "query", value: .object([query]))
        ])
        #expect(throws: DatabaseAdapterFailure.self) {
            _ = try OpenSearchDatabaseReadCompiler.compileQuery(
                OpenSearchDatabaseReadingFixtures.queryRequest(
                    source: source,
                    command: "search",
                    body: body),
                sessionID: DatabaseAdapterSessionID(),
                requestTimeoutMilliseconds: 1_000)
        }
    }
    #expect(throws: DatabaseAdapterFailure.self) {
        _ = try OpenSearchDatabaseReadCompiler.compileBrowse(
            OpenSearchDatabaseReadingFixtures.pageRequest(target: target, pageSize: 101),
            sessionID: DatabaseAdapterSessionID(),
            requestTimeoutMilliseconds: 1_000)
    }
}

private enum OpenSearchDatabaseReadingLiveEnvironment {
    static let values = ProcessInfo.processInfo.environment
    static let isEnabled = [
        "EDITH_DATABASE_OPENSEARCH_URL",
        "EDITH_DATABASE_OPENSEARCH_USERNAME",
        "EDITH_DATABASE_OPENSEARCH_PASSWORD",
    ].allSatisfy { values[$0]?.isEmpty == false }
    static let isLargeEnabled =
        isEnabled
        && values["EDITH_DATABASE_OPENSEARCH_LARGE_TESTS"] == "1"

    static func resolved() throws -> DatabaseResolvedConnection {
        let username = try #require(values["EDITH_DATABASE_OPENSEARCH_USERNAME"])
        let password = try #require(values["EDITH_DATABASE_OPENSEARCH_PASSWORD"])
        let definition = try OpenSearchDatabaseReadingFixtures.definition(
            username: username,
            tls: DatabaseTLSConfiguration(mode: .required, verification: .full))
        let reference = try #require(definition.authentication.secretReferences.first)
        return try DatabaseResolvedConnection(
            definition: definition,
            secrets: [reference: Data(password.utf8)])
    }
}

private final class OpenSearchDatabaseReadingLiveDelegate: NSObject, URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard
            challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        task.cancel()
        completionHandler(nil)
    }
}

private func openSearchDatabaseReadingLiveURLSession(
    _ plan: OpenSearchDatabaseConnectionPlan
) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = TimeInterval(plan.connectTimeoutMilliseconds) / 1_000
    configuration.timeoutIntervalForResource = TimeInterval(plan.requestTimeoutMilliseconds) / 1_000
    configuration.waitsForConnectivity = false
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.httpCookieStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.urlCache = nil
    return URLSession(
        configuration: configuration,
        delegate: OpenSearchDatabaseReadingLiveDelegate(),
        delegateQueue: nil)
}

private func openSearchDatabaseReadingLiveClient() async throws -> any OpenSearchDatabaseClient {
    let resolved = try OpenSearchDatabaseReadingLiveEnvironment.resolved()
    let plan = try OpenSearchDatabaseAdapterSupport.connectionPlan(
        resolved,
        context: OpenSearchDatabaseReadingFixtures.context(deadline: Date().addingTimeInterval(10)))
    return try await URLSessionOpenSearchDatabaseClient.connect(
        plan,
        sessionFactory: { openSearchDatabaseReadingLiveURLSession($0) })
}

private func openSearchDatabaseReadingLiveSession() async throws -> (
    any DatabaseAdapterSession, DatabaseConnectionDefinition
) {
    let resolved = try OpenSearchDatabaseReadingLiveEnvironment.resolved()
    let session = try await OpenSearchDatabaseAdapter { plan in
        try await URLSessionOpenSearchDatabaseClient.connect(
            plan,
            sessionFactory: { openSearchDatabaseReadingLiveURLSession($0) })
    }.connect(
        resolved,
        context: OpenSearchDatabaseReadingFixtures.context(deadline: Date().addingTimeInterval(10)))
    return (session, resolved.definition)
}

private func openSearchDatabaseReadingLiveBody(_ value: String) throws -> DatabaseValue {
    try JSONDecoder().decode(OpenSearchDatabaseJSONValue.self, from: Data(value.utf8))
        .databaseValue()
}

private func openSearchDatabaseReadingLiveSearch(
    client: any OpenSearchDatabaseClient,
    command: String,
    body: String,
    pageSize: Int = 6,
    sorts: [DatabaseSort] = []
) async throws -> OpenSearchDatabaseSearchResponse {
    let definition = try OpenSearchDatabaseReadingFixtures.definition()
    let source = try OpenSearchDatabaseReadingFixtures.pageRequest(
        target: OpenSearchDatabaseReadingFixtures.target(connectionID: definition.id),
        pageSize: pageSize,
        sorts: sorts)
    let request = try OpenSearchDatabaseReadingFixtures.queryRequest(
        source: source,
        command: command,
        body: openSearchDatabaseReadingLiveBody(body))
    let plan = try OpenSearchDatabaseReadCompiler.compileQuery(
        request,
        sessionID: DatabaseAdapterSessionID(),
        requestTimeoutMilliseconds: 5_000)
    let opened = try await client.openPointInTime(target: plan.target, keepAlive: "60s")
    do {
        let response = try await client.search(body: plan.body, pointInTimeID: opened)
        try await client.closePointInTime(response.pointInTimeID ?? opened)
        return response
    } catch {
        try? await client.closePointInTime(opened)
        throw error
    }
}

@Suite(.serialized)
struct OpenSearchDatabaseReadingLiveTests {
    @Test(.enabled(if: OpenSearchDatabaseReadingLiveEnvironment.isEnabled))
    func metadataQueriesHighlightAggregationsAndNestedReads() async throws {
        let client = try await openSearchDatabaseReadingLiveClient()
        defer { Task { await client.disconnect() } }
        let resolved = try await client.resolveIndexes()
        #expect(resolved.indices.contains { $0.name == "edith-documents-v1" })
        #expect(resolved.aliases.contains { $0.name == "edith_documents" })
        let mapping = try await client.mapping(target: "edith-documents-v1")
        let fields = try OpenSearchDatabaseReadCompiler.fieldDescriptors(mapping)
        #expect(fields.count == 26)
        #expect(fields.first { $0.displayName == "comments.rating" }?.isFilterable == false)
        let settings = try await client.settings(target: "edith-documents-v1")
        #expect(settings.indices["edith-documents-v1"]?.settings["index.number_of_shards"] == "3")
        #expect(settings.indices["edith-documents-v1"]?.settings["index.number_of_replicas"] == "0")

        let sort = DatabaseSort(field: DatabaseFieldPath("doc_id"), direction: .ascending)
        let matched = try await openSearchDatabaseReadingLiveSearch(
            client: client,
            command: "search",
            body: #"{"query":{"match_phrase":{"summary":"group-42"}},"track_total_hits":true}"#,
            pageSize: 5,
            sorts: [sort])
        #expect(matched.hits.total?.value == 7_813)
        #expect(matched.hits.hits.first?.identifier == "doc-0000042")

        let highlighted = try await openSearchDatabaseReadingLiveSearch(
            client: client,
            command: "search",
            body:
                #"{"query":{"match":{"title":"account"}},"highlight":{"fields":{"title":{}},"fragment_size":120},"track_total_hits":true}"#,
            pageSize: 1,
            sorts: [sort])
        #expect(highlighted.hits.total?.value == 166_667)
        #expect(highlighted.hits.hits.first?.highlight?["title"]?.isEmpty == false)

        let aggregated = try await openSearchDatabaseReadingLiveSearch(
            client: client,
            command: "aggregate",
            body: #"{"aggs":{"categories":{"terms":{"field":"category","size":6}}}}"#)
        guard case let .object(categoryAggregation)? = aggregated.aggregations?["categories"],
            case let .array(buckets)? = categoryAggregation["buckets"]
        else {
            Issue.record("missing category buckets")
            return
        }
        #expect(buckets.count == 6)

        let nested = try await openSearchDatabaseReadingLiveSearch(
            client: client,
            command: "search",
            body:
                #"{"query":{"nested":{"path":"comments","query":{"term":{"comments.rating":2}}}},"track_total_hits":true}"#,
            pageSize: 1)
        #expect(nested.hits.total?.value == 200_000)
    }

    @Test(.enabled(if: OpenSearchDatabaseReadingLiveEnvironment.isEnabled))
    func cancellationDeadlineAndReconnectRemainBounded() async throws {
        let body = try openSearchDatabaseReadingLiveBody(
            #"{"aggs":{"high_cardinality":{"terms":{"field":"doc_id","size":100,"shard_size":1000}}}}"#
        )
        let operationID = DatabaseOperationID()
        let first = try await openSearchDatabaseReadingLiveSession()
        let source = try OpenSearchDatabaseReadingFixtures.pageRequest(
            target: OpenSearchDatabaseReadingFixtures.target(connectionID: first.1.id))
        let request = try OpenSearchDatabaseReadingFixtures.queryRequest(
            source: source,
            command: "aggregate",
            body: body)
        let task = Task {
            try await first.0.query(
                request,
                context: OpenSearchDatabaseReadingFixtures.context(operationID: operationID))
        }
        try await Task.sleep(for: .milliseconds(5))
        let startedAt = ContinuousClock.now
        #expect(await first.0.cancel(operationID).disposition == .accepted)
        await #expect(throws: DatabaseAdapterFailure.self) { _ = try await task.value }
        #expect(ContinuousClock.now - startedAt < .seconds(2))
        #expect(await first.0.lifecycleState() == .failed)

        let second = try await openSearchDatabaseReadingLiveSession()
        let secondSource = try OpenSearchDatabaseReadingFixtures.pageRequest(
            target: OpenSearchDatabaseReadingFixtures.target(connectionID: second.1.id))
        let secondRequest = try OpenSearchDatabaseReadingFixtures.queryRequest(
            source: secondSource,
            command: "aggregate",
            body: body)
        await #expect(throws: OpenSearchDatabaseAdapterSupport.deadlineExceeded) {
            _ = try await second.0.query(
                secondRequest,
                context: OpenSearchDatabaseReadingFixtures.context(
                    deadline: Date().addingTimeInterval(0.005)))
        }
        #expect(await second.0.lifecycleState() == .failed)
        let recovered = try await openSearchDatabaseReadingLiveSession()
        #expect(recovered.0.productIdentity.version?.string == "3.8.0")
        await recovered.0.disconnect()
    }

    @Test(.enabled(if: OpenSearchDatabaseReadingLiveEnvironment.isLargeEnabled))
    func traversesOneMillionDocumentsWithoutOffsets() async throws {
        let connected = try await openSearchDatabaseReadingLiveSession()
        let target = OpenSearchDatabaseReadingFixtures.target(connectionID: connected.1.id)
        var continuation: DatabaseAdapterContinuation?
        var expected = 0
        var pages = 0
        var maximumTokenBytes = 0
        var hasher = SHA256()
        let startedAt = ContinuousClock.now
        repeat {
            let request = try OpenSearchDatabaseReadingFixtures.pageRequest(
                target: target,
                pageSize: 100,
                continuation: continuation,
                projection: DatabaseProjection(
                    mode: .include,
                    fields: [DatabaseProjectedField(path: DatabaseFieldPath("doc_id"))]),
                sorts: [DatabaseSort(field: DatabaseFieldPath("doc_id"), direction: .ascending)])
            let page = try await connected.0.readPage(
                request,
                context: OpenSearchDatabaseReadingFixtures.context(
                    deadline: Date().addingTimeInterval(15)))
            #expect(page.records.count == 100)
            for record in page.records {
                let value = try #require(record.fields.first { $0.name == "doc_id" }?.value)
                guard case let .string(identifier) = value else {
                    Issue.record("missing traversal identifier")
                    return
                }
                #expect(identifier == String(format: "doc-%07d", expected))
                hasher.update(data: Data((identifier + "\n").utf8))
                expected += 1
            }
            continuation = page.nextContinuation
            maximumTokenBytes = max(maximumTokenBytes, continuation?.payload.count ?? 0)
            pages += 1
        } while continuation != nil
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        #expect(expected == 1_000_000)
        #expect(pages == 10_000)
        #expect(digest == "32298b18aeb1bf6c75086093284c7d7da556dd7a7a3f37c96709ff5cf1ee93a2")
        #expect(maximumTokenBytes <= DatabaseAdapterBounds.maximumContinuationBytes)
        await connected.0.disconnect()
        let recovered = try await openSearchDatabaseReadingLiveSession()
        #expect(recovered.0.productIdentity.product == .openSearch)
        await recovered.0.disconnect()
        print(
            "opensearch traversal documents=1000000 pages=10000 maxTokenBytes=\(maximumTokenBytes) duration=\(ContinuousClock.now - startedAt)"
        )
    }
}
