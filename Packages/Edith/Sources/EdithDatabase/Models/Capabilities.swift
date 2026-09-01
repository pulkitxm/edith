import Foundation

public struct DatabaseCapabilityID: RawRepresentable, Codable, Hashable, Sendable,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        rawValue = value
    }
}

extension DatabaseCapabilityID {
    public static let connectionTest: Self = "connection.test"
    public static let objectDiscovery: Self = "objects.discover"
    public static let objectDescription: Self = "objects.describe"
    public static let query: Self = "query.execute"
    public static let queryCancellation: Self = "query.cancel"
    public static let explain: Self = "query.explain"
    public static let browse: Self = "data.browse"
    public static let insert: Self = "data.insert"
    public static let update: Self = "data.update"
    public static let delete: Self = "data.delete"
    public static let bulkMutation: Self = "data.bulk-mutation"
    public static let mutationStatus: Self = "data.mutation-status"
    public static let mutationCancellation: Self = "data.mutation-cancel"
    public static let importData: Self = "data.import"
    public static let exportData: Self = "data.export"
    public static let transactions: Self = "transactions"
    public static let schemaMutation: Self = "schema.mutate"
    public static let monitoring: Self = "monitoring"
    public static let administration: Self = "administration"
}

public enum DatabaseCapabilityRequirement: String, CaseIterable, Codable, Hashable, Sendable {
    case sharedRequired
    case familyRequired
    case productRequired
    case plannedExtension
    case unsupported
}

public enum DatabaseCapabilityAvailability: String, CaseIterable, Codable, Hashable, Sendable {
    case available
    case degraded
    case unavailable
    case planned
}

public enum DatabaseCapabilityUnavailableCategory: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case product
    case version
    case topology
    case permission
    case module
    case plugin
    case license
    case connectionPolicy
    case configuration
    case unsafe
    case notImplemented
    case unknown
}

public struct DatabaseCapabilityUnavailableReason: Codable, Hashable, Sendable {
    public let category: DatabaseCapabilityUnavailableCategory
    public let message: String
    public let requiredVersion: String?
    public let requiredTopology: DatabaseTopologyKind?
    public let missingPermissions: [String]
    public let requiredExtension: String?
    public let constraints: [DatabaseStringAttribute]

    public init(
        category: DatabaseCapabilityUnavailableCategory,
        message: String,
        requiredVersion: String? = nil,
        requiredTopology: DatabaseTopologyKind? = nil,
        missingPermissions: [String] = [],
        requiredExtension: String? = nil,
        constraints: [DatabaseStringAttribute] = []
    ) {
        self.category = category
        self.message = message
        self.requiredVersion = requiredVersion
        self.requiredTopology = requiredTopology
        self.missingPermissions = missingPermissions
        self.requiredExtension = requiredExtension
        self.constraints = constraints
    }
}

public struct DatabaseCapabilityLimit: Codable, Hashable, Sendable {
    public let name: String
    public let value: UInt64
    public let unit: String?

    public init(name: String, value: UInt64, unit: String? = nil) {
        self.name = name
        self.value = value
        self.unit = unit
    }
}

public struct DatabaseCapabilityStatus: Codable, Hashable, Sendable {
    public let id: DatabaseCapabilityID
    public let requirement: DatabaseCapabilityRequirement
    public let availability: DatabaseCapabilityAvailability
    public let reason: DatabaseCapabilityUnavailableReason?
    public let limits: [DatabaseCapabilityLimit]
    public let attributes: [DatabaseStringAttribute]

    public var isAvailable: Bool {
        availability == .available || availability == .degraded
    }

    public init(
        id: DatabaseCapabilityID,
        requirement: DatabaseCapabilityRequirement,
        availability: DatabaseCapabilityAvailability,
        reason: DatabaseCapabilityUnavailableReason? = nil,
        limits: [DatabaseCapabilityLimit] = [],
        attributes: [DatabaseStringAttribute] = []
    ) {
        self.id = id
        self.requirement = requirement
        self.availability = availability
        self.reason = reason
        self.limits = limits
        self.attributes = attributes
    }
}

public enum DatabasePagingMode: String, CaseIterable, Codable, Hashable, Sendable {
    case keyset
    case serverCursor
    case scanCursor
    case pointInTime
    case streamed
    case offset
}

public enum DatabaseMutationMode: String, CaseIterable, Codable, Hashable, Sendable {
    case singleRecord
    case transactionalBatch
    case boundedBatch
    case asynchronousTask
    case unsupported
}

public enum DatabaseTransactionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case implicit
    case explicit
    case savepoints
    case distributed
}

public enum DatabaseCancellationMode: String, CaseIterable, Codable, Hashable, Sendable {
    case none
    case cooperative
    case protocolCancellation
    case serverOperation
}

public enum DatabaseDataFormat: String, CaseIterable, Codable, Hashable, Sendable {
    case csv
    case tsv
    case json
    case jsonLines
    case sql
    case native
    case parquet
}

public enum DatabaseExplainMode: String, CaseIterable, Codable, Hashable, Sendable {
    case logical
    case physical
    case analyzed
    case pipeline
    case indexes
}

public struct DatabasePermissionStatus: Codable, Hashable, Sendable {
    public let name: String
    public let granted: Bool?
    public let scope: String?

    public init(name: String, granted: Bool?, scope: String? = nil) {
        self.name = name
        self.granted = granted
        self.scope = scope
    }
}

public struct DatabaseCapabilityReport: Codable, Hashable, Sendable {
    public let productIdentity: DatabaseProductIdentity
    public let capabilities: [DatabaseCapabilityStatus]
    public let permissions: [DatabasePermissionStatus]
    public let pagingModes: [DatabasePagingMode]
    public let mutationModes: [DatabaseMutationMode]
    public let transactionModes: [DatabaseTransactionMode]
    public let cancellationModes: [DatabaseCancellationMode]
    public let importFormats: [DatabaseDataFormat]
    public let exportFormats: [DatabaseDataFormat]
    public let explainModes: [DatabaseExplainMode]
    public let safetyLimitations: [String]
    public let discoveredAt: Date
    public let expiresAt: Date?

    public init(
        productIdentity: DatabaseProductIdentity,
        capabilities: [DatabaseCapabilityStatus],
        permissions: [DatabasePermissionStatus] = [],
        pagingModes: [DatabasePagingMode] = [],
        mutationModes: [DatabaseMutationMode] = [],
        transactionModes: [DatabaseTransactionMode] = [],
        cancellationModes: [DatabaseCancellationMode] = [],
        importFormats: [DatabaseDataFormat] = [],
        exportFormats: [DatabaseDataFormat] = [],
        explainModes: [DatabaseExplainMode] = [],
        safetyLimitations: [String] = [],
        discoveredAt: Date,
        expiresAt: Date? = nil
    ) {
        self.productIdentity = productIdentity
        self.capabilities = capabilities
        self.permissions = permissions
        self.pagingModes = pagingModes
        self.mutationModes = mutationModes
        self.transactionModes = transactionModes
        self.cancellationModes = cancellationModes
        self.importFormats = importFormats
        self.exportFormats = exportFormats
        self.explainModes = explainModes
        self.safetyLimitations = safetyLimitations
        self.discoveredAt = discoveredAt
        self.expiresAt = expiresAt
    }

    public func status(for id: DatabaseCapabilityID) -> DatabaseCapabilityStatus? {
        capabilities.first { $0.id == id }
    }

    public func supports(_ id: DatabaseCapabilityID) -> Bool {
        status(for: id)?.isAvailable == true
    }

    public func unavailableReason(
        for id: DatabaseCapabilityID
    ) -> DatabaseCapabilityUnavailableReason? {
        status(for: id)?.reason
    }
}
