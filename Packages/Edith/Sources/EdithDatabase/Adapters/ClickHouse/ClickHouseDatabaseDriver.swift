import Foundation

enum ClickHouseDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case configuration
    case connection
    case decoding
    case permission(String?)
    case resourceLimit(String?)
    case server(String?)
    case timeout
    case tls
}

enum ClickHouseDatabaseTLSPlan: Sendable {
    case disabled
    case required
}

struct ClickHouseDatabaseConnectionPlan: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let tls: ClickHouseDatabaseTLSPlan
    let requestTimeoutMilliseconds: UInt64
    let readOnly: Bool

    func baseURL() throws -> URL {
        guard (1...65_535).contains(port),
            requestTimeoutMilliseconds > 0,
            requestTimeoutMilliseconds <= 86_400_000,
            Self.validHost(host)
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        let normalizedHost =
            host.contains(":") && !(host.hasPrefix("[") && host.hasSuffix("]"))
            ? "[\(host)]"
            : host
        var components = URLComponents()
        switch tls {
        case .disabled:
            components.scheme = "http"
        case .required:
            components.scheme = "https"
        }
        components.host = normalizedHost
        components.port = port
        components.path = "/"
        guard let url = components.url,
            url.host() != nil,
            url.user() == nil,
            url.password() == nil
        else {
            throw ClickHouseDatabaseHTTPTransportFailure.invalidConfiguration
        }
        return url
    }

    private static func validHost(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || CharacterSet.whitespacesAndNewlines.contains($0)
            })
            && !value.contains("/") && !value.contains("?") && !value.contains("#")
            && !value.contains("@")
    }
}

struct ClickHouseDatabaseIdentityValues: Codable, Equatable, Sendable {
    let version: String
    let database: String
    let timezone: String
    let hostName: String
    let clusterName: String
    let clusterNodeCount: UInt64
    let shardCount: UInt64
    let totalReplicas: UInt64

    private enum CodingKeys: String, CodingKey {
        case version
        case database
        case timezone
        case hostName = "host_name"
        case clusterName = "cluster_name"
        case clusterNodeCount = "cluster_node_count"
        case shardCount = "shard_count"
        case totalReplicas = "total_replicas"
    }
}

protocol ClickHouseDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func execute(
        query: String,
        maximumResponseBytes: Int,
        parameters: [ClickHouseDatabaseHTTPParameter]
    ) async throws -> ClickHouseDatabaseHTTPResponse
    func disconnect() async
}

typealias ClickHouseDatabaseClientConnector =
    @Sendable (ClickHouseDatabaseConnectionPlan) async throws -> any ClickHouseDatabaseClient

final class URLSessionClickHouseDatabaseClient: ClickHouseDatabaseClient, @unchecked Sendable {
    static let maximumIdentityResponseBytes = 65_536
    static let identityQuery = """
        WITH (
            SELECT min(cluster)
            FROM system.clusters
            WHERE cluster != ''
        ) AS selected_cluster
        SELECT
            version() AS version,
            currentDatabase() AS database,
            timezone() AS timezone,
            hostName() AS host_name,
            selected_cluster AS cluster_name,
            toUInt64((
                SELECT countDistinct(tuple(host_name, port))
                FROM system.clusters
                WHERE cluster = selected_cluster
            )) AS cluster_node_count,
            toUInt64((
                SELECT countDistinct(shard_num)
                FROM system.clusters
                WHERE cluster = selected_cluster
            )) AS shard_count,
            toUInt64((
                SELECT ifNull(max(total_replicas), 0)
                FROM system.replicas
            )) AS total_replicas
        FORMAT JSONEachRow
        """

    private let lock = NSLock()
    private var transport: ClickHouseDatabaseHTTPTransport?

    init(transport: ClickHouseDatabaseHTTPTransport) {
        self.transport = transport
    }

    static func connect(
        _ plan: ClickHouseDatabaseConnectionPlan
    ) async throws -> any ClickHouseDatabaseClient {
        do {
            return try URLSessionClickHouseDatabaseClient(
                transport: ClickHouseDatabaseHTTPTransport(plan: plan))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try ClickHouseDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard let transport = lock.withLock({ transport }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        do {
            let response = try await transport.execute(
                query: Self.identityQuery,
                maximumResponseBytes: Self.maximumIdentityResponseBytes)
            let values: ClickHouseDatabaseIdentityValues
            do {
                values = try JSONDecoder().decode(
                    ClickHouseDatabaseIdentityValues.self,
                    from: response.body)
            } catch {
                throw ClickHouseDatabaseDriverFailure.decoding
            }
            return try ClickHouseDatabaseDriverSupport.identity(values)
        } catch let failure as ClickHouseDatabaseDriverFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try ClickHouseDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func execute(
        query: String,
        maximumResponseBytes: Int,
        parameters: [ClickHouseDatabaseHTTPParameter] = []
    ) async throws -> ClickHouseDatabaseHTTPResponse {
        guard let transport = lock.withLock({ transport }) else {
            throw ClickHouseDatabaseDriverFailure.connection
        }
        do {
            return try await transport.execute(
                query: query,
                maximumResponseBytes: maximumResponseBytes,
                parameters: parameters)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try ClickHouseDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func disconnect() async {
        let transport = lock.withLock {
            let transport = self.transport
            self.transport = nil
            return transport
        }
        await transport?.close()
    }
}

enum ClickHouseDatabaseDriverErrorClassifier {
    static func classify(
        _ error: Error
    ) throws(CancellationError) -> ClickHouseDatabaseDriverFailure {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if let failure = error as? ClickHouseDatabaseDriverFailure {
            return failure
        }
        if let failure = error as? ClickHouseDatabaseHTTPTransportFailure {
            return try classify(failure)
        }
        if let error = error as? URLError {
            return classify(error.code)
        }
        return .connection
    }

    static func classify(
        _ failure: ClickHouseDatabaseHTTPTransportFailure
    ) throws(CancellationError) -> ClickHouseDatabaseDriverFailure {
        switch failure {
        case .invalidConfiguration:
            return .configuration
        case .invalidResponse:
            return .connection
        case .responseTooLarge:
            return .resourceLimit(nil)
        case let .http(statusCode, exceptionCode):
            return try classify(
                statusCode: statusCode,
                exceptionCode: exceptionCode)
        }
    }

    static func classify(
        statusCode: Int,
        exceptionCode: String?
    ) throws(CancellationError) -> ClickHouseDatabaseDriverFailure {
        switch exceptionCode {
        case "192", "193", "516":
            return .authentication
        case "394":
            throw CancellationError()
        case "497":
            return .permission(exceptionCode)
        case "159":
            return .timeout
        case "158", "202", "241":
            return .resourceLimit(exceptionCode)
        default:
            break
        }
        switch statusCode {
        case 401:
            return .authentication
        case 403:
            return .permission(exceptionCode)
        case 408, 504:
            return .timeout
        case 413, 429:
            return .resourceLimit(exceptionCode)
        default:
            return .server(exceptionCode)
        }
    }

    static func classify(_ code: URLError.Code) -> ClickHouseDatabaseDriverFailure {
        switch code {
        case .timedOut:
            return .timeout
        case .secureConnectionFailed,
            .serverCertificateHasBadDate,
            .serverCertificateUntrusted,
            .serverCertificateHasUnknownRoot,
            .serverCertificateNotYetValid,
            .clientCertificateRejected,
            .clientCertificateRequired,
            .appTransportSecurityRequiresSecureConnection:
            return .tls
        default:
            return .connection
        }
    }
}

enum ClickHouseDatabaseDriverSupport {
    static func identity(
        _ values: ClickHouseDatabaseIdentityValues
    ) throws -> DatabaseProductIdentity {
        guard valid(values.version, maximumBytes: 256),
            valid(values.database, maximumBytes: 1_024),
            valid(values.timezone, maximumBytes: 256),
            valid(values.hostName, maximumBytes: 1_024),
            validOptional(values.clusterName, maximumBytes: 1_024),
            values.clusterNodeCount <= 1_000_000,
            values.shardCount <= 1_000_000,
            values.totalReplicas <= 1_000_000,
            values.shardCount <= max(1, values.clusterNodeCount),
            (values.clusterName.isEmpty && values.clusterNodeCount == 0
                && values.shardCount == 0)
                || (!values.clusterName.isEmpty && values.clusterNodeCount > 0
                    && values.shardCount > 0)
        else {
            throw ClickHouseDatabaseDriverFailure.decoding
        }
        let parsedVersion = parsedVersion(values.version)
        let knownNodeCount = max(
            1,
            Int(max(values.clusterNodeCount, values.totalReplicas)))
        let distributed = knownNodeCount > 1 || values.shardCount > 1
        let replicaCount =
            values.totalReplicas > 1
            ? Int(values.totalReplicas - 1)
            : nil
        return DatabaseProductIdentity(
            product: .clickHouse,
            version: DatabaseVersion(
                string: values.version,
                major: parsedVersion.major,
                minor: parsedVersion.minor,
                patch: parsedVersion.patch),
            distribution: "ClickHouse",
            topology: DatabaseTopology(
                kind: distributed ? .distributed : .standalone,
                name: values.clusterName.isEmpty ? nil : values.clusterName,
                localRole: values.totalReplicas > 1 ? "replica" : "node",
                nodeCount: knownNodeCount,
                replicaCount: replicaCount,
                shardCount: values.shardCount > 0 ? Int(values.shardCount) : nil,
                attributes: [
                    DatabaseStringAttribute(name: "database", value: values.database),
                    DatabaseStringAttribute(name: "hostName", value: values.hostName),
                    DatabaseStringAttribute(name: "interface", value: "http"),
                    DatabaseStringAttribute(name: "timezone", value: values.timezone),
                    DatabaseStringAttribute(
                        name: "totalReplicas",
                        value: String(values.totalReplicas)),
                ]),
            serverIdentifier: values.hostName)
    }

    static func parsedVersion(
        _ value: String
    ) -> (major: Int?, minor: Int?, patch: Int?) {
        let token = value.split(separator: " ", maxSplits: 1).first ?? ""
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        return (
            numericPrefix(components.indices.contains(0) ? components[0] : ""),
            numericPrefix(components.indices.contains(1) ? components[1] : ""),
            numericPrefix(components.indices.contains(2) ? components[2] : "")
        )
    }

    private static func numericPrefix(_ value: Substring) -> Int? {
        let digits = value.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && validOptional(value, maximumBytes: maximumBytes)
    }

    private static func validOptional(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        value.utf8.count <= maximumBytes && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }
}
