import Foundation

enum ElasticsearchDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case connection
    case conflict
    case invalidConfiguration
    case invalidResponse
    case permission(Int)
    case responseTooLarge
    case server(Int)
    case timeout
    case tls
    case unsupportedProduct
}

enum ElasticsearchDatabaseAuthorization: Equatable, Sendable {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(identifier: String, secret: String)

    var headerValue: String? {
        switch self {
        case .none:
            return nil
        case let .basic(username, password):
            return "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        case let .bearer(token):
            return "Bearer \(token)"
        case let .apiKey(identifier, secret):
            let encoded = Data("\(identifier):\(secret)".utf8).base64EncodedString()
            return "ApiKey \(encoded)"
        }
    }

    func validate() throws(ElasticsearchDatabaseDriverFailure) {
        switch self {
        case .none:
            return
        case let .basic(username, password):
            guard Self.valid(username, maximumBytes: 1_024),
                !username.contains(":"),
                Self.valid(password, maximumBytes: 1_048_576)
            else {
                throw .invalidConfiguration
            }
        case let .bearer(token):
            guard Self.valid(token, maximumBytes: 1_048_576) else {
                throw .invalidConfiguration
            }
        case let .apiKey(identifier, secret):
            guard Self.valid(identifier, maximumBytes: 4_096),
                !identifier.contains(":"),
                Self.valid(secret, maximumBytes: 1_048_576)
            else {
                throw .invalidConfiguration
            }
        }
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
            && !value.contains("\0") && !value.contains("\r") && !value.contains("\n")
    }
}

struct ElasticsearchDatabaseConnectionPlan: Sendable {
    let endpoint: URL
    let authorization: ElasticsearchDatabaseAuthorization
    let connectTimeoutMilliseconds: UInt64
    let requestTimeoutMilliseconds: UInt64
    let maximumResponseBytes: Int
}

protocol ElasticsearchDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func resolveIndexes() async throws -> ElasticsearchDatabaseResolveResponse
    func mapping(
        target: String
    ) async throws -> ElasticsearchDatabaseMappingResponse
    func openPointInTime(
        target: String,
        keepAlive: String
    ) async throws -> String
    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> ElasticsearchDatabaseSearchResponse
    func closePointInTime(_ identifier: String) async throws
    func mutate(
        _ plan: ElasticsearchDatabaseMutationPlan
    ) async throws -> ElasticsearchDatabaseMutationResult
    func disconnect() async
}

enum ElasticsearchDatabaseMutationOperation: Equatable, Sendable {
    case create(body: Data)
    case replace(body: Data, sequenceNumber: Int64, primaryTerm: Int64)
    case delete(sequenceNumber: Int64, primaryTerm: Int64)
}

struct ElasticsearchDatabaseMutationPlan: Equatable, Sendable {
    let index: String
    let identifier: String
    let operation: ElasticsearchDatabaseMutationOperation
}

struct ElasticsearchDatabaseMutationResult: Equatable, Sendable {
    let index: String
    let identifier: String
    let result: String
    let sequenceNumber: Int64
    let primaryTerm: Int64
}

typealias ElasticsearchDatabaseSessionFactory =
    @Sendable (ElasticsearchDatabaseConnectionPlan) -> URLSession

typealias ElasticsearchDatabaseClientConnector =
    @Sendable (ElasticsearchDatabaseConnectionPlan) async throws -> any ElasticsearchDatabaseClient

actor URLSessionElasticsearchDatabaseClient: ElasticsearchDatabaseClient {
    private static let maximumOpenPointInTimes = 8
    private let plan: ElasticsearchDatabaseConnectionPlan
    private var session: URLSession?
    private var identity: DatabaseProductIdentity?
    private var openPointInTimeIdentifiers: Set<String> = []

    private init(
        plan: ElasticsearchDatabaseConnectionPlan,
        session: URLSession
    ) {
        self.plan = plan
        self.session = session
    }

    static func connect(
        _ plan: ElasticsearchDatabaseConnectionPlan,
        sessionFactory: ElasticsearchDatabaseSessionFactory = {
            ElasticsearchDatabaseTransport.makeSession($0)
        }
    ) async throws -> any ElasticsearchDatabaseClient {
        try ElasticsearchDatabaseTransport.validate(plan)
        let client = URLSessionElasticsearchDatabaseClient(
            plan: plan,
            session: sessionFactory(plan))
        do {
            try await ElasticsearchDatabaseDeadline.run(
                milliseconds: plan.connectTimeoutMilliseconds
            ) {
                try await client.prepare()
            }
            return client
        } catch is CancellationError {
            await client.disconnect()
            throw CancellationError()
        } catch {
            await client.disconnect()
            throw try ElasticsearchDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard session != nil, let identity else {
            throw ElasticsearchDatabaseDriverFailure.connection
        }
        return identity
    }

    func resolveIndexes() async throws -> ElasticsearchDatabaseResolveResponse {
        let response = try await send(
            path: "/_resolve/index/*",
            queryItems: [URLQueryItem(name: "expand_wildcards", value: "open")])
        let decoded = try decode(ElasticsearchDatabaseResolveResponse.self, from: response.body)
        try ElasticsearchDatabaseDriverSupport.validate(decoded)
        return decoded
    }

    func mapping(
        target: String
    ) async throws -> ElasticsearchDatabaseMappingResponse {
        let segment = try ElasticsearchDatabaseDriverSupport.pathSegment(target)
        let response = try await send(
            path: "/\(segment)/_mapping",
            queryItems: [URLQueryItem(name: "filter_path", value: "*.mappings")])
        let decoded = try decode(ElasticsearchDatabaseMappingResponse.self, from: response.body)
        try ElasticsearchDatabaseDriverSupport.validate(decoded)
        return decoded
    }

    func openPointInTime(
        target: String,
        keepAlive: String
    ) async throws -> String {
        guard openPointInTimeIdentifiers.count < Self.maximumOpenPointInTimes else {
            throw ElasticsearchDatabaseDriverFailure.responseTooLarge
        }
        let segment = try ElasticsearchDatabaseDriverSupport.pathSegment(target)
        guard ElasticsearchDatabaseDriverSupport.validKeepAlive(keepAlive) else {
            throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
        }
        let response = try await send(
            method: .post,
            path: "/\(segment)/_pit",
            queryItems: [URLQueryItem(name: "keep_alive", value: keepAlive)])
        let decoded = try decode(
            ElasticsearchDatabaseOpenPointInTimeResponse.self,
            from: response.body)
        guard ElasticsearchDatabaseDriverSupport.validOpaqueIdentifier(decoded.id) else {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
        openPointInTimeIdentifiers.insert(decoded.id)
        return decoded.id
    }

    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> ElasticsearchDatabaseSearchResponse {
        guard ElasticsearchDatabaseDriverSupport.validOpaqueIdentifier(pointInTimeID) else {
            throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
        }
        let boundedBody: Data
        do {
            var value = try JSONDecoder().decode(
                ElasticsearchDatabaseJSONValue.self,
                from: body)
            guard case var .object(fields) = value,
                case var .object(pointInTime)? = fields["pit"],
                pointInTime["keep_alive"] == .string("60s")
            else {
                throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
            }
            pointInTime["id"] = .string(pointInTimeID)
            fields["pit"] = .object(pointInTime)
            value = .object(fields)
            boundedBody = try ElasticsearchDatabaseJSONCodec.encode(value)
        } catch let failure as ElasticsearchDatabaseDriverFailure {
            throw failure
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
        }
        let response = try await send(
            method: .post,
            path: "/_search",
            queryItems: [
                URLQueryItem(name: "allow_partial_search_results", value: "true"),
                URLQueryItem(name: "batched_reduce_size", value: "64"),
                URLQueryItem(name: "seq_no_primary_term", value: "true"),
                URLQueryItem(
                    name: "filter_path",
                    value:
                        "took,timed_out,pit_id,_shards.total,_shards.successful,_shards.skipped,_shards.failed,_shards.failures.index,_shards.failures.shard,hits.total,hits.hits._index,hits.hits._id,hits.hits._seq_no,hits.hits._primary_term,hits.hits._source,hits.hits.sort,hits.hits.highlight,aggregations"
                ),
            ],
            body: boundedBody)
        let decoded = try decode(ElasticsearchDatabaseSearchResponse.self, from: response.body)
        try ElasticsearchDatabaseDriverSupport.validate(decoded)
        if let refreshed = decoded.pointInTimeID {
            openPointInTimeIdentifiers.remove(pointInTimeID)
            openPointInTimeIdentifiers.insert(refreshed)
        }
        return decoded
    }

    func closePointInTime(_ identifier: String) async throws {
        guard ElasticsearchDatabaseDriverSupport.validOpaqueIdentifier(identifier) else {
            throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
        }
        defer { openPointInTimeIdentifiers.remove(identifier) }
        let body: Data
        do {
            body = try ElasticsearchDatabaseJSONCodec.encode(
                .object(["id": .string(identifier)]))
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
        }
        let response = try await send(
            method: .delete,
            path: "/_pit",
            body: body)
        let decoded = try decode(
            ElasticsearchDatabaseClosePointInTimeResponse.self,
            from: response.body)
        guard decoded.succeeded, decoded.freed >= 0 else {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
    }

    func mutate(
        _ mutation: ElasticsearchDatabaseMutationPlan
    ) async throws -> ElasticsearchDatabaseMutationResult {
        let index = try ElasticsearchDatabaseDriverSupport.pathSegment(mutation.index)
        let identifier = try ElasticsearchDatabaseDriverSupport.documentPathSegment(
            mutation.identifier)
        let method: ElasticsearchDatabaseHTTPMethod
        let path: String
        var queryItems = [URLQueryItem(name: "refresh", value: "wait_for")]
        let body: Data?
        switch mutation.operation {
        case .create(let document):
            method = .put
            path = "/\(index)/_create/\(identifier)"
            body = document
        case .replace(let document, let sequenceNumber, let primaryTerm):
            guard sequenceNumber >= 0, primaryTerm >= 0 else {
                throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
            }
            method = .put
            path = "/\(index)/_doc/\(identifier)"
            queryItems.append(URLQueryItem(name: "if_seq_no", value: String(sequenceNumber)))
            queryItems.append(URLQueryItem(name: "if_primary_term", value: String(primaryTerm)))
            body = document
        case .delete(let sequenceNumber, let primaryTerm):
            guard sequenceNumber >= 0, primaryTerm >= 0 else {
                throw ElasticsearchDatabaseDriverFailure.invalidConfiguration
            }
            method = .delete
            path = "/\(index)/_doc/\(identifier)"
            queryItems.append(URLQueryItem(name: "if_seq_no", value: String(sequenceNumber)))
            queryItems.append(URLQueryItem(name: "if_primary_term", value: String(primaryTerm)))
            body = nil
        }
        let response = try await send(
            method: method,
            path: path,
            queryItems: queryItems,
            body: body)
        let decoded = try decode(
            ElasticsearchDatabaseDocumentMutationResponse.self,
            from: response.body)
        guard decoded.index == mutation.index,
            decoded.identifier == mutation.identifier,
            decoded.sequenceNumber >= 0,
            decoded.primaryTerm >= 0,
            ["created", "updated", "deleted"].contains(decoded.result)
        else {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
        return ElasticsearchDatabaseMutationResult(
            index: decoded.index,
            identifier: decoded.identifier,
            result: decoded.result,
            sequenceNumber: decoded.sequenceNumber,
            primaryTerm: decoded.primaryTerm)
    }

    func disconnect() async {
        let session = self.session
        let identifiers = openPointInTimeIdentifiers
        openPointInTimeIdentifiers.removeAll()
        if let session {
            for identifier in identifiers {
                await Self.closePointInTime(
                    identifier,
                    session: session,
                    plan: plan)
            }
        }
        self.session = nil
        identity = nil
        session?.invalidateAndCancel()
    }

    func outstandingPointInTimeCount() -> Int {
        openPointInTimeIdentifiers.count
    }

    private func prepare() async throws {
        let rootResponse = try await send(path: "/")
        let root: ElasticsearchDatabaseRootResponse
        do {
            root = try JSONDecoder().decode(
                ElasticsearchDatabaseRootResponse.self,
                from: rootResponse.body)
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
        let nodesResponse = try await send(
            path: "/_nodes/_all/plugins",
            queryItems: [
                URLQueryItem(
                    name: "filter_path",
                    value:
                        "_nodes,cluster_name,nodes.*.name,nodes.*.roles,nodes.*.version,nodes.*.plugins.name,nodes.*.plugins.version,nodes.*.modules.name,nodes.*.modules.version"
                )
            ])
        let nodes: ElasticsearchDatabaseNodesResponse
        do {
            nodes = try JSONDecoder().decode(
                ElasticsearchDatabaseNodesResponse.self,
                from: nodesResponse.body)
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
        identity = try ElasticsearchDatabaseDriverSupport.identity(
            root: root,
            nodes: nodes)
    }

    private func send(
        method: ElasticsearchDatabaseHTTPMethod = .get,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> ElasticsearchDatabaseHTTPResponse {
        guard let session else {
            throw ElasticsearchDatabaseDriverFailure.connection
        }
        let request = try ElasticsearchDatabaseTransport.request(
            endpoint: plan.endpoint,
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            authorization: plan.authorization)
        do {
            let response = try await ElasticsearchDatabaseTransport.execute(
                session: session,
                request: request,
                maximumResponseBytes: plan.maximumResponseBytes)
            try ElasticsearchDatabaseDriverErrorClassifier.validate(response)
            return response
        } catch {
            throw try ElasticsearchDatabaseDriverErrorClassifier.classify(error)
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
    }

    private static func closePointInTime(
        _ identifier: String,
        session: URLSession,
        plan: ElasticsearchDatabaseConnectionPlan
    ) async {
        guard
            let body = try? ElasticsearchDatabaseJSONCodec.encode(
                .object(["id": .string(identifier)])),
            let request = try? ElasticsearchDatabaseTransport.request(
                endpoint: plan.endpoint,
                path: "/_pit",
                method: .delete,
                queryItems: [],
                body: body,
                authorization: plan.authorization),
            let response = try? await ElasticsearchDatabaseDeadline.run(
                milliseconds: min(plan.requestTimeoutMilliseconds, 2_000),
                operation: {
                    try await ElasticsearchDatabaseTransport.execute(
                        session: session,
                        request: request,
                        maximumResponseBytes: plan.maximumResponseBytes)
                })
        else {
            return
        }
        try? ElasticsearchDatabaseDriverErrorClassifier.validate(response)
    }
}

struct ElasticsearchDatabaseResolveResponse: Decodable, Sendable {
    let indices: [Index]
    let aliases: [Alias]
    let dataStreams: [DataStream]

    struct Index: Decodable, Sendable {
        let name: String
        let aliases: [String]
        let attributes: [String]
        let dataStream: String?
        let mode: String?

        private enum CodingKeys: String, CodingKey {
            case name
            case aliases
            case attributes
            case dataStream = "data_stream"
            case mode
        }
    }

    struct Alias: Decodable, Sendable {
        let name: String
        let indices: [String]
    }

    struct DataStream: Decodable, Sendable {
        let name: String
        let backingIndices: [String]
        let timestampField: String

        private enum CodingKeys: String, CodingKey {
            case name
            case backingIndices = "backing_indices"
            case timestampField = "timestamp_field"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case indices
        case aliases
        case dataStreams = "data_streams"
    }
}

struct ElasticsearchDatabaseMappingResponse: Decodable, Sendable {
    let indices: [String: Index]

    init(indices: [String: Index]) {
        self.indices = indices
    }

    struct Index: Decodable, Sendable {
        let mappings: Mapping
    }

    struct Mapping: Decodable, Sendable {
        let dynamic: ElasticsearchDatabaseJSONValue?
        let properties: [String: Field]?
        let runtime: [String: Field]?
    }

    struct Field: Decodable, Sendable {
        let type: String?
        let index: Bool?
        let enabled: Bool?
        let docValues: Bool?
        let properties: [String: Field]?
        let fields: [String: Field]?

        private enum CodingKeys: String, CodingKey {
            case type
            case index
            case enabled
            case docValues = "doc_values"
            case properties
            case fields
        }
    }

    init(from decoder: Decoder) throws {
        indices = try decoder.singleValueContainer().decode([String: Index].self)
    }
}

struct ElasticsearchDatabaseSearchResponse: Decodable, Sendable {
    let took: UInt64
    let timedOut: Bool
    let pointInTimeID: String?
    let shards: Shards
    let hits: Hits
    let aggregations: [String: ElasticsearchDatabaseJSONValue]?

    struct Shards: Decodable, Sendable {
        let total: Int
        let successful: Int
        let skipped: Int
        let failed: Int
        let failures: [Failure]?
    }

    struct Failure: Decodable, Sendable {
        let index: String?
        let shard: Int?
    }

    struct Hits: Decodable, Sendable {
        let total: Total
        let hits: [Hit]

        init(total: Total, hits: [Hit]) {
            self.total = total
            self.hits = hits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = try container.decode(Total.self, forKey: .total)
            hits = try container.decodeIfPresent([Hit].self, forKey: .hits) ?? []
        }

        private enum CodingKeys: String, CodingKey {
            case total
            case hits
        }
    }

    struct Total: Decodable, Sendable {
        let value: UInt64
        let relation: Relation
    }

    enum Relation: String, Decodable, Sendable {
        case equal = "eq"
        case greaterThanOrEqual = "gte"
    }

    struct Hit: Decodable, Sendable {
        let index: String
        let identifier: String?
        let sequenceNumber: Int64?
        let primaryTerm: Int64?
        let source: ElasticsearchDatabaseJSONValue?
        let sort: [ElasticsearchDatabaseJSONValue]?
        let highlight: [String: [String]]?

        private enum CodingKeys: String, CodingKey {
            case index = "_index"
            case identifier = "_id"
            case sequenceNumber = "_seq_no"
            case primaryTerm = "_primary_term"
            case source = "_source"
            case sort
            case highlight
        }
    }

    private enum CodingKeys: String, CodingKey {
        case took
        case timedOut = "timed_out"
        case pointInTimeID = "pit_id"
        case shards = "_shards"
        case hits
        case aggregations
    }
}

private struct ElasticsearchDatabaseOpenPointInTimeResponse: Decodable {
    let id: String
}

private struct ElasticsearchDatabaseClosePointInTimeResponse: Decodable {
    let succeeded: Bool
    let freed: Int

    private enum CodingKeys: String, CodingKey {
        case succeeded
        case freed = "num_freed"
    }
}

private struct ElasticsearchDatabaseDocumentMutationResponse: Decodable {
    let index: String
    let identifier: String
    let result: String
    let sequenceNumber: Int64
    let primaryTerm: Int64

    private enum CodingKeys: String, CodingKey {
        case index = "_index"
        case identifier = "_id"
        case result
        case sequenceNumber = "_seq_no"
        case primaryTerm = "_primary_term"
    }
}

enum ElasticsearchDatabaseDriverErrorClassifier {
    static func validate(
        _ response: ElasticsearchDatabaseHTTPResponse
    ) throws(ElasticsearchDatabaseDriverFailure) {
        switch response.statusCode {
        case 200..<300:
            guard response.productHeader == "Elasticsearch" else {
                throw .unsupportedProduct
            }
        case 401:
            throw .authentication
        case 403:
            throw .permission(403)
        case 409:
            throw .conflict
        case 408, 504:
            throw .timeout
        default:
            throw .server(Self.safeStatus(response.statusCode))
        }
    }

    static func classify(
        _ error: Error
    ) throws(CancellationError) -> ElasticsearchDatabaseDriverFailure {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if let failure = error as? ElasticsearchDatabaseDriverFailure {
            return failure
        }
        guard let error = error as? URLError else {
            return .connection
        }
        switch error.code {
        case .timedOut:
            return .timeout
        case .secureConnectionFailed, .serverCertificateHasBadDate,
            .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid, .clientCertificateRejected,
            .clientCertificateRequired:
            return .tls
        default:
            return .connection
        }
    }

    private static func safeStatus(_ value: Int) -> Int {
        (100...599).contains(value) ? value : 500
    }
}

struct ElasticsearchDatabaseRootResponse: Decodable, Equatable, Sendable {
    let name: String
    let clusterName: String
    let clusterUUID: String
    let version: Version
    let tagline: String

    struct Version: Decodable, Equatable, Sendable {
        let number: String
        let buildFlavor: String
        let buildType: String
        let buildHash: String

        private enum CodingKeys: String, CodingKey {
            case number
            case buildFlavor = "build_flavor"
            case buildType = "build_type"
            case buildHash = "build_hash"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case clusterName = "cluster_name"
        case clusterUUID = "cluster_uuid"
        case version
        case tagline
    }
}

struct ElasticsearchDatabaseNodesResponse: Decodable, Equatable, Sendable {
    let summary: Summary
    let clusterName: String
    let nodes: [String: Node]

    struct Summary: Decodable, Equatable, Sendable {
        let total: Int
        let successful: Int
        let failed: Int
    }

    struct Node: Decodable, Equatable, Sendable {
        let name: String
        let version: String
        let roles: [String]
        let plugins: [Extension]?
        let modules: [Extension]?
    }

    struct Extension: Decodable, Equatable, Sendable {
        let name: String
        let version: String?
    }

    private enum CodingKeys: String, CodingKey {
        case summary = "_nodes"
        case clusterName = "cluster_name"
        case nodes
    }
}

enum ElasticsearchDatabaseDriverSupport {
    private static let maximumClusterNodes = 10_000
    private static let maximumNodeRoles = 64
    private static let maximumExtensions = 128
    private static let maximumResolvedObjects = 10_000
    private static let maximumMappingIndices = 256
    private static let maximumMappingFields = DatabaseAdapterBounds.maximumPageFields
    private static let maximumMappingDepth = 32
    private static let maximumSearchHits = DatabasePageSize.range.upperBound + 1
    private static let maximumSearchShards = 100_000
    private static let maximumShardFailures = DatabaseAdapterBounds.maximumPartialFailures
    private static let maximumSortValues = DatabaseAdapterBounds.maximumSorts + 1
    private static let maximumHighlightFields = 64
    private static let maximumHighlightFragments = 16

    static func identity(
        root: ElasticsearchDatabaseRootResponse,
        nodes: ElasticsearchDatabaseNodesResponse
    ) throws(ElasticsearchDatabaseDriverFailure) -> DatabaseProductIdentity {
        guard valid(root.name, maximumBytes: 1_024),
            valid(root.clusterName, maximumBytes: 1_024),
            valid(root.clusterUUID, maximumBytes: 256),
            valid(root.version.number, maximumBytes: 128),
            valid(root.version.buildFlavor, maximumBytes: 128),
            valid(root.version.buildType, maximumBytes: 128),
            valid(root.version.buildHash, maximumBytes: 256),
            valid(root.tagline, maximumBytes: 1_024),
            nodes.clusterName == root.clusterName,
            nodes.summary.total > 0,
            nodes.summary.total <= maximumClusterNodes,
            nodes.summary.successful >= 0,
            nodes.summary.failed >= 0,
            nodes.summary.successful == nodes.nodes.count,
            nodes.summary.total == nodes.summary.successful + nodes.summary.failed
        else {
            throw .invalidResponse
        }
        let localNodes = nodes.nodes.values.filter { $0.name == root.name }
        guard localNodes.count <= 1 else {
            throw .invalidResponse
        }
        var modules = Set<ElasticsearchDatabaseExtensionValue>()
        var plugins = Set<ElasticsearchDatabaseExtensionValue>()
        var nodeVersions = Set<String>()
        for (identifier, node) in nodes.nodes {
            guard valid(identifier, maximumBytes: 256),
                valid(node.name, maximumBytes: 1_024),
                valid(node.version, maximumBytes: 128),
                node.roles.count <= maximumNodeRoles,
                node.roles.allSatisfy({ valid($0, maximumBytes: 128) })
            else {
                throw .invalidResponse
            }
            nodeVersions.insert(node.version)
            try collect(node.modules ?? [], into: &modules)
            try collect(node.plugins ?? [], into: &plugins)
        }
        guard modules.count <= maximumExtensions,
            plugins.count <= maximumExtensions
        else {
            throw .responseTooLarge
        }
        let roles = localNodes.first?.roles.sorted() ?? []
        var attributes = [
            DatabaseStringAttribute(name: "buildFlavor", value: root.version.buildFlavor),
            DatabaseStringAttribute(name: "buildType", value: root.version.buildType),
            DatabaseStringAttribute(name: "buildHash", value: root.version.buildHash),
            DatabaseStringAttribute(
                name: "respondingNodes",
                value: String(nodes.summary.successful)),
            DatabaseStringAttribute(
                name: "failedNodes",
                value: String(nodes.summary.failed)),
        ]
        if !roles.isEmpty {
            attributes.append(
                DatabaseStringAttribute(name: "localRoles", value: roles.joined(separator: ",")))
        }
        var compatibilityNotes: [String] = []
        if nodes.summary.failed > 0 {
            compatibilityNotes.append("Node topology discovery returned partial results.")
        }
        if nodeVersions.count > 1 {
            compatibilityNotes.append("Cluster nodes report mixed Elasticsearch versions.")
        }
        let parsedVersion = parsedVersion(root.version.number)
        return DatabaseProductIdentity(
            product: .elasticsearch,
            version: DatabaseVersion(
                string: root.version.number,
                major: parsedVersion.major,
                minor: parsedVersion.minor,
                patch: parsedVersion.patch),
            distribution: "Elasticsearch",
            topology: DatabaseTopology(
                kind: nodes.summary.total == 1 ? .standalone : .cluster,
                name: root.clusterName,
                localRole: localRole(roles),
                nodeCount: nodes.summary.total,
                attributes: attributes),
            serverIdentifier: root.clusterUUID,
            modules: modules.sorted().map(\.identity),
            plugins: plugins.sorted().map(\.identity),
            compatibilityNotes: compatibilityNotes)
    }

    static func validate(
        _ response: ElasticsearchDatabaseSearchResponse
    ) throws(ElasticsearchDatabaseDriverFailure) {
        guard response.shards.total >= 0,
            response.shards.total <= maximumSearchShards,
            response.shards.successful >= 0,
            response.shards.failed >= 0,
            response.shards.skipped >= 0,
            response.shards.successful + response.shards.failed == response.shards.total,
            response.shards.skipped <= response.shards.successful,
            response.hits.hits.count <= maximumSearchHits,
            response.aggregations?.count ?? 0 <= 64,
            response.pointInTimeID.map(validOpaqueIdentifier) ?? true
        else {
            throw .invalidResponse
        }
        let failures = response.shards.failures ?? []
        guard failures.count <= maximumShardFailures else {
            throw .responseTooLarge
        }
        for failure in failures {
            guard failure.index.map({ valid($0, maximumBytes: 1_024) }) ?? true,
                failure.shard.map({ $0 >= 0 }) ?? true
            else {
                throw .invalidResponse
            }
        }
        for hit in response.hits.hits {
            guard valid(hit.index, maximumBytes: 1_024),
                hit.identifier.map({ valid($0, maximumBytes: 4_096) }) ?? true,
                hit.sequenceNumber.map({ $0 >= 0 }) ?? true,
                hit.primaryTerm.map({ $0 >= 0 }) ?? true,
                hit.sort?.count ?? 0 <= maximumSortValues,
                hit.sort?.allSatisfy({ $0.isBoundedScalar() }) ?? true,
                hit.highlight?.count ?? 0 <= maximumHighlightFields
            else {
                throw .invalidResponse
            }
            for (field, fragments) in hit.highlight ?? [:] {
                guard valid(field, maximumBytes: 4_096),
                    fragments.count <= maximumHighlightFragments,
                    fragments.allSatisfy({ valid($0, maximumBytes: 16_384) })
                else {
                    throw .responseTooLarge
                }
            }
        }
    }

    static func validate(
        _ response: ElasticsearchDatabaseResolveResponse
    ) throws(ElasticsearchDatabaseDriverFailure) {
        let count = response.indices.count + response.aliases.count + response.dataStreams.count
        guard count <= maximumResolvedObjects else {
            throw .responseTooLarge
        }
        for index in response.indices {
            guard validTargetName(index.name),
                index.aliases.count <= 1_024,
                index.aliases.allSatisfy(validTargetName),
                index.attributes.count <= 64,
                index.attributes.allSatisfy({ valid($0, maximumBytes: 128) }),
                index.dataStream.map(validTargetName) ?? true,
                index.mode.map({ valid($0, maximumBytes: 128) }) ?? true
            else {
                throw .invalidResponse
            }
        }
        for alias in response.aliases {
            guard validTargetName(alias.name),
                alias.indices.count <= maximumResolvedObjects,
                alias.indices.allSatisfy(validTargetName)
            else {
                throw .invalidResponse
            }
        }
        for dataStream in response.dataStreams {
            guard validTargetName(dataStream.name),
                dataStream.backingIndices.count <= maximumResolvedObjects,
                dataStream.backingIndices.allSatisfy(validTargetName),
                valid(dataStream.timestampField, maximumBytes: 4_096)
            else {
                throw .invalidResponse
            }
        }
    }

    static func validate(
        _ response: ElasticsearchDatabaseMappingResponse
    ) throws(ElasticsearchDatabaseDriverFailure) {
        guard response.indices.count <= maximumMappingIndices else {
            throw .responseTooLarge
        }
        var fieldCount = 0
        for (index, value) in response.indices {
            guard validTargetName(index) else { throw .invalidResponse }
            try validateMappingFields(
                value.mappings.properties ?? [:],
                depth: 0,
                fieldCount: &fieldCount)
            try validateMappingFields(
                value.mappings.runtime ?? [:],
                depth: 0,
                fieldCount: &fieldCount)
        }
    }

    static func pathSegment(
        _ value: String
    ) throws(ElasticsearchDatabaseDriverFailure) -> String {
        guard validTargetName(value) else {
            throw .invalidConfiguration
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/\\?#%:,*")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
            !encoded.isEmpty
        else {
            throw .invalidConfiguration
        }
        return encoded
    }

    static func documentPathSegment(
        _ value: String
    ) throws(ElasticsearchDatabaseDriverFailure) -> String {
        guard !value.isEmpty,
            value.utf8.count <= 512,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw .invalidConfiguration
        }
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/\\?#%")
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
            !encoded.isEmpty
        else {
            throw .invalidConfiguration
        }
        return encoded
    }

    static func validTargetName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 255 && value != "." && value != ".."
            && value != "_all" && !value.hasPrefix("_")
            && !value.contains("\0") && !value.contains("/") && !value.contains("\\")
            && !value.contains("?") && !value.contains("#") && !value.contains("%")
            && !value.contains(":") && !value.contains(",") && !value.contains("*")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    static func validOpaqueIdentifier(_ value: String) -> Bool {
        valid(value, maximumBytes: DatabaseAdapterBounds.maximumContinuationBytes)
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func validateMappingFields(
        _ fields: [String: ElasticsearchDatabaseMappingResponse.Field],
        depth: Int,
        fieldCount: inout Int
    ) throws(ElasticsearchDatabaseDriverFailure) {
        guard depth <= maximumMappingDepth else { throw .responseTooLarge }
        for (name, field) in fields {
            fieldCount += 1
            guard fieldCount <= maximumMappingFields else { throw .responseTooLarge }
            guard valid(name, maximumBytes: 4_096),
                !name.unicodeScalars.contains(where: {
                    CharacterSet.controlCharacters.contains($0)
                }),
                field.type.map({
                    valid($0, maximumBytes: 128)
                        && !$0.unicodeScalars.contains(where: {
                            CharacterSet.controlCharacters.contains($0)
                        })
                }) ?? true
            else {
                throw .invalidResponse
            }
            try validateMappingFields(
                field.properties ?? [:],
                depth: depth + 1,
                fieldCount: &fieldCount)
            try validateMappingFields(
                field.fields ?? [:],
                depth: depth + 1,
                fieldCount: &fieldCount)
        }
    }

    static func validKeepAlive(_ value: String) -> Bool {
        value == "60s"
    }

    private static func collect(
        _ values: [ElasticsearchDatabaseNodesResponse.Extension],
        into output: inout Set<ElasticsearchDatabaseExtensionValue>
    ) throws(ElasticsearchDatabaseDriverFailure) {
        guard values.count <= maximumExtensions else {
            throw .responseTooLarge
        }
        for value in values {
            guard valid(value.name, maximumBytes: 4_096),
                value.version.map({ valid($0, maximumBytes: 4_096) }) ?? true
            else {
                throw .invalidResponse
            }
            output.insert(
                ElasticsearchDatabaseExtensionValue(
                    name: value.name,
                    version: value.version))
        }
    }

    private static func localRole(_ roles: [String]) -> String? {
        if roles.contains("master") {
            return "master-eligible"
        }
        if roles.contains(where: { $0 == "data" || $0.hasPrefix("data_") }) {
            return "data"
        }
        if roles.contains("ingest") {
            return "ingest"
        }
        return roles.isEmpty ? "coordinating-only" : roles.first
    }

    private static func parsedVersion(
        _ value: String
    ) -> (major: Int?, minor: Int?, patch: Int?) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        return (
            numericPrefix(components.indices.contains(0) ? components[0] : ""),
            numericPrefix(components.indices.contains(1) ? components[1] : ""),
            numericPrefix(components.indices.contains(2) ? components[2] : "")
        )
    }

    private static func numericPrefix(_ value: Substring) -> Int? {
        let digits = value.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
    }
}

private struct ElasticsearchDatabaseExtensionValue: Hashable, Comparable, Sendable {
    let name: String
    let version: String?

    var identity: DatabaseExtensionIdentity {
        DatabaseExtensionIdentity(name: name, version: version)
    }

    static func < (
        lhs: ElasticsearchDatabaseExtensionValue,
        rhs: ElasticsearchDatabaseExtensionValue
    ) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return (lhs.version ?? "") < (rhs.version ?? "")
    }
}
