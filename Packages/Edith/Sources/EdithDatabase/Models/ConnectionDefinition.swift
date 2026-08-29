import Foundation

public struct DatabaseConnectionID: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init() {
        rawValue = UUID()
    }
}

public enum DatabaseEnvironmentKind: String, CaseIterable, Codable, Hashable, Sendable {
    case local
    case development
    case testing
    case staging
    case production
    case other
}

public enum DatabaseEnvironmentProtection: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case confirmationRequired
    case readOnly
}

public struct DatabaseEnvironmentMetadata: Codable, Hashable, Sendable {
    public let kind: DatabaseEnvironmentKind
    public let label: String
    public let protection: DatabaseEnvironmentProtection

    public init(
        kind: DatabaseEnvironmentKind,
        label: String,
        protection: DatabaseEnvironmentProtection
    ) {
        self.kind = kind
        self.label = label
        self.protection = protection
    }
}

public enum DatabaseBoundedValueError: Error, Equatable, Sendable {
    case port(Int)
    case timeoutMilliseconds(UInt64)
    case poolSize(Int)
}

public struct DatabasePort: Codable, Hashable, Sendable {
    public static let range = 1...65_535
    public let value: Int

    public init(_ value: Int) throws {
        guard Self.range.contains(value) else { throw DatabaseBoundedValueError.port(value) }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Database port must be between 1 and 65535.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct DatabaseTimeout: Codable, Hashable, Sendable {
    public static let range: ClosedRange<UInt64> = 100...86_400_000
    public let milliseconds: UInt64

    public init(milliseconds: UInt64) throws {
        guard Self.range.contains(milliseconds) else {
            throw DatabaseBoundedValueError.timeoutMilliseconds(milliseconds)
        }
        self.milliseconds = milliseconds
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(UInt64.self)
        do {
            try self.init(milliseconds: value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Database timeout must be between 100 and 86400000 milliseconds.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(milliseconds)
    }
}

public struct DatabasePoolSize: Codable, Hashable, Sendable {
    public static let range = 1...256
    public let value: Int

    public init(_ value: Int) throws {
        guard Self.range.contains(value) else {
            throw DatabaseBoundedValueError.poolSize(value)
        }
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(Int.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: try decoder.singleValueContainer(),
                debugDescription: "Database pool size must be between 1 and 256.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum DatabaseEndpointRole: String, CaseIterable, Codable, Hashable, Sendable {
    case primary
    case readReplica
    case seed
    case router
    case sentinel
    case node
}

public struct DatabaseNetworkEndpoint: Codable, Hashable, Sendable {
    public let host: String
    public let port: DatabasePort
    public let role: DatabaseEndpointRole

    public init(host: String, port: DatabasePort, role: DatabaseEndpointRole = .primary) {
        self.host = host
        self.port = port
        self.role = role
    }
}

public enum DatabaseSQLiteAccessMode: String, CaseIterable, Codable, Hashable, Sendable {
    case readOnly
    case readWrite
    case createIfMissing
}

public struct DatabaseSQLiteLocation: Codable, Hashable, Sendable {
    public let path: String
    public let accessMode: DatabaseSQLiteAccessMode
    public let fileReference: DatabaseResourceReference?

    public init(
        path: String,
        accessMode: DatabaseSQLiteAccessMode = .readWrite,
        fileReference: DatabaseResourceReference? = nil
    ) {
        self.path = path
        self.accessMode = accessMode
        self.fileReference = fileReference
    }
}

public enum DatabaseConnectionLocation: Codable, Hashable, Sendable {
    case network([DatabaseNetworkEndpoint])
    case sqlite(DatabaseSQLiteLocation)
    case memory(name: String?)

    private enum CodingKeys: String, CodingKey {
        case kind
        case endpoints
        case sqlite
        case name
    }

    private enum Kind: String, Codable {
        case network
        case sqlite
        case memory
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .network:
            self = .network(
                try container.decode([DatabaseNetworkEndpoint].self, forKey: .endpoints))
        case .sqlite:
            self = .sqlite(try container.decode(DatabaseSQLiteLocation.self, forKey: .sqlite))
        case .memory:
            self = .memory(name: try container.decodeIfPresent(String.self, forKey: .name))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .network(endpoints):
            try container.encode(Kind.network, forKey: .kind)
            try container.encode(endpoints, forKey: .endpoints)
        case let .sqlite(location):
            try container.encode(Kind.sqlite, forKey: .kind)
            try container.encode(location, forKey: .sqlite)
        case let .memory(name):
            try container.encode(Kind.memory, forKey: .kind)
            try container.encodeIfPresent(name, forKey: .name)
        }
    }
}

public enum DatabaseDeploymentMode: String, CaseIterable, Codable, Hashable, Sendable {
    case automatic
    case embedded
    case standalone
    case primaryReplica
    case sentinel
    case cluster
    case replicaSet
    case shardedCluster
    case distributed
}

public struct DatabaseNamespaceDefaults: Codable, Hashable, Sendable {
    public let catalog: String?
    public let schema: String?
    public let database: String?
    public let logicalDatabase: String?

    public init(
        catalog: String? = nil,
        schema: String? = nil,
        database: String? = nil,
        logicalDatabase: String? = nil
    ) {
        self.catalog = catalog
        self.schema = schema
        self.database = database
        self.logicalDatabase = logicalDatabase
    }
}

public enum DatabaseAuthenticationKind: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case password
    case usernameAndPassword
    case token
    case apiKey
    case scram
    case x509
    case cloudIdentity
}

public enum DatabaseSecretPurpose: String, CaseIterable, Codable, Hashable, Sendable {
    case password
    case token
    case apiKeyIdentifier
    case apiKeySecret
    case clientPrivateKey
    case passphrase
    case confirmationSigningKey
}

public struct DatabaseSecretReference: Codable, Hashable, Sendable {
    public let identifier: UUID
    public let purpose: DatabaseSecretPurpose

    public init(identifier: UUID, purpose: DatabaseSecretPurpose) {
        self.identifier = identifier
        self.purpose = purpose
    }
}

public struct DatabaseAuthentication: Codable, Hashable, Sendable {
    public let kind: DatabaseAuthenticationKind
    public let secretReferences: [DatabaseSecretReference]
    public let source: String?

    public init(
        kind: DatabaseAuthenticationKind,
        secretReferences: [DatabaseSecretReference] = [],
        source: String? = nil
    ) {
        self.kind = kind
        self.secretReferences = secretReferences
        self.source = source
    }
}

public enum DatabaseResourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case certificateAuthority
    case clientCertificate
    case sqliteBookmark
}

public struct DatabaseResourceReference: Codable, Hashable, Sendable {
    public let identifier: UUID
    public let kind: DatabaseResourceKind

    public init(identifier: UUID, kind: DatabaseResourceKind) {
        self.identifier = identifier
        self.kind = kind
    }
}

public enum DatabaseTLSMode: String, CaseIterable, Codable, Hashable, Sendable {
    case disabled
    case preferred
    case required
}

public enum DatabaseTLSVerification: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case certificateAuthority
    case full
}

public struct DatabaseTLSConfiguration: Codable, Hashable, Sendable {
    public let mode: DatabaseTLSMode
    public let verification: DatabaseTLSVerification
    public let serverName: String?
    public let certificateAuthority: DatabaseResourceReference?
    public let clientCertificate: DatabaseResourceReference?
    public let clientPrivateKey: DatabaseSecretReference?

    public init(
        mode: DatabaseTLSMode,
        verification: DatabaseTLSVerification,
        serverName: String? = nil,
        certificateAuthority: DatabaseResourceReference? = nil,
        clientCertificate: DatabaseResourceReference? = nil,
        clientPrivateKey: DatabaseSecretReference? = nil
    ) {
        self.mode = mode
        self.verification = verification
        self.serverName = serverName
        self.certificateAuthority = certificateAuthority
        self.clientCertificate = clientCertificate
        self.clientPrivateKey = clientPrivateKey
    }
}

public struct DatabaseTunnelDefinition: Codable, Hashable, Sendable {
    public let machineIdentifier: String
    public let remoteEndpoint: DatabaseNetworkEndpoint
    public let localBindAddress: String
    public let requestedLocalPort: DatabasePort?
    public let managesLifecycle: Bool

    public init(
        machineIdentifier: String,
        remoteEndpoint: DatabaseNetworkEndpoint,
        localBindAddress: String = "127.0.0.1",
        requestedLocalPort: DatabasePort? = nil,
        managesLifecycle: Bool = true
    ) {
        self.machineIdentifier = machineIdentifier
        self.remoteEndpoint = remoteEndpoint
        self.localBindAddress = localBindAddress
        self.requestedLocalPort = requestedLocalPort
        self.managesLifecycle = managesLifecycle
    }
}

public struct DatabaseConnectionLimits: Codable, Hashable, Sendable {
    public let connectionTimeout: DatabaseTimeout
    public let operationTimeout: DatabaseTimeout
    public let poolSize: DatabasePoolSize
    public let idleTimeout: DatabaseTimeout?
    public let keepaliveInterval: DatabaseTimeout?

    public init(
        connectionTimeout: DatabaseTimeout,
        operationTimeout: DatabaseTimeout,
        poolSize: DatabasePoolSize,
        idleTimeout: DatabaseTimeout? = nil,
        keepaliveInterval: DatabaseTimeout? = nil
    ) {
        self.connectionTimeout = connectionTimeout
        self.operationTimeout = operationTimeout
        self.poolSize = poolSize
        self.idleTimeout = idleTimeout
        self.keepaliveInterval = keepaliveInterval
    }
}

public enum DatabaseReadOnlyPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case disabled
    case preferred
    case required
}

public enum DatabaseProductionPolicy: String, CaseIterable, Codable, Hashable, Sendable {
    case standard
    case requireMutationPreview
    case prohibitMutations
}

public enum DatabaseNonSecretOptionValue: Codable, Hashable, Sendable {
    case boolean(Bool)
    case integer(Int64)
    case string(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case boolean
        case integer
        case string
    }

    private enum Kind: String, Codable {
        case boolean
        case integer
        case string
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .integer:
            self = .integer(try container.decode(Int64.self, forKey: .integer))
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .boolean)
        case let .integer(value):
            try container.encode(Kind.integer, forKey: .kind)
            try container.encode(value, forKey: .integer)
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .string)
        }
    }
}

public struct DatabaseNonSecretOption: Codable, Hashable, Sendable {
    public let name: String
    public let value: DatabaseNonSecretOptionValue

    public init(name: String, value: DatabaseNonSecretOptionValue) {
        self.name = name
        self.value = value
    }
}

public struct DatabaseConnectionIdentity: Codable, Hashable, Sendable {
    public let id: DatabaseConnectionID
    public let displayName: String
    public let productHint: DatabaseProduct
    public let environment: DatabaseEnvironmentMetadata

    public init(
        id: DatabaseConnectionID,
        displayName: String,
        productHint: DatabaseProduct,
        environment: DatabaseEnvironmentMetadata
    ) {
        self.id = id
        self.displayName = displayName
        self.productHint = productHint
        self.environment = environment
    }
}

public struct DatabaseConnectionDefinition: Codable, Hashable, Sendable {
    public static let schemaVersion = 1

    public let version: Int
    public let id: DatabaseConnectionID
    public let displayName: String
    public let productHint: DatabaseProduct
    public let location: DatabaseConnectionLocation
    public let username: String?
    public let namespaces: DatabaseNamespaceDefaults
    public let deploymentMode: DatabaseDeploymentMode
    public let authentication: DatabaseAuthentication
    public let tls: DatabaseTLSConfiguration
    public let tunnel: DatabaseTunnelDefinition?
    public let limits: DatabaseConnectionLimits
    public let readOnlyPolicy: DatabaseReadOnlyPolicy
    public let productionPolicy: DatabaseProductionPolicy
    public let environment: DatabaseEnvironmentMetadata
    public let group: String?
    public let tags: [String]
    public let color: String?
    public let isFavorite: Bool
    public let options: [DatabaseNonSecretOption]
    public let createdAt: Date
    public let updatedAt: Date
    public let lastTestedAt: Date?
    public let lastUsedAt: Date?

    public var identity: DatabaseConnectionIdentity {
        DatabaseConnectionIdentity(
            id: id,
            displayName: displayName,
            productHint: productHint,
            environment: environment)
    }

    public init(
        version: Int = DatabaseConnectionDefinition.schemaVersion,
        id: DatabaseConnectionID,
        displayName: String,
        productHint: DatabaseProduct,
        location: DatabaseConnectionLocation,
        username: String? = nil,
        namespaces: DatabaseNamespaceDefaults = DatabaseNamespaceDefaults(),
        deploymentMode: DatabaseDeploymentMode = .automatic,
        authentication: DatabaseAuthentication,
        tls: DatabaseTLSConfiguration,
        tunnel: DatabaseTunnelDefinition? = nil,
        limits: DatabaseConnectionLimits,
        readOnlyPolicy: DatabaseReadOnlyPolicy = .disabled,
        productionPolicy: DatabaseProductionPolicy = .standard,
        environment: DatabaseEnvironmentMetadata,
        group: String? = nil,
        tags: [String] = [],
        color: String? = nil,
        isFavorite: Bool = false,
        options: [DatabaseNonSecretOption] = [],
        createdAt: Date,
        updatedAt: Date,
        lastTestedAt: Date? = nil,
        lastUsedAt: Date? = nil
    ) {
        self.version = version
        self.id = id
        self.displayName = displayName
        self.productHint = productHint
        self.location = location
        self.username = username
        self.namespaces = namespaces
        self.deploymentMode = deploymentMode
        self.authentication = authentication
        self.tls = tls
        self.tunnel = tunnel
        self.limits = limits
        self.readOnlyPolicy = readOnlyPolicy
        self.productionPolicy = productionPolicy
        self.environment = environment
        self.group = group
        self.tags = tags
        self.color = color
        self.isFavorite = isFavorite
        self.options = options
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastTestedAt = lastTestedAt
        self.lastUsedAt = lastUsedAt
    }
}
