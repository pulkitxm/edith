import Foundation

enum ElasticsearchDatabaseDriverFailure: Error, Equatable, Sendable {
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
    func disconnect() async
}

typealias ElasticsearchDatabaseSessionFactory =
    @Sendable (ElasticsearchDatabaseConnectionPlan) -> URLSession

typealias ElasticsearchDatabaseClientConnector =
    @Sendable (ElasticsearchDatabaseConnectionPlan) async throws -> any ElasticsearchDatabaseClient

actor URLSessionElasticsearchDatabaseClient: ElasticsearchDatabaseClient {
    private let plan: ElasticsearchDatabaseConnectionPlan
    private var session: URLSession?
    private var identity: DatabaseProductIdentity?

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

    func disconnect() {
        let session = self.session
        self.session = nil
        identity = nil
        session?.invalidateAndCancel()
    }

    private func prepare() async throws {
        let rootResponse = try await get(path: "/")
        try ElasticsearchDatabaseDriverErrorClassifier.validate(rootResponse)
        let root: ElasticsearchDatabaseRootResponse
        do {
            root = try JSONDecoder().decode(
                ElasticsearchDatabaseRootResponse.self,
                from: rootResponse.body)
        } catch {
            throw ElasticsearchDatabaseDriverFailure.invalidResponse
        }
        let nodesResponse = try await get(
            path: "/_nodes/_all/plugins",
            queryItems: [
                URLQueryItem(
                    name: "filter_path",
                    value:
                        "_nodes,cluster_name,nodes.*.name,nodes.*.roles,nodes.*.version,nodes.*.plugins.name,nodes.*.plugins.version,nodes.*.modules.name,nodes.*.modules.version"
                )
            ])
        try ElasticsearchDatabaseDriverErrorClassifier.validate(nodesResponse)
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

    private func get(
        path: String,
        queryItems: [URLQueryItem] = []
    ) async throws -> ElasticsearchDatabaseHTTPResponse {
        guard let session else {
            throw ElasticsearchDatabaseDriverFailure.connection
        }
        let request = try ElasticsearchDatabaseTransport.request(
            endpoint: plan.endpoint,
            path: path,
            queryItems: queryItems,
            authorization: plan.authorization)
        do {
            return try await ElasticsearchDatabaseTransport.execute(
                session: session,
                request: request,
                maximumResponseBytes: plan.maximumResponseBytes)
        } catch {
            throw try ElasticsearchDatabaseDriverErrorClassifier.classify(error)
        }
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
