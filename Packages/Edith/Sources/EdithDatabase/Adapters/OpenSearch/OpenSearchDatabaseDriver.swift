import Foundation

enum OpenSearchDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case connection
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
    func disconnect() async
}

typealias OpenSearchDatabaseSessionFactory =
    @Sendable (OpenSearchDatabaseConnectionPlan) -> URLSession

typealias OpenSearchDatabaseClientConnector =
    @Sendable (OpenSearchDatabaseConnectionPlan) async throws -> any OpenSearchDatabaseClient

actor URLSessionOpenSearchDatabaseClient: OpenSearchDatabaseClient {
    private let plan: OpenSearchDatabaseConnectionPlan
    private var session: URLSession?
    private var identity: DatabaseProductIdentity?

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

    func disconnect() {
        let session = self.session
        self.session = nil
        identity = nil
        session?.invalidateAndCancel()
    }

    private func prepare() async throws {
        let rootResponse = try await get(path: "/")
        try OpenSearchDatabaseDriverErrorClassifier.validate(rootResponse)
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
        let nodesResponse = try await get(
            path: "/_nodes/_all/plugins",
            queryItems: [
                URLQueryItem(
                    name: "filter_path",
                    value:
                        "_nodes,cluster_name,nodes.*.name,nodes.*.roles,nodes.*.version,nodes.*.plugins.name,nodes.*.plugins.version,nodes.*.modules.name,nodes.*.modules.version"
                )
            ])
        try OpenSearchDatabaseDriverErrorClassifier.validate(nodesResponse)
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

    private func get(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> OpenSearchDatabaseHTTPResponse {
        guard let session else {
            throw OpenSearchDatabaseDriverFailure.connection
        }
        let request = try OpenSearchDatabaseTransport.request(
            endpoint: plan.endpoint,
            path: path,
            queryItems: queryItems,
            authorization: plan.authorization)
        let requestTimeoutMilliseconds = plan.requestTimeoutMilliseconds
        let maximumResponseBytes = plan.maximumResponseBytes
        do {
            return try await OpenSearchDatabaseDeadline.run(
                milliseconds: requestTimeoutMilliseconds
            ) {
                try await OpenSearchDatabaseTransport.execute(
                    session: session,
                    request: request,
                    maximumResponseBytes: maximumResponseBytes)
            }
        } catch {
            throw try OpenSearchDatabaseDriverErrorClassifier.classify(error)
        }
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
