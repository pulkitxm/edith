import Foundation
import NIOCore
import PostgresNIO

enum PostgreSQLDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case connection
    case permission(String?)
    case timeout
    case server(String?)
}

enum PostgreSQLDatabaseTLSPlan: Sendable {
    case disabled
    case preferred(verifyCertificate: Bool)
    case required(verifyCertificate: Bool)
}

struct PostgreSQLDatabaseConnectionPlan: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let tls: PostgreSQLDatabaseTLSPlan
    let tlsServerName: String?
    let connectTimeoutMilliseconds: UInt64
    let statementTimeoutMilliseconds: UInt64
    let readOnly: Bool

    func configuration() throws -> PostgresConnection.Configuration {
        var configuration = PostgresConnection.Configuration(
            host: host,
            port: port,
            username: username,
            password: password,
            database: database,
            tls: try tls.configuration())
        applyOptions(to: &configuration)
        return configuration
    }

    func configuration(
        establishedChannel: any Channel
    ) throws -> PostgresConnection.Configuration {
        var configuration = PostgresConnection.Configuration(
            establishedChannel: establishedChannel,
            tls: try tls.configuration(),
            username: username,
            password: password,
            database: database)
        applyOptions(to: &configuration)
        return configuration
    }

    private func applyOptions(
        to configuration: inout PostgresConnection.Configuration
    ) {
        configuration.options.connectTimeout = .milliseconds(
            Int64(clamping: connectTimeoutMilliseconds))
        configuration.options.tlsServerName = tlsServerName
        configuration.options.additionalStartupParameters = [
            ("application_name", "Edith"),
            ("statement_timeout", String(statementTimeoutMilliseconds)),
        ]
        if readOnly {
            configuration.options.additionalStartupParameters.append(
                ("default_transaction_read_only", "on"))
        }
    }
}

struct PostgreSQLDatabaseIdentityValues: Equatable, Sendable {
    let version: String
    let versionNumber: Int64
    let database: String
    let serverEncoding: String
    let inRecovery: Bool
    let replicaCount: Int64
}

protocol PostgreSQLDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func disconnect() async
}

typealias PostgreSQLDatabaseClientConnector =
    @Sendable (PostgreSQLDatabaseConnectionPlan) async throws -> any PostgreSQLDatabaseClient

final class PostgresNIODatabaseClient: PostgreSQLDatabaseClient, @unchecked Sendable {
    private static let identityQuery = PostgresQuery(
        unsafeSQL: """
            SELECT
                current_setting('server_version')::text AS server_version,
                current_setting('server_version_num')::int8 AS server_version_number,
                current_database()::text AS database_name,
                current_setting('server_encoding')::text AS server_encoding,
                pg_is_in_recovery() AS in_recovery,
                (SELECT count(*)::int8 FROM pg_catalog.pg_stat_replication) AS replica_count
            """)

    private let lock = NSLock()
    private var resource: PostgreSQLDatabaseTransportResource?

    private init(resource: PostgreSQLDatabaseTransportResource) {
        self.resource = resource
    }

    static func connect(
        _ plan: PostgreSQLDatabaseConnectionPlan
    ) async throws -> any PostgreSQLDatabaseClient {
        do {
            let resource = try await PostgreSQLDatabaseTransport.connect(
                plan,
                connectionID: await PostgreSQLDatabaseConnectionIDGenerator.shared.take())
            return PostgresNIODatabaseClient(resource: resource)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try PostgreSQLDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard let connection = lock.withLock({ resource?.connection }) else {
            throw PostgreSQLDatabaseDriverFailure.connection
        }
        do {
            let sequence = try await connection.query(
                Self.identityQuery,
                logger: Logger(label: "com.edith.database.postgresql.identity"))
            var iterator = sequence.makeAsyncIterator()
            guard let row = try await iterator.next(), try await iterator.next() == nil else {
                throw PostgreSQLDatabaseDriverFailure.server(nil)
            }
            let values = try PostgreSQLDatabaseDriverSupport.identityValues(row)
            return try PostgreSQLDatabaseDriverSupport.identity(values)
        } catch let failure as PostgreSQLDatabaseDriverFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try PostgreSQLDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func disconnect() async {
        let resource = lock.withLock {
            let resource = self.resource
            self.resource = nil
            return resource
        }
        try? await resource?.connection.close()
        try? await resource?.eventLoopGroup.shutdownGracefully()
    }
}

enum PostgreSQLDatabaseDriverErrorClassifier {
    static func classify(
        _ error: Error
    ) throws(CancellationError) -> PostgreSQLDatabaseDriverFailure {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if isConnectTimeout(error) {
            return .timeout
        }
        guard let error = error as? PSQLError else {
            return .connection
        }
        if isConnectTimeout(error.underlying) {
            return .timeout
        }
        return classify(
            code: error.code,
            sqlState: error.serverInfo?[.sqlState])
    }

    static func classify(
        code: PSQLError.Code,
        sqlState: String?
    ) -> PostgreSQLDatabaseDriverFailure {
        if code == .authMechanismRequiresPassword || code == .saslError
            || sqlState == "28000" || sqlState == "28P01"
        {
            return .authentication
        }
        if sqlState == "42501" {
            return .permission(sqlState)
        }
        if code == .queryCancelled || sqlState == "57014" {
            return .timeout
        }
        if code == .connectionError || code == .clientClosedConnection
            || code == .serverClosedConnection || sqlState?.hasPrefix("08") == true
        {
            return .connection
        }
        if code == .server {
            return .server(PostgreSQLDatabaseDriverSupport.safeSQLState(sqlState))
        }
        return .connection
    }

    private static func isConnectTimeout(_ error: Error?) -> Bool {
        guard let channelError = error as? ChannelError else { return false }
        if case .connectTimeout = channelError {
            return true
        }
        return false
    }
}

enum PostgreSQLDatabaseDriverSupport {
    static func identityValues(
        _ row: PostgresRow
    ) throws -> PostgreSQLDatabaseIdentityValues {
        guard row.count == 6 else {
            throw PostgreSQLDatabaseDriverFailure.server(nil)
        }
        var cells: [String: PostgresCell] = [:]
        cells.reserveCapacity(row.count)
        for cell in row {
            guard cells[cell.columnName] == nil else {
                throw PostgreSQLDatabaseDriverFailure.server(nil)
            }
            cells[cell.columnName] = cell
        }
        guard let version = cells["server_version"],
            let versionNumber = cells["server_version_number"],
            let database = cells["database_name"],
            let serverEncoding = cells["server_encoding"],
            let inRecovery = cells["in_recovery"],
            let replicaCount = cells["replica_count"]
        else {
            throw PostgreSQLDatabaseDriverFailure.server(nil)
        }
        do {
            return PostgreSQLDatabaseIdentityValues(
                version: try version.decode(String.self),
                versionNumber: try versionNumber.decode(Int64.self),
                database: try database.decode(String.self),
                serverEncoding: try serverEncoding.decode(String.self),
                inRecovery: try inRecovery.decode(Bool.self),
                replicaCount: try replicaCount.decode(Int64.self))
        } catch {
            throw PostgreSQLDatabaseDriverFailure.server(nil)
        }
    }

    static func identity(
        _ values: PostgreSQLDatabaseIdentityValues
    ) throws -> DatabaseProductIdentity {
        guard valid(values.version, maximumBytes: 256),
            values.versionNumber > 0,
            valid(values.database, maximumBytes: 1_024),
            valid(values.serverEncoding, maximumBytes: 128),
            values.replicaCount >= 0,
            values.replicaCount <= 1_000_000
        else {
            throw PostgreSQLDatabaseDriverFailure.server(nil)
        }
        let version = parsedVersion(values.version)
        let replicated = values.inRecovery || values.replicaCount > 0
        let knownNodeCount: Int?
        if values.inRecovery {
            knownNodeCount = nil
        } else {
            knownNodeCount = Int(values.replicaCount) + 1
        }
        return DatabaseProductIdentity(
            product: .postgresql,
            version: DatabaseVersion(
                string: values.version,
                major: version.major,
                minor: version.minor,
                patch: version.patch),
            distribution: "PostgreSQL",
            topology: DatabaseTopology(
                kind: replicated ? .primaryReplica : .standalone,
                localRole: values.inRecovery ? "standby" : "primary",
                nodeCount: knownNodeCount,
                replicaCount: replicated && !values.inRecovery ? Int(values.replicaCount) : nil,
                attributes: [
                    DatabaseStringAttribute(name: "database", value: values.database),
                    DatabaseStringAttribute(
                        name: "serverEncoding",
                        value: values.serverEncoding),
                    DatabaseStringAttribute(
                        name: "serverVersionNumber",
                        value: String(values.versionNumber)),
                ]))
    }

    static func safeSQLState(_ value: String?) -> String? {
        guard let value, value.utf8.count == 5,
            value.utf8.allSatisfy({ byte in
                (48...57).contains(byte) || (65...90).contains(byte)
            })
        else {
            return nil
        }
        return value
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

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
    }
}

extension PostgreSQLDatabaseTLSPlan {
    func configuration() throws -> PostgresConnection.Configuration.TLS {
        switch self {
        case .disabled:
            return .disable
        case let .preferred(verifyCertificate):
            return .prefer(try context(verifyCertificate: verifyCertificate))
        case let .required(verifyCertificate):
            return .require(try context(verifyCertificate: verifyCertificate))
        }
    }

    func context(verifyCertificate: Bool) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = verifyCertificate ? .fullVerification : .none
        return try NIOSSLContext(configuration: configuration)
    }
}

private actor PostgreSQLDatabaseConnectionIDGenerator {
    static let shared = PostgreSQLDatabaseConnectionIDGenerator()
    private var nextValue = 1

    func take() -> Int {
        let value = nextValue
        nextValue = nextValue == Int.max ? 1 : nextValue + 1
        return value
    }
}
