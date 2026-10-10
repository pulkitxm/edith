import Foundation

public enum DatabaseFamily: String, CaseIterable, Codable, Hashable, Sendable {
    case relational
    case keyValue
    case document
    case search
    case analytical
}

public enum DatabaseProduct: String, CaseIterable, Codable, Hashable, Sendable {
    case postgresql
    case mysql
    case mariaDB = "mariadb"
    case sqlite
    case redis
    case valkey
    case mongoDB = "mongodb"
    case elasticsearch
    case openSearch = "opensearch"
    case clickHouse = "clickhouse"

    public var family: DatabaseFamily {
        switch self {
        case .postgresql, .mysql, .mariaDB, .sqlite:
            .relational
        case .redis, .valkey:
            .keyValue
        case .mongoDB:
            .document
        case .elasticsearch, .openSearch:
            .search
        case .clickHouse:
            .analytical
        }
    }

    public var displayName: String {
        switch self {
        case .postgresql:
            "PostgreSQL"
        case .mysql:
            "MySQL"
        case .mariaDB:
            "MariaDB"
        case .sqlite:
            "SQLite"
        case .redis:
            "Redis"
        case .valkey:
            "Valkey"
        case .mongoDB:
            "MongoDB"
        case .elasticsearch:
            "Elasticsearch"
        case .openSearch:
            "OpenSearch"
        case .clickHouse:
            "ClickHouse"
        }
    }
}

public struct DatabaseVersion: Codable, Hashable, Sendable {
    public let string: String
    public let major: Int?
    public let minor: Int?
    public let patch: Int?

    public init(string: String, major: Int? = nil, minor: Int? = nil, patch: Int? = nil) {
        self.string = string
        self.major = major
        self.minor = minor
        self.patch = patch
    }
}

public enum DatabaseTopologyKind: String, CaseIterable, Codable, Hashable, Sendable {
    case unknown
    case embedded
    case standalone
    case primaryReplica
    case sentinel
    case cluster
    case replicaSet
    case shardedCluster
    case distributed
}

public struct DatabaseStringAttribute: Codable, Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct DatabaseTopology: Codable, Hashable, Sendable {
    public let kind: DatabaseTopologyKind
    public let name: String?
    public let localRole: String?
    public let nodeCount: Int?
    public let replicaCount: Int?
    public let shardCount: Int?
    public let attributes: [DatabaseStringAttribute]

    public init(
        kind: DatabaseTopologyKind,
        name: String? = nil,
        localRole: String? = nil,
        nodeCount: Int? = nil,
        replicaCount: Int? = nil,
        shardCount: Int? = nil,
        attributes: [DatabaseStringAttribute] = []
    ) {
        self.kind = kind
        self.name = name
        self.localRole = localRole
        self.nodeCount = nodeCount
        self.replicaCount = replicaCount
        self.shardCount = shardCount
        self.attributes = attributes
    }
}

public struct DatabaseExtensionIdentity: Codable, Hashable, Sendable {
    public let name: String
    public let version: String?

    public init(name: String, version: String? = nil) {
        self.name = name
        self.version = version
    }
}

public struct DatabaseProductIdentity: Codable, Hashable, Sendable {
    public let product: DatabaseProduct
    public let version: DatabaseVersion?
    public let distribution: String?
    public let topology: DatabaseTopology
    public let serverIdentifier: String?
    public let modules: [DatabaseExtensionIdentity]
    public let plugins: [DatabaseExtensionIdentity]
    public let compatibilityNotes: [String]

    public var family: DatabaseFamily { product.family }

    public init(
        product: DatabaseProduct,
        version: DatabaseVersion? = nil,
        distribution: String? = nil,
        topology: DatabaseTopology,
        serverIdentifier: String? = nil,
        modules: [DatabaseExtensionIdentity] = [],
        plugins: [DatabaseExtensionIdentity] = [],
        compatibilityNotes: [String] = []
    ) {
        self.product = product
        self.version = version
        self.distribution = distribution
        self.topology = topology
        self.serverIdentifier = serverIdentifier
        self.modules = modules
        self.plugins = plugins
        self.compatibilityNotes = compatibilityNotes
    }
}
