import Foundation

public enum DatabaseObjectKind: String, CaseIterable, Codable, Hashable, Sendable {
    case server
    case cluster
    case node
    case catalog
    case database
    case schema
    case table
    case view
    case materializedView
    case column
    case index
    case constraint
    case sequence
    case routine
    case type
    case role
    case keyspace
    case key
    case collection
    case alias
    case dataStream
    case template
    case pipeline
    case snapshot
    case dictionary
    case partition
    case part
    case other
}

public struct DatabaseObjectIdentifier: Codable, Hashable, Sendable {
    public let kind: DatabaseObjectKind
    public let path: [String]
    public let nativeIdentifier: String?

    public init(kind: DatabaseObjectKind, path: [String], nativeIdentifier: String? = nil) {
        self.kind = kind
        self.path = path
        self.nativeIdentifier = nativeIdentifier
    }
}

public enum DatabaseRecordIdentityKind: String, CaseIterable, Codable, Hashable, Sendable {
    case primaryKey
    case uniqueKey
    case rowID
    case documentID
    case searchDocument
    case key
    case explicitPredicate
}

public struct DatabaseIdentityComponent: Codable, Hashable, Sendable {
    public let name: String
    public let value: DatabaseValue

    public init(name: String, value: DatabaseValue) {
        self.name = name
        self.value = value
    }
}

public struct DatabaseRecordIdentity: Codable, Hashable, Sendable {
    public let kind: DatabaseRecordIdentityKind
    public let components: [DatabaseIdentityComponent]
    public let concurrencyTokens: [DatabaseIdentityComponent]

    public init(
        kind: DatabaseRecordIdentityKind,
        components: [DatabaseIdentityComponent],
        concurrencyTokens: [DatabaseIdentityComponent] = []
    ) {
        self.kind = kind
        self.components = components
        self.concurrencyTokens = concurrencyTokens
    }
}

public struct DatabaseTargetIdentifier: Codable, Hashable, Sendable {
    public let connectionID: DatabaseConnectionID
    public let object: DatabaseObjectIdentifier?
    public let record: DatabaseRecordIdentity?

    public init(
        connectionID: DatabaseConnectionID,
        object: DatabaseObjectIdentifier? = nil,
        record: DatabaseRecordIdentity? = nil
    ) {
        self.connectionID = connectionID
        self.object = object
        self.record = record
    }
}
