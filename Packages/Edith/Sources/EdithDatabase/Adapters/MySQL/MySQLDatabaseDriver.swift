import Foundation
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

enum MySQLDatabaseDriverFailure: Error, Equatable, Sendable {
    case authentication
    case configuration
    case connection
    case incompatibleProduct(DatabaseProduct)
    case permission(String?)
    case resourceLimit
    case server(String?)
    case timeout
    case tls
}

enum MySQLDatabaseTLSPlan: Sendable {
    case disabled
    case preferred(verifyCertificate: Bool)
    case required(verifyCertificate: Bool)
}

struct MySQLDatabaseConnectionPlan: Sendable {
    let host: String
    let port: Int
    let username: String
    let password: String?
    let database: String?
    let tls: MySQLDatabaseTLSPlan
    let tlsServerName: String?
    let connectTimeoutMilliseconds: UInt64

    func validate() throws {
        guard (1...65_535).contains(port),
            connectTimeoutMilliseconds > 0,
            connectTimeoutMilliseconds <= 86_400_000,
            Self.valid(host, maximumBytes: 1_024, allowWhitespace: false),
            Self.valid(username, maximumBytes: 1_024, allowWhitespace: true),
            password.map({ Self.valid($0, maximumBytes: 1_048_576, allowWhitespace: true) })
                ?? true,
            database.map({ Self.valid($0, maximumBytes: 1_024, allowWhitespace: true) })
                ?? true,
            tlsServerName.map({ Self.valid($0, maximumBytes: 1_024, allowWhitespace: false) })
                ?? true
        else {
            throw MySQLDatabaseDriverFailure.configuration
        }
        if case .disabled = tls, tlsServerName != nil {
            throw MySQLDatabaseDriverFailure.configuration
        }
    }

    var effectiveTLSServerName: String? {
        guard tls.isEnabled else { return nil }
        if let tlsServerName {
            return tlsServerName
        }
        guard !hostIsIPAddress else { return nil }
        return host
    }

    private var hostIsIPAddress: Bool {
        let candidate: String
        if host.hasPrefix("["), host.hasSuffix("]") {
            candidate = String(host.dropFirst().dropLast())
        } else {
            candidate = host
        }
        return (try? SocketAddress(ipAddress: candidate, port: port)) != nil
    }

    private static func valid(
        _ value: String,
        maximumBytes: Int,
        allowWhitespace: Bool
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
                    || (!allowWhitespace && CharacterSet.whitespacesAndNewlines.contains($0))
            })
    }
}

struct MySQLDatabaseIdentityValues: Equatable, Sendable {
    let version: String
    let versionComment: String
    let database: String?
    let hostName: String
    let serverUUID: String
    let readOnly: Bool
    let superReadOnly: Bool
    let defaultStorageEngine: String
    let characterSet: String
    let collation: String
    let compileMachine: String
    let compileOS: String
    let tlsCipher: String
    let groupMemberCount: UInt64
    let localMemberRole: String
    let groupReplicaCount: UInt64
    let replicaChannelCount: UInt64
}

protocol MySQLDatabaseClient: Sendable {
    func discoverIdentity() async throws -> DatabaseProductIdentity
    func disconnect() async
}

typealias MySQLDatabaseClientConnector =
    @Sendable (MySQLDatabaseConnectionPlan) async throws -> any MySQLDatabaseClient

final class MySQLNIODatabaseClient: MySQLDatabaseClient, @unchecked Sendable {
    static let maximumDetectionResponseBytes = 16_384
    static let maximumIdentityResponseBytes = 65_536

    private static let detectionQuery =
        "SELECT @@version AS server_version, @@version_comment AS version_comment"
    private static let identityQuery = """
        SELECT
            @@version AS server_version,
            @@version_comment AS version_comment,
            DATABASE() AS database_name,
            @@hostname AS host_name,
            @@server_uuid AS server_uuid,
            @@read_only AS read_only,
            @@super_read_only AS super_read_only,
            @@default_storage_engine AS default_storage_engine,
            @@character_set_server AS character_set_server,
            @@collation_server AS collation_server,
            @@version_compile_machine AS compile_machine,
            @@version_compile_os AS compile_os,
            COALESCE((
                SELECT VARIABLE_VALUE
                FROM performance_schema.session_status
                WHERE VARIABLE_NAME = 'Ssl_cipher'
                LIMIT 1
            ), '') AS ssl_cipher,
            (
                SELECT COUNT(*)
                FROM performance_schema.replication_group_members
                WHERE MEMBER_STATE <> 'OFFLINE'
            ) AS group_member_count,
            COALESCE((
                SELECT MEMBER_ROLE
                FROM performance_schema.replication_group_members
                WHERE MEMBER_ID = @@server_uuid
                LIMIT 1
            ), '') AS local_member_role,
            (
                SELECT COUNT(*)
                FROM performance_schema.replication_group_members
                WHERE MEMBER_STATE <> 'OFFLINE' AND MEMBER_ROLE <> 'PRIMARY'
            ) AS group_replica_count,
            (
                SELECT COUNT(*)
                FROM performance_schema.replication_connection_status
                WHERE SERVICE_STATE = 'ON'
            ) AS replica_channel_count
        """

    private let lock = NSLock()
    private var resource: MySQLDatabaseResource?

    private init(resource: MySQLDatabaseResource) {
        self.resource = resource
    }

    static func connect(
        _ plan: MySQLDatabaseConnectionPlan
    ) async throws -> any MySQLDatabaseClient {
        do {
            try plan.validate()
            let resource = try await MySQLDatabaseTransport.connect(plan)
            return MySQLNIODatabaseClient(resource: resource)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try MySQLDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func discoverIdentity() async throws -> DatabaseProductIdentity {
        guard let resource = lock.withLock({ resource }) else {
            throw MySQLDatabaseDriverFailure.connection
        }
        do {
            let detectionRows = try await boundedQuery(
                Self.detectionQuery,
                maximumResponseBytes: Self.maximumDetectionResponseBytes,
                resource: resource)
            let detection = try MySQLDatabaseDriverSupport.detection(detectionRows)
            try MySQLDatabaseDriverSupport.requireMySQL(detection)
            let identityRows = try await boundedQuery(
                Self.identityQuery,
                maximumResponseBytes: Self.maximumIdentityResponseBytes,
                resource: resource)
            let values = try MySQLDatabaseDriverSupport.identityValues(identityRows)
            let identity = try MySQLDatabaseDriverSupport.identity(values)
            if resource.plan.tls.requiresEncryption && values.tlsCipher.isEmpty {
                throw MySQLDatabaseDriverFailure.tls
            }
            return identity
        } catch let failure as MySQLDatabaseDriverFailure {
            throw failure
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw try MySQLDatabaseDriverErrorClassifier.classify(error)
        }
    }

    func disconnect() async {
        let resource = lock.withLock {
            let resource = self.resource
            self.resource = nil
            return resource
        }
        guard let resource else { return }
        try? await resource.connection.close().get()
        try? await resource.eventLoopGroup.shutdownGracefully()
    }

    private func boundedQuery(
        _ query: String,
        maximumResponseBytes: Int,
        resource: MySQLDatabaseResource
    ) async throws -> [MySQLRow] {
        guard resource.responseGuard.begin(maximumBytes: maximumResponseBytes) else {
            throw MySQLDatabaseDriverFailure.connection
        }
        defer {
            resource.responseGuard.end()
        }
        do {
            return try await resource.connection.simpleQuery(query).get()
        } catch {
            if resource.responseGuard.exceededLimit {
                throw MySQLDatabaseDriverFailure.resourceLimit
            }
            throw error
        }
    }
}

struct MySQLDatabaseResource: @unchecked Sendable {
    let connection: MySQLConnection
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let responseGuard: MySQLDatabaseInboundResponseGuard
    let plan: MySQLDatabaseConnectionPlan
}

enum MySQLDatabaseTransport {
    static func connect(
        _ plan: MySQLDatabaseConnectionPlan
    ) async throws -> MySQLDatabaseResource {
        let eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let eventLoop = eventLoopGroup.next()
        let race = MySQLDatabaseConnectionRace()
        let promise = eventLoop.makePromise(of: MySQLConnection.self)
        let timeout = eventLoop.scheduleTask(
            in: .milliseconds(Int64(clamping: plan.connectTimeoutMilliseconds))
        ) {
            if race.claim() {
                promise.fail(MySQLDatabaseDriverFailure.timeout)
            }
        }
        do {
            let address = try SocketAddress.makeAddressResolvingHost(
                plan.host,
                port: plan.port)
            let connectionFuture = MySQLConnection.connect(
                to: address,
                username: plan.username,
                database: plan.database ?? "",
                password: plan.password,
                tlsConfiguration: plan.tls.configuration(),
                serverHostname: plan.effectiveTLSServerName,
                on: eventLoop)
            connectionFuture.whenComplete { result in
                if race.claim() {
                    promise.completeWith(result)
                } else if case let .success(connection) = result {
                    connection.close().whenFailure { _ in }
                }
            }
            let connection = try await withTaskCancellationHandler {
                try await promise.futureResult.get()
            } onCancel: {
                if race.claim() {
                    promise.fail(CancellationError())
                }
            }
            timeout.cancel()
            let responseGuard = MySQLDatabaseInboundResponseGuard()
            try await connection.channel.pipeline.addHandler(
                responseGuard,
                position: .first
            ).get()
            return MySQLDatabaseResource(
                connection: connection,
                eventLoopGroup: eventLoopGroup,
                responseGuard: responseGuard,
                plan: plan)
        } catch {
            timeout.cancel()
            try? await eventLoopGroup.shutdownGracefully()
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }
}

private final class MySQLDatabaseConnectionRace: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func claim() -> Bool {
        lock.withLock {
            guard !completed else { return false }
            completed = true
            return true
        }
    }
}

final class MySQLDatabaseInboundResponseGuard: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var active = false
    private var maximumBytes = 0
    private var receivedBytes = 0
    private var limitExceeded = false

    var exceededLimit: Bool {
        lock.withLock { limitExceeded }
    }

    func begin(maximumBytes: Int) -> Bool {
        lock.withLock {
            guard !active, maximumBytes > 0 else { return false }
            active = true
            self.maximumBytes = maximumBytes
            receivedBytes = 0
            limitExceeded = false
            return true
        }
    }

    func end() {
        lock.withLock {
            active = false
            maximumBytes = 0
            receivedBytes = 0
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        let shouldClose = lock.withLock {
            guard active else { return false }
            let next = receivedBytes.addingReportingOverflow(buffer.readableBytes)
            guard !next.overflow, next.partialValue <= maximumBytes else {
                limitExceeded = true
                return true
            }
            receivedBytes = next.partialValue
            return false
        }
        if shouldClose {
            context.close(mode: .all, promise: nil)
        } else {
            context.fireChannelRead(data)
        }
    }
}

enum MySQLDatabaseDriverErrorClassifier {
    static func classify(
        _ error: Error
    ) throws(CancellationError) -> MySQLDatabaseDriverFailure {
        if error is CancellationError || Task.isCancelled {
            throw CancellationError()
        }
        if let failure = error as? MySQLDatabaseDriverFailure {
            return failure
        }
        if let channelError = error as? ChannelError,
            case .connectTimeout = channelError
        {
            return .timeout
        }
        if error is NIOSSLError {
            return .tls
        }
        guard let error = error as? MySQLError else {
            return .connection
        }
        switch error {
        case .secureConnectionRequired:
            return .tls
        case .unsupportedAuthPlugin, .authPluginDataError,
            .missingOrInvalidAuthMoreDataStatusTag,
            .missingOrInvalidAuthPluginInlineCommand,
            .missingAuthPluginInlineData:
            return .authentication
        case .unsupportedServer, .protocolError:
            return .server(nil)
        case .closed:
            return .connection
        case let .server(packet):
            return classify(
                code: packet.errorCode.rawValue,
                sqlState: packet.sqlState)
        case .duplicateEntry, .invalidSyntax:
            return .server(nil)
        }
    }

    static func classify(
        code: UInt16,
        sqlState: String?
    ) -> MySQLDatabaseDriverFailure {
        if [1045, 1251, 1698, 1873, 2049, 2059, 2061].contains(code) {
            return .authentication
        }
        if [1044, 1095, 1142, 1143, 1227, 1370].contains(code) {
            return .permission(safeCode(code, sqlState: sqlState))
        }
        if code == 1317 {
            return .timeout
        }
        if [1040, 1041, 1203].contains(code) {
            return .resourceLimit
        }
        if [
            1042, 1043, 1053, 1080, 1129, 1130, 1152, 1184, 2002, 2003, 2005, 2006,
            2010, 2011, 2012, 2013, 2015, 2021, 2055,
        ].contains(code) {
            return .connection
        }
        if code == 2026 {
            return .tls
        }
        return .server(safeCode(code, sqlState: sqlState))
    }

    private static func safeCode(
        _ code: UInt16,
        sqlState: String?
    ) -> String {
        if let sqlState = MySQLDatabaseDriverSupport.safeSQLState(sqlState) {
            return String(code) + "." + sqlState
        }
        return String(code)
    }
}

enum MySQLDatabaseDriverSupport {
    static func detection(
        _ rows: [MySQLRow]
    ) throws -> (version: String, versionComment: String) {
        let row = try singleRow(rows, expectedColumns: ["server_version", "version_comment"])
        return (
            try requiredString(row, name: "server_version"),
            try requiredString(row, name: "version_comment")
        )
    }

    static func requireMySQL(
        _ detection: (version: String, versionComment: String)
    ) throws {
        guard valid(detection.version, maximumBytes: 256),
            valid(detection.versionComment, maximumBytes: 1_024)
        else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        let signature = (detection.version + " " + detection.versionComment).lowercased()
        if signature.contains("mariadb") {
            throw MySQLDatabaseDriverFailure.incompatibleProduct(.mariaDB)
        }
        let version = parsedVersion(detection.version)
        guard version.major != nil, version.minor != nil, version.patch != nil else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
    }

    static func identityValues(
        _ rows: [MySQLRow]
    ) throws -> MySQLDatabaseIdentityValues {
        let expected = [
            "server_version", "version_comment", "database_name", "host_name", "server_uuid",
            "read_only", "super_read_only", "default_storage_engine", "character_set_server",
            "collation_server", "compile_machine", "compile_os", "ssl_cipher",
            "group_member_count", "local_member_role", "group_replica_count",
            "replica_channel_count",
        ]
        let row = try singleRow(rows, expectedColumns: expected)
        let values = MySQLDatabaseIdentityValues(
            version: try requiredString(row, name: "server_version"),
            versionComment: try requiredString(row, name: "version_comment"),
            database: try optionalString(row, name: "database_name"),
            hostName: try requiredString(row, name: "host_name"),
            serverUUID: try requiredString(row, name: "server_uuid"),
            readOnly: try boolean(row, name: "read_only"),
            superReadOnly: try boolean(row, name: "super_read_only"),
            defaultStorageEngine: try requiredString(row, name: "default_storage_engine"),
            characterSet: try requiredString(row, name: "character_set_server"),
            collation: try requiredString(row, name: "collation_server"),
            compileMachine: try requiredString(row, name: "compile_machine"),
            compileOS: try requiredString(row, name: "compile_os"),
            tlsCipher: try requiredString(row, name: "ssl_cipher", allowEmpty: true),
            groupMemberCount: try unsignedInteger(row, name: "group_member_count"),
            localMemberRole: try requiredString(row, name: "local_member_role", allowEmpty: true),
            groupReplicaCount: try unsignedInteger(row, name: "group_replica_count"),
            replicaChannelCount: try unsignedInteger(row, name: "replica_channel_count"))
        try requireMySQL((values.version, values.versionComment))
        return values
    }

    static func identity(
        _ values: MySQLDatabaseIdentityValues
    ) throws -> DatabaseProductIdentity {
        guard valid(values.version, maximumBytes: 256),
            valid(values.versionComment, maximumBytes: 1_024),
            validOptional(values.database, maximumBytes: 1_024),
            valid(values.hostName, maximumBytes: 1_024),
            valid(values.serverUUID, maximumBytes: 128),
            valid(values.defaultStorageEngine, maximumBytes: 128),
            valid(values.characterSet, maximumBytes: 128),
            valid(values.collation, maximumBytes: 256),
            valid(values.compileMachine, maximumBytes: 128),
            valid(values.compileOS, maximumBytes: 256),
            validOptional(values.tlsCipher.isEmpty ? nil : values.tlsCipher, maximumBytes: 256),
            validOptional(
                values.localMemberRole.isEmpty ? nil : values.localMemberRole,
                maximumBytes: 128),
            values.groupMemberCount <= 1_000_000,
            values.groupReplicaCount <= values.groupMemberCount,
            values.replicaChannelCount <= 1_000_000,
            values.groupMemberCount > 0 || values.localMemberRole.isEmpty
        else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        try requireMySQL((values.version, values.versionComment))
        let parsed = parsedVersion(values.version)
        let topology: DatabaseTopology
        if values.groupMemberCount > 0 {
            topology = DatabaseTopology(
                kind: .cluster,
                localRole: values.localMemberRole.lowercased(),
                nodeCount: Int(values.groupMemberCount),
                replicaCount: Int(values.groupReplicaCount),
                attributes: attributes(values))
        } else if values.replicaChannelCount > 0 {
            topology = DatabaseTopology(
                kind: .primaryReplica,
                localRole: "replica",
                nodeCount: nil,
                replicaCount: nil,
                attributes: attributes(values))
        } else {
            topology = DatabaseTopology(
                kind: .standalone,
                localRole: "primary",
                nodeCount: 1,
                attributes: attributes(values))
        }
        return DatabaseProductIdentity(
            product: .mysql,
            version: DatabaseVersion(
                string: values.version,
                major: parsed.major,
                minor: parsed.minor,
                patch: parsed.patch),
            distribution: "MySQL",
            topology: topology,
            serverIdentifier: values.serverUUID)
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
        let token = value.split(separator: "-", maxSplits: 1).first ?? ""
        let components = token.split(separator: ".", omittingEmptySubsequences: false)
        return (
            numericPrefix(components.indices.contains(0) ? components[0] : ""),
            numericPrefix(components.indices.contains(1) ? components[1] : ""),
            numericPrefix(components.indices.contains(2) ? components[2] : "")
        )
    }

    private static func singleRow(
        _ rows: [MySQLRow],
        expectedColumns: [String]
    ) throws -> MySQLRow {
        guard rows.count == 1, let row = rows.first,
            row.columnDefinitions.count == expectedColumns.count,
            row.values.count == expectedColumns.count,
            row.columnDefinitions.map(\.name) == expectedColumns,
            Set(expectedColumns).count == expectedColumns.count
        else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        return row
    }

    private static func requiredString(
        _ row: MySQLRow,
        name: String,
        allowEmpty: Bool = false
    ) throws -> String {
        guard let value = row.column(name)?.string,
            (allowEmpty || !value.isEmpty)
        else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        return value
    }

    private static func optionalString(
        _ row: MySQLRow,
        name: String
    ) throws -> String? {
        guard let data = row.column(name) else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        guard data.buffer != nil else { return nil }
        guard let value = data.string, !value.isEmpty else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        return value
    }

    private static func boolean(
        _ row: MySQLRow,
        name: String
    ) throws -> Bool {
        switch try requiredString(row, name: name) {
        case "0":
            return false
        case "1":
            return true
        default:
            throw MySQLDatabaseDriverFailure.server(nil)
        }
    }

    private static func unsignedInteger(
        _ row: MySQLRow,
        name: String
    ) throws -> UInt64 {
        guard let value = UInt64(try requiredString(row, name: name)) else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        return value
    }

    private static func attributes(
        _ values: MySQLDatabaseIdentityValues
    ) -> [DatabaseStringAttribute] {
        var attributes = [
            DatabaseStringAttribute(name: "characterSet", value: values.characterSet),
            DatabaseStringAttribute(name: "collation", value: values.collation),
            DatabaseStringAttribute(name: "compileMachine", value: values.compileMachine),
            DatabaseStringAttribute(name: "compileOS", value: values.compileOS),
            DatabaseStringAttribute(
                name: "defaultStorageEngine",
                value: values.defaultStorageEngine),
            DatabaseStringAttribute(name: "hostName", value: values.hostName),
            DatabaseStringAttribute(name: "protocolVersion", value: "4.1"),
            DatabaseStringAttribute(name: "readOnly", value: String(values.readOnly)),
            DatabaseStringAttribute(
                name: "replicaChannelCount",
                value: String(values.replicaChannelCount)),
            DatabaseStringAttribute(name: "superReadOnly", value: String(values.superReadOnly)),
            DatabaseStringAttribute(
                name: "tlsCipher",
                value: values.tlsCipher.isEmpty ? "none" : values.tlsCipher),
            DatabaseStringAttribute(name: "versionComment", value: values.versionComment),
        ]
        if let database = values.database {
            attributes.append(DatabaseStringAttribute(name: "database", value: database))
        }
        return attributes.sorted { $0.name < $1.name }
    }

    private static func numericPrefix(_ value: Substring) -> Int? {
        let digits = value.prefix(while: { $0.isNumber })
        guard !digits.isEmpty else { return nil }
        return Int(digits)
    }

    private static func valid(_ value: String, maximumBytes: Int) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes && !value.contains("\0")
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }
            )
    }

    private static func validOptional(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map { valid($0, maximumBytes: maximumBytes) } ?? true
    }
}

extension MySQLDatabaseTLSPlan {
    var isEnabled: Bool {
        switch self {
        case .disabled:
            return false
        case .preferred, .required:
            return true
        }
    }

    var requiresEncryption: Bool {
        if case .required = self {
            return true
        }
        return false
    }

    func configuration() -> TLSConfiguration? {
        switch self {
        case .disabled:
            return nil
        case let .preferred(verifyCertificate), let .required(verifyCertificate):
            var configuration = TLSConfiguration.makeClientConfiguration()
            configuration.certificateVerification =
                verifyCertificate ? .fullVerification : .none
            configuration.minimumTLSVersion = .tlsv12
            return configuration
        }
    }
}
