import Foundation

public struct DatabaseFieldPath: Codable, Hashable, Sendable {
    public let segments: [String]

    public init(_ segments: [String]) {
        self.segments = segments
    }

    public init(_ segment: String) {
        segments = [segment]
    }
}

public enum DatabaseProjectionMode: String, CaseIterable, Codable, Hashable, Sendable {
    case include
    case exclude
}

public struct DatabaseProjectedField: Codable, Hashable, Sendable {
    public let path: DatabaseFieldPath
    public let alias: String?

    public init(path: DatabaseFieldPath, alias: String? = nil) {
        self.path = path
        self.alias = alias
    }
}

public struct DatabaseProjection: Codable, Hashable, Sendable {
    public let mode: DatabaseProjectionMode
    public let fields: [DatabaseProjectedField]

    public init(mode: DatabaseProjectionMode, fields: [DatabaseProjectedField]) {
        self.mode = mode
        self.fields = fields
    }
}

public enum DatabaseFilterOperator: String, CaseIterable, Codable, Hashable, Sendable {
    case equal
    case notEqual
    case greaterThan
    case greaterThanOrEqual
    case lessThan
    case lessThanOrEqual
    case contains
    case startsWith
    case endsWith
    case `in`
    case notIn
    case between
    case isNull
    case isNotNull
    case isMissing
    case isNotMissing
    case regularExpression
    case fullText
}

public enum DatabaseFilterCaseSensitivity: String, CaseIterable, Codable, Hashable, Sendable {
    case productDefault
    case sensitive
    case insensitive
}

public struct DatabaseFilterPredicate: Codable, Hashable, Sendable {
    public let field: DatabaseFieldPath
    public let operation: DatabaseFilterOperator
    public let values: [DatabaseValue]
    public let caseSensitivity: DatabaseFilterCaseSensitivity

    public init(
        field: DatabaseFieldPath,
        operation: DatabaseFilterOperator,
        values: [DatabaseValue] = [],
        caseSensitivity: DatabaseFilterCaseSensitivity = .productDefault
    ) {
        self.field = field
        self.operation = operation
        self.values = values
        self.caseSensitivity = caseSensitivity
    }
}

public indirect enum DatabaseFilter: Hashable, Sendable {
    case predicate(DatabaseFilterPredicate)
    case all([DatabaseFilter])
    case any([DatabaseFilter])
    case not(DatabaseFilter)
}

extension DatabaseFilter: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case predicate
        case children
        case child
    }

    private enum Kind: String, Codable {
        case predicate
        case all
        case any
        case not
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .predicate:
            self = .predicate(
                try container.decode(DatabaseFilterPredicate.self, forKey: .predicate))
        case .all:
            self = .all(try container.decode([DatabaseFilter].self, forKey: .children))
        case .any:
            self = .any(try container.decode([DatabaseFilter].self, forKey: .children))
        case .not:
            self = .not(try container.decode(DatabaseFilter.self, forKey: .child))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .predicate(predicate):
            try container.encode(Kind.predicate, forKey: .kind)
            try container.encode(predicate, forKey: .predicate)
        case let .all(children):
            try container.encode(Kind.all, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .any(children):
            try container.encode(Kind.any, forKey: .kind)
            try container.encode(children, forKey: .children)
        case let .not(child):
            try container.encode(Kind.not, forKey: .kind)
            try container.encode(child, forKey: .child)
        }
    }
}

public enum DatabaseSortDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case ascending
    case descending
}

public enum DatabaseNullPlacement: String, CaseIterable, Codable, Hashable, Sendable {
    case productDefault
    case first
    case last
}

public struct DatabaseSort: Codable, Hashable, Sendable {
    public let field: DatabaseFieldPath
    public let direction: DatabaseSortDirection
    public let nullPlacement: DatabaseNullPlacement

    public init(
        field: DatabaseFieldPath,
        direction: DatabaseSortDirection,
        nullPlacement: DatabaseNullPlacement = .productDefault
    ) {
        self.field = field
        self.direction = direction
        self.nullPlacement = nullPlacement
    }
}
