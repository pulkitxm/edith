import Foundation

enum OpenSearchDatabaseDriverFailure: Error, Equatable, Sendable {
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

enum OpenSearchDatabaseAuthorization: Equatable, Sendable {
    case none
    case basic(username: String, password: String)
    case bearer(token: String)
    case apiKey(token: String)

    var headerValue: String? {
        switch self {
        case .none:
            return nil
        case let .basic(username, password):
            return "Basic \(Data("\(username):\(password)".utf8).base64EncodedString())"
        case let .bearer(token):
            return "Bearer \(token)"
        case let .apiKey(token):
            return "ApiKey \(token)"
        }
    }

    func validate() throws(OpenSearchDatabaseDriverFailure) {
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
            guard Self.validToken(token, maximumBytes: 1_048_576) else {
                throw .invalidConfiguration
            }
        case let .apiKey(token):
            guard token.hasPrefix("os_"),
                Self.validToken(token, maximumBytes: 1_048_576)
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

    private static func validToken(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        valid(value, maximumBytes: maximumBytes)
            && value.unicodeScalars.allSatisfy {
                !CharacterSet.whitespacesAndNewlines.contains($0)
            }
    }
}

struct OpenSearchDatabaseConnectionPlan: Sendable {
    let endpoint: URL
    let authorization: OpenSearchDatabaseAuthorization
    let connectTimeoutMilliseconds: UInt64
    let requestTimeoutMilliseconds: UInt64
    let maximumResponseBytes: Int
}

protocol OpenSearchDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func resolveIndexes() async throws -> OpenSearchDatabaseResolveResponse
    func mapping(
        target: String
    ) async throws -> OpenSearchDatabaseMappingResponse
    func settings(
        target: String
    ) async throws -> OpenSearchDatabaseSettingsResponse
    func openPointInTime(
        target: String,
        keepAlive: String
    ) async throws -> String
    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> OpenSearchDatabaseSearchResponse
    func closePointInTime(_ identifier: String) async throws
    func mutate(
        _ plan: OpenSearchDatabaseMutationPlan
    ) async throws -> OpenSearchDatabaseMutationResult
    func disconnect() async
}

enum OpenSearchDatabaseMutationOperation: Equatable, Sendable {
    case create(body: Data)
    case replace(body: Data, sequenceNumber: Int64, primaryTerm: Int64)
    case delete(sequenceNumber: Int64, primaryTerm: Int64)
}

struct OpenSearchDatabaseMutationPlan: Equatable, Sendable {
    let index: String
    let identifier: String
    let operation: OpenSearchDatabaseMutationOperation
}

struct OpenSearchDatabaseMutationResult: Equatable, Sendable {
    let index: String
    let identifier: String
    let result: String
    let sequenceNumber: Int64
    let primaryTerm: Int64
}

typealias OpenSearchDatabaseSessionFactory =
    @Sendable (OpenSearchDatabaseConnectionPlan) -> URLSession

typealias OpenSearchDatabaseClientConnector =
    @Sendable (OpenSearchDatabaseConnectionPlan) async throws -> any OpenSearchDatabaseClient

actor URLSessionOpenSearchDatabaseClient: OpenSearchDatabaseClient {
    private let plan: OpenSearchDatabaseConnectionPlan
    private var session: URLSession?
    private var identity: DatabaseProductIdentity?
    private var openPointInTimeIdentifiers: [String: Date] = [:]

    private init(
        plan: OpenSearchDatabaseConnectionPlan,
        session: URLSession
    ) {
        self.plan = plan
        self.session = session
    }

    static func connect(
        _ plan: OpenSearchDatabaseConnectionPlan,
        sessionFactory: OpenSearchDatabaseSessionFactory = {
            OpenSearchDatabaseTransport.makeSession($0)
        }
    ) async throws -> any OpenSearchDatabaseClient {
        try Task.checkCancellation()
        try OpenSearchDatabaseTransport.validate(plan)
        let client = URLSessionOpenSearchDatabaseClient(
            plan: plan,
            session: sessionFactory(plan))
        do {
            try await OpenSearchDatabaseDeadline.run(
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
            throw try OpenSearchDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard session != nil, let identity else {
            throw OpenSearchDatabaseDriverFailure.connection
        }
        return identity
    }

    func resolveIndexes() async throws -> OpenSearchDatabaseResolveResponse {
        let response = try await send(
            path: "/_resolve/index/*",
            queryItems: [URLQueryItem(name: "expand_wildcards", value: "open")])
        let decoded = try decode(OpenSearchDatabaseResolveResponse.self, from: response.body)
        try OpenSearchDatabaseDriverSupport.validate(decoded)
        return decoded
    }

    func mapping(
        target: String
    ) async throws -> OpenSearchDatabaseMappingResponse {
        let segment = try OpenSearchDatabaseDriverSupport.pathSegment(target)
        let response = try await send(
            path: "/\(segment)/_mapping",
            queryItems: [URLQueryItem(name: "filter_path", value: "*.mappings")])
        let decoded = try decode(OpenSearchDatabaseMappingResponse.self, from: response.body)
        try OpenSearchDatabaseDriverSupport.validate(decoded)
        return decoded
    }

    func settings(
        target: String
    ) async throws -> OpenSearchDatabaseSettingsResponse {
        let segment = try OpenSearchDatabaseDriverSupport.pathSegment(target)
        let response = try await send(
            path: "/\(segment)/_settings",
            queryItems: [
                URLQueryItem(name: "flat_settings", value: "true"),
                URLQueryItem(name: "include_defaults", value: "false"),
                URLQueryItem(name: "filter_path", value: "*.settings.*"),
            ])
        let decoded = try decode(OpenSearchDatabaseSettingsResponse.self, from: response.body)
        try OpenSearchDatabaseDriverSupport.validate(decoded, expectedTarget: target)
        return decoded
    }

    func openPointInTime(
        target: String,
        keepAlive: String
    ) async throws -> String {
        let segment = try OpenSearchDatabaseDriverSupport.pathSegment(target)
        guard OpenSearchDatabaseDriverSupport.validKeepAlive(keepAlive) else {
            throw OpenSearchDatabaseDriverFailure.invalidConfiguration
        }
        let now = Date()
        openPointInTimeIdentifiers = openPointInTimeIdentifiers.filter { $0.value > now }
        guard openPointInTimeIdentifiers.count < 8 else {
            throw OpenSearchDatabaseDriverFailure.responseTooLarge
        }
        let response = try await send(
            method: .post,
            path: "/\(segment)/_search/point_in_time",
            queryItems: [
                URLQueryItem(name: "keep_alive", value: keepAlive),
                URLQueryItem(name: "allow_partial_pit_creation", value: "false"),
                URLQueryItem(name: "expand_wildcards", value: "open"),
            ])
        let decoded = try decode(
            OpenSearchDatabaseOpenPointInTimeResponse.self,
            from: response.body)
        try OpenSearchDatabaseDriverSupport.validate(decoded)
        openPointInTimeIdentifiers[decoded.pointInTimeID] = now.addingTimeInterval(60)
        return decoded.pointInTimeID
    }

    func search(
        body: Data,
        pointInTimeID: String
    ) async throws -> OpenSearchDatabaseSearchResponse {
        guard OpenSearchDatabaseDriverSupport.validOpaqueIdentifier(pointInTimeID) else {
            throw OpenSearchDatabaseDriverFailure.invalidConfiguration
        }
        let boundedBody: Data
        do {
            var value = try JSONDecoder().decode(
                OpenSearchDatabaseJSONValue.self,
                from: body)
            guard case var .object(fields) = value,
                case var .object(pointInTime)? = fields["pit"],
                pointInTime["keep_alive"] == .string("60s")
            else {
                throw OpenSearchDatabaseDriverFailure.invalidConfiguration
            }
            pointInTime["id"] = .string(pointInTimeID)
            fields["pit"] = .object(pointInTime)
            value = .object(fields)
            boundedBody = try OpenSearchDatabaseJSONCodec.encode(value)
        } catch let failure as OpenSearchDatabaseDriverFailure {
            throw failure
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidConfiguration
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
        let decoded = try decode(OpenSearchDatabaseSearchResponse.self, from: response.body)
        try OpenSearchDatabaseDriverSupport.validate(decoded)
        let refreshed = decoded.pointInTimeID ?? pointInTimeID
        openPointInTimeIdentifiers.removeValue(forKey: pointInTimeID)
        openPointInTimeIdentifiers[refreshed] = Date().addingTimeInterval(60)
        return decoded
    }

    func closePointInTime(_ identifier: String) async throws {
        guard OpenSearchDatabaseDriverSupport.validOpaqueIdentifier(identifier) else {
            throw OpenSearchDatabaseDriverFailure.invalidConfiguration
        }
        defer { openPointInTimeIdentifiers.removeValue(forKey: identifier) }
        let body: Data
        do {
            body = try OpenSearchDatabaseJSONCodec.encode(
                .object(["pit_id": .array([.string(identifier)])]))
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidConfiguration
        }
        let response = try await send(
            method: .delete,
            path: "/_search/point_in_time",
            body: body)
        let decoded = try decode(
            OpenSearchDatabaseClosePointInTimeResponse.self,
            from: response.body)
        guard decoded.pits.count == 1,
            decoded.pits[0].successful,
            decoded.pits[0].pointInTimeID == identifier
        else {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
    }

    func mutate(
        _ mutation: OpenSearchDatabaseMutationPlan
    ) async throws -> OpenSearchDatabaseMutationResult {
        let index = try OpenSearchDatabaseDriverSupport.pathSegment(mutation.index)
        let identifier = try OpenSearchDatabaseDriverSupport.documentPathSegment(
            mutation.identifier)
        let method: OpenSearchDatabaseHTTPMethod
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
                throw OpenSearchDatabaseDriverFailure.invalidConfiguration
            }
            method = .put
            path = "/\(index)/_doc/\(identifier)"
            queryItems.append(URLQueryItem(name: "if_seq_no", value: String(sequenceNumber)))
            queryItems.append(URLQueryItem(name: "if_primary_term", value: String(primaryTerm)))
            body = document
        case .delete(let sequenceNumber, let primaryTerm):
            guard sequenceNumber >= 0, primaryTerm >= 0 else {
                throw OpenSearchDatabaseDriverFailure.invalidConfiguration
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
            OpenSearchDatabaseDocumentMutationResponse.self,
            from: response.body)
        guard decoded.index == mutation.index,
            decoded.identifier == mutation.identifier,
            decoded.sequenceNumber >= 0,
            decoded.primaryTerm >= 0,
            ["created", "updated", "deleted"].contains(decoded.result)
        else {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
        return OpenSearchDatabaseMutationResult(
            index: decoded.index,
            identifier: decoded.identifier,
            result: decoded.result,
            sequenceNumber: decoded.sequenceNumber,
            primaryTerm: decoded.primaryTerm)
    }

    func disconnect() async {
        let session = self.session
        let identifiers = openPointInTimeIdentifiers.keys
        openPointInTimeIdentifiers.removeAll()
        if let session {
            for identifier in identifiers.prefix(8) {
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

    private func prepare() async throws {
        let rootResponse = try await send(path: "/")
        let signature: OpenSearchDatabaseProductSignature
        do {
            signature = try JSONDecoder().decode(
                OpenSearchDatabaseProductSignature.self,
                from: rootResponse.body)
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
        try OpenSearchDatabaseDriverSupport.validateProduct(
            signature: signature,
            response: rootResponse)
        let root: OpenSearchDatabaseRootResponse
        do {
            root = try JSONDecoder().decode(
                OpenSearchDatabaseRootResponse.self,
                from: rootResponse.body)
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
        try OpenSearchDatabaseDriverSupport.validateProduct(
            root: root,
            response: rootResponse)
        let nodesResponse = try await send(
            path: "/_nodes/_all/plugins",
            queryItems: [
                URLQueryItem(
                    name: "filter_path",
                    value:
                        "_nodes,cluster_name,nodes.*.name,nodes.*.roles,nodes.*.version,nodes.*.plugins.name,nodes.*.plugins.version,nodes.*.modules.name,nodes.*.modules.version"
                )
            ])
        try OpenSearchDatabaseDriverSupport.validateProductHeaders(
            response: nodesResponse,
            expectedVersion: root.version.number)
        let nodes: OpenSearchDatabaseNodesResponse
        do {
            nodes = try JSONDecoder().decode(
                OpenSearchDatabaseNodesResponse.self,
                from: nodesResponse.body)
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
        identity = try OpenSearchDatabaseDriverSupport.identity(
            root: root,
            nodes: nodes)
    }

    private func send(
        method: OpenSearchDatabaseHTTPMethod = .get,
        path: String,
        queryItems: [URLQueryItem] = [],
        body: Data? = nil
    ) async throws -> OpenSearchDatabaseHTTPResponse {
        guard let session else {
            throw OpenSearchDatabaseDriverFailure.connection
        }
        let request = try OpenSearchDatabaseTransport.request(
            endpoint: plan.endpoint,
            path: path,
            method: method,
            queryItems: queryItems,
            body: body,
            authorization: plan.authorization)
        let requestTimeoutMilliseconds = plan.requestTimeoutMilliseconds
        let maximumResponseBytes = plan.maximumResponseBytes
        do {
            let response = try await OpenSearchDatabaseDeadline.run(
                milliseconds: requestTimeoutMilliseconds
            ) {
                try await OpenSearchDatabaseTransport.execute(
                    session: session,
                    request: request,
                    maximumResponseBytes: maximumResponseBytes)
            }
            try OpenSearchDatabaseDriverErrorClassifier.validate(response)
            if let version = identity?.version?.string {
                try OpenSearchDatabaseDriverSupport.validateProductHeaders(
                    response: response,
                    expectedVersion: version)
            }
            return response
        } catch {
            throw try OpenSearchDatabaseDriverErrorClassifier.classify(error)
        }
    }

    private func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw OpenSearchDatabaseDriverFailure.invalidResponse
        }
    }

    private static func closePointInTime(
        _ identifier: String,
        session: URLSession,
        plan: OpenSearchDatabaseConnectionPlan
    ) async {
        guard
            let body = try? OpenSearchDatabaseJSONCodec.encode(
                .object(["pit_id": .array([.string(identifier)])])),
            let request = try? OpenSearchDatabaseTransport.request(
                endpoint: plan.endpoint,
                path: "/_search/point_in_time",
                method: .delete,
                queryItems: [],
                body: body,
                authorization: plan.authorization),
            let response = try? await OpenSearchDatabaseDeadline.run(
                milliseconds: min(plan.requestTimeoutMilliseconds, 2_000),
                operation: {
                    try await OpenSearchDatabaseTransport.execute(
                        session: session,
                        request: request,
                        maximumResponseBytes: plan.maximumResponseBytes)
                })
        else {
            return
        }
        try? OpenSearchDatabaseDriverErrorClassifier.validate(response)
    }
}

struct OpenSearchDatabaseResolveResponse: Decodable, Sendable {
    let indices: [Index]
    let aliases: [Alias]
    let dataStreams: [DataStream]

    struct Index: Decodable, Sendable {
        let name: String
        let aliases: [String]
        let attributes: [String]
        let dataStream: String?
        let mode: String?

        init(
            name: String,
            aliases: [String],
            attributes: [String],
            dataStream: String?,
            mode: String?
        ) {
            self.name = name
            self.aliases = aliases
            self.attributes = attributes
            self.dataStream = dataStream
            self.mode = mode
        }

        private enum CodingKeys: String, CodingKey {
            case name
            case aliases
            case attributes
            case dataStream = "data_stream"
            case mode
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            name = try container.decode(String.self, forKey: .name)
            aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
            attributes = try container.decodeIfPresent([String].self, forKey: .attributes) ?? []
            dataStream = try container.decodeIfPresent(String.self, forKey: .dataStream)
            mode = try container.decodeIfPresent(String.self, forKey: .mode)
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

struct OpenSearchDatabaseMappingResponse: Decodable, Sendable {
    let indices: [String: Index]

    init(indices: [String: Index]) {
        self.indices = indices
    }

    struct Index: Decodable, Sendable {
        let mappings: Mapping
    }

    struct Mapping: Decodable, Sendable {
        let dynamic: OpenSearchDatabaseJSONValue?
        let properties: [String: Field]?
        let runtime: [String: Field]?
        let derived: [String: Field]?
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

struct OpenSearchDatabaseSettingsResponse: Decodable, Sendable {
    let indices: [String: Index]

    init(indices: [String: Index]) {
        self.indices = indices
    }

    struct Index: Decodable, Sendable {
        let settings: [String: String]
    }

    init(from decoder: Decoder) throws {
        indices = try decoder.singleValueContainer().decode([String: Index].self)
    }
}

struct OpenSearchDatabaseSearchResponse: Decodable, Sendable {
    let took: UInt64
    let timedOut: Bool
    let pointInTimeID: String?
    let shards: Shards
    let hits: Hits
    let aggregations: [String: OpenSearchDatabaseJSONValue]?

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
        let total: Total?
        let hits: [Hit]

        private enum CodingKeys: String, CodingKey {
            case total
            case hits
        }

        init(total: Total?, hits: [Hit]) {
            self.total = total
            self.hits = hits
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            total = try container.decodeIfPresent(Total.self, forKey: .total)
            hits = try container.decodeIfPresent([Hit].self, forKey: .hits) ?? []
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
        let source: OpenSearchDatabaseJSONValue?
        let sort: [OpenSearchDatabaseJSONValue]?
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

struct OpenSearchDatabaseOpenPointInTimeResponse: Decodable, Sendable {
    let pointInTimeID: String
    let creationTime: UInt64
    let shards: OpenSearchDatabaseSearchResponse.Shards

    private enum CodingKeys: String, CodingKey {
        case pointInTimeID = "pit_id"
        case creationTime = "creation_time"
        case shards = "_shards"
    }
}

private struct OpenSearchDatabaseClosePointInTimeResponse: Decodable {
    let pits: [Result]

    struct Result: Decodable {
        let successful: Bool
        let pointInTimeID: String

        private enum CodingKeys: String, CodingKey {
            case successful
            case pointInTimeID = "pit_id"
        }
    }
}

private struct OpenSearchDatabaseDocumentMutationResponse: Decodable {
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

enum OpenSearchDatabaseDriverErrorClassifier {
    static func validate(
        _ response: OpenSearchDatabaseHTTPResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        switch response.statusCode {
        case 200..<300:
            return
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
    ) throws(CancellationError) -> OpenSearchDatabaseDriverFailure {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if let failure = error as? OpenSearchDatabaseDriverFailure {
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

struct OpenSearchDatabaseRootResponse: Decodable, Equatable, Sendable {
    let name: String
    let clusterName: String
    let clusterUUID: String
    let version: Version
    let tagline: String

    struct Version: Decodable, Equatable, Sendable {
        let distribution: String?
        let number: String
        let buildType: String
        let buildHash: String
        let buildDate: String
        let buildSnapshot: Bool
        let luceneVersion: String
        let minimumWireCompatibilityVersion: String
        let minimumIndexCompatibilityVersion: String

        private enum CodingKeys: String, CodingKey {
            case distribution
            case number
            case buildType = "build_type"
            case buildHash = "build_hash"
            case buildDate = "build_date"
            case buildSnapshot = "build_snapshot"
            case luceneVersion = "lucene_version"
            case minimumWireCompatibilityVersion = "minimum_wire_compatibility_version"
            case minimumIndexCompatibilityVersion = "minimum_index_compatibility_version"
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

struct OpenSearchDatabaseProductSignature: Decodable, Equatable, Sendable {
    let version: Version
    let tagline: String?

    struct Version: Decodable, Equatable, Sendable {
        let distribution: String?
        let number: String?
    }
}

struct OpenSearchDatabaseNodesResponse: Decodable, Equatable, Sendable {
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

enum OpenSearchDatabaseDriverSupport {
    private static let maximumClusterNodes = 10_000
    private static let maximumNodeRoles = 64
    private static let maximumExtensions = 128
    private static let maximumResolvedObjects = 10_000
    private static let maximumSearchHits = OpenSearchDatabaseReadCompiler.maximumPageSize + 1
    private static let maximumSearchShards = 100_000
    private static let maximumShardFailures = DatabaseAdapterBounds.maximumPartialFailures
    private static let maximumSortValues = DatabaseAdapterBounds.maximumSorts + 1
    private static let maximumHighlightFields = 64
    private static let maximumHighlightFragments = 16
    private static let maximumMappingIndices = 1_024
    private static let maximumSettings = 512

    static func validateProduct(
        signature: OpenSearchDatabaseProductSignature,
        response: OpenSearchDatabaseHTTPResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard signature.version.distribution == "opensearch",
            signature.tagline?.hasPrefix("The OpenSearch Project:") == true,
            response.elasticProductHeader == nil
        else {
            throw .unsupportedProduct
        }
        guard let version = signature.version.number,
            valid(version, maximumBytes: 128)
        else {
            throw .invalidResponse
        }
        try validateProductHeaders(
            response: response,
            expectedVersion: version)
    }

    static func validateProduct(
        root: OpenSearchDatabaseRootResponse,
        response: OpenSearchDatabaseHTTPResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard root.version.distribution == "opensearch",
            root.tagline.hasPrefix("The OpenSearch Project:"),
            response.elasticProductHeader == nil
        else {
            throw .unsupportedProduct
        }
        try validateProductHeaders(
            response: response,
            expectedVersion: root.version.number)
    }

    static func validateProductHeaders(
        response: OpenSearchDatabaseHTTPResponse,
        expectedVersion: String
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard response.elasticProductHeader == nil else {
            throw .unsupportedProduct
        }
        if let header = response.openSearchVersionHeader {
            guard header == "OpenSearch/\(expectedVersion) (opensearch)" else {
                throw .invalidResponse
            }
        }
    }

    static func identity(
        root: OpenSearchDatabaseRootResponse,
        nodes: OpenSearchDatabaseNodesResponse
    ) throws(OpenSearchDatabaseDriverFailure) -> DatabaseProductIdentity {
        guard root.version.distribution == "opensearch",
            valid(root.name, maximumBytes: 1_024),
            valid(root.clusterName, maximumBytes: 1_024),
            valid(root.clusterUUID, maximumBytes: 256),
            valid(root.version.number, maximumBytes: 128),
            valid(root.version.buildType, maximumBytes: 128),
            valid(root.version.buildHash, maximumBytes: 256),
            valid(root.version.buildDate, maximumBytes: 256),
            valid(root.version.luceneVersion, maximumBytes: 128),
            valid(root.version.minimumWireCompatibilityVersion, maximumBytes: 128),
            valid(root.version.minimumIndexCompatibilityVersion, maximumBytes: 128),
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
        var modules = Set<OpenSearchDatabaseExtensionValue>()
        var plugins = Set<OpenSearchDatabaseExtensionValue>()
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
            DatabaseStringAttribute(name: "buildType", value: root.version.buildType),
            DatabaseStringAttribute(name: "buildHash", value: root.version.buildHash),
            DatabaseStringAttribute(name: "buildDate", value: root.version.buildDate),
            DatabaseStringAttribute(
                name: "buildSnapshot",
                value: String(root.version.buildSnapshot)),
            DatabaseStringAttribute(name: "luceneVersion", value: root.version.luceneVersion),
            DatabaseStringAttribute(
                name: "minimumWireCompatibilityVersion",
                value: root.version.minimumWireCompatibilityVersion),
            DatabaseStringAttribute(
                name: "minimumIndexCompatibilityVersion",
                value: root.version.minimumIndexCompatibilityVersion),
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
            compatibilityNotes.append("Cluster nodes report mixed OpenSearch versions.")
        }
        let parsedVersion = parsedVersion(root.version.number)
        return DatabaseProductIdentity(
            product: .openSearch,
            version: DatabaseVersion(
                string: root.version.number,
                major: parsedVersion.major,
                minor: parsedVersion.minor,
                patch: parsedVersion.patch),
            distribution: "OpenSearch",
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
        _ response: OpenSearchDatabaseSearchResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        try validateShards(response.shards, requireComplete: false)
        guard response.hits.hits.count <= maximumSearchHits,
            response.aggregations?.count ?? 0 <= 64,
            response.pointInTimeID.map(validOpaqueIdentifier) ?? true
        else {
            throw .invalidResponse
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
        _ response: OpenSearchDatabaseOpenPointInTimeResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard validOpaqueIdentifier(response.pointInTimeID),
            response.creationTime > 0
        else {
            throw .invalidResponse
        }
        try validateShards(response.shards, requireComplete: true)
    }

    static func validate(
        _ response: OpenSearchDatabaseResolveResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        let count = response.indices.count + response.aliases.count + response.dataStreams.count
        guard count <= maximumResolvedObjects else {
            throw .responseTooLarge
        }
        var identities = Set<String>()
        for index in response.indices {
            guard validTargetName(index.name),
                identities.insert("index:" + index.name).inserted,
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
                identities.insert("alias:" + alias.name).inserted,
                alias.indices.count <= maximumResolvedObjects,
                alias.indices.allSatisfy(validTargetName)
            else {
                throw .invalidResponse
            }
        }
        for dataStream in response.dataStreams {
            guard validTargetName(dataStream.name),
                identities.insert("data-stream:" + dataStream.name).inserted,
                dataStream.backingIndices.count <= maximumResolvedObjects,
                dataStream.backingIndices.allSatisfy(validTargetName),
                valid(dataStream.timestampField, maximumBytes: 4_096)
            else {
                throw .invalidResponse
            }
        }
    }

    static func validate(
        _ response: OpenSearchDatabaseMappingResponse
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard !response.indices.isEmpty, response.indices.count <= maximumMappingIndices else {
            throw .invalidResponse
        }
        var count = 0
        for (index, value) in response.indices {
            guard validTargetName(index) else { throw .invalidResponse }
            try validateMappingFields(
                value.mappings.properties ?? [:],
                depth: 0,
                count: &count)
            try validateMappingFields(
                value.mappings.runtime ?? [:],
                depth: 0,
                count: &count)
            try validateMappingFields(
                value.mappings.derived ?? [:],
                depth: 0,
                count: &count)
        }
    }

    static func validate(
        _ response: OpenSearchDatabaseSettingsResponse,
        expectedTarget: String
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard validTargetName(expectedTarget), !response.indices.isEmpty,
            response.indices.count <= maximumMappingIndices
        else {
            throw .invalidResponse
        }
        for (index, value) in response.indices {
            guard validTargetName(index), value.settings.count <= maximumSettings else {
                throw .responseTooLarge
            }
            for (name, setting) in value.settings {
                guard name.hasPrefix("index."),
                    valid(name, maximumBytes: 4_096),
                    setting.utf8.count <= 4_096,
                    !setting.contains("\0")
                else {
                    throw .invalidResponse
                }
            }
        }
    }

    static func pathSegment(
        _ value: String
    ) throws(OpenSearchDatabaseDriverFailure) -> String {
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
    ) throws(OpenSearchDatabaseDriverFailure) -> String {
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

    static func validKeepAlive(_ value: String) -> Bool {
        value == "60s"
    }

    private static func validateShards(
        _ shards: OpenSearchDatabaseSearchResponse.Shards,
        requireComplete: Bool
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard shards.total >= 0,
            shards.total <= maximumSearchShards,
            shards.successful >= 0,
            shards.failed >= 0,
            shards.skipped >= 0,
            shards.successful + shards.failed <= shards.total,
            shards.skipped <= shards.successful
        else {
            throw .invalidResponse
        }
        if requireComplete {
            guard shards.total > 0, shards.successful == shards.total, shards.failed == 0 else {
                throw .invalidResponse
            }
        }
        let failures = shards.failures ?? []
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
    }

    private static func validateMappingFields(
        _ fields: [String: OpenSearchDatabaseMappingResponse.Field],
        depth: Int,
        count: inout Int
    ) throws(OpenSearchDatabaseDriverFailure) {
        guard depth <= 32 else { throw .responseTooLarge }
        for (name, field) in fields {
            count += 1
            guard count <= 20_000,
                !name.isEmpty,
                name.utf8.count <= 4_096,
                !name.contains("\0"),
                field.type.map({ valid($0, maximumBytes: 128) }) ?? true
            else {
                throw .responseTooLarge
            }
            try validateMappingFields(
                field.properties ?? [:],
                depth: depth + 1,
                count: &count)
            try validateMappingFields(
                field.fields ?? [:],
                depth: depth + 1,
                count: &count)
        }
    }

    private static func collect(
        _ values: [OpenSearchDatabaseNodesResponse.Extension],
        into output: inout Set<OpenSearchDatabaseExtensionValue>
    ) throws(OpenSearchDatabaseDriverFailure) {
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
                OpenSearchDatabaseExtensionValue(
                    name: value.name,
                    version: value.version))
        }
    }

    private static func localRole(_ roles: [String]) -> String? {
        if roles.contains("cluster_manager") || roles.contains("master") {
            return "cluster-manager-eligible"
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

private struct OpenSearchDatabaseExtensionValue: Hashable, Comparable, Sendable {
    let name: String
    let version: String?

    var identity: DatabaseExtensionIdentity {
        DatabaseExtensionIdentity(name: name, version: version)
    }

    static func < (
        lhs: OpenSearchDatabaseExtensionValue,
        rhs: OpenSearchDatabaseExtensionValue
    ) -> Bool {
        if lhs.name != rhs.name {
            return lhs.name < rhs.name
        }
        return (lhs.version ?? "") < (rhs.version ?? "")
    }
}
