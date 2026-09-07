import Foundation

enum OpenSearchDatabaseJSONValue: Codable, Hashable, Sendable {
    case null
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case floatingPoint(Double)
    case string(String)
    case array([OpenSearchDatabaseJSONValue])
    case object([String: OpenSearchDatabaseJSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .boolean(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .signedInteger(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self), value.isFinite {
            self = .floatingPoint(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([OpenSearchDatabaseJSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(
            [String: OpenSearchDatabaseJSONValue].self)
        {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported OpenSearch JSON value.")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case let .boolean(value):
            try container.encode(value)
        case let .signedInteger(value):
            try container.encode(value)
        case let .unsignedInteger(value):
            try container.encode(value)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw EncodingError.invalidValue(
                    value,
                    EncodingError.Context(
                        codingPath: encoder.codingPath,
                        debugDescription: "Non-finite OpenSearch JSON number."))
            }
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(value):
            try container.encode(value)
        case let .object(value):
            try container.encode(value)
        }
    }

    init(databaseValue: DatabaseValue) throws {
        switch databaseValue {
        case .missing:
            throw OpenSearchDatabaseJSONValueError.invalid
        case .null:
            self = .null
        case let .boolean(value):
            self = .boolean(value)
        case let .signedInteger(value):
            self = .signedInteger(value)
        case let .unsignedInteger(value):
            self = .unsignedInteger(value)
        case let .decimal(value):
            guard let number = Double(value.rawValue), number.isFinite else {
                throw OpenSearchDatabaseJSONValueError.invalid
            }
            self = .floatingPoint(number)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw OpenSearchDatabaseJSONValueError.invalid
            }
            self = .floatingPoint(value)
        case let .string(value):
            self = .string(value)
        case .binary:
            throw OpenSearchDatabaseJSONValueError.invalid
        case let .date(value):
            self = .string(value.text)
        case let .time(value):
            self = .string(value.text)
        case let .timestamp(value):
            self = .string(value.text)
        case let .uuid(value):
            self = .string(value.uuidString.lowercased())
        case let .array(values):
            self = .array(try values.map(Self.init(databaseValue:)))
        case let .object(fields):
            var output: [String: OpenSearchDatabaseJSONValue] = [:]
            for field in fields {
                guard output[field.name] == nil else {
                    throw OpenSearchDatabaseJSONValueError.invalid
                }
                output[field.name] = try Self(databaseValue: field.value)
            }
            self = .object(output)
        case let .productSpecific(value):
            guard value.binaryRepresentation == nil,
                let text = value.textRepresentation
            else {
                throw OpenSearchDatabaseJSONValueError.invalid
            }
            self = .string(text)
        }
    }

    func databaseValue(
        maximumDepth: Int = 32,
        maximumNodes: Int = 100_000,
        maximumStringBytes: Int = 1_048_576
    ) throws -> DatabaseValue {
        var nodes = 0
        return try databaseValue(
            depth: 0,
            nodes: &nodes,
            maximumDepth: maximumDepth,
            maximumNodes: maximumNodes,
            maximumStringBytes: maximumStringBytes)
    }

    func isBoundedScalar(maximumStringBytes: Int = 16_384) -> Bool {
        switch self {
        case .null, .boolean, .signedInteger, .unsignedInteger, .floatingPoint:
            return true
        case let .string(value):
            return value.utf8.count <= maximumStringBytes && !value.contains("\0")
        case .array, .object:
            return false
        }
    }

    private func databaseValue(
        depth: Int,
        nodes: inout Int,
        maximumDepth: Int,
        maximumNodes: Int,
        maximumStringBytes: Int
    ) throws -> DatabaseValue {
        guard depth <= maximumDepth, nodes < maximumNodes else {
            throw OpenSearchDatabaseJSONValueError.limitExceeded
        }
        nodes += 1
        switch self {
        case .null:
            return .null
        case let .boolean(value):
            return .boolean(value)
        case let .signedInteger(value):
            return .signedInteger(value)
        case let .unsignedInteger(value):
            return .unsignedInteger(value)
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw OpenSearchDatabaseJSONValueError.invalid
            }
            return .floatingPoint(value)
        case let .string(value):
            guard value.utf8.count <= maximumStringBytes, !value.contains("\0") else {
                throw OpenSearchDatabaseJSONValueError.limitExceeded
            }
            return .string(value)
        case let .array(values):
            guard values.count <= 10_000 else {
                throw OpenSearchDatabaseJSONValueError.limitExceeded
            }
            return .array(
                try values.map {
                    try $0.databaseValue(
                        depth: depth + 1,
                        nodes: &nodes,
                        maximumDepth: maximumDepth,
                        maximumNodes: maximumNodes,
                        maximumStringBytes: maximumStringBytes)
                })
        case let .object(values):
            guard values.count <= DatabaseAdapterBounds.maximumRecordFields else {
                throw OpenSearchDatabaseJSONValueError.limitExceeded
            }
            var fields: [DatabaseObjectField] = []
            fields.reserveCapacity(values.count)
            for name in values.keys.sorted() {
                guard name.utf8.count <= 4_096, !name.contains("\0"), let value = values[name]
                else {
                    throw OpenSearchDatabaseJSONValueError.limitExceeded
                }
                fields.append(
                    DatabaseObjectField(
                        name: name,
                        value: try value.databaseValue(
                            depth: depth + 1,
                            nodes: &nodes,
                            maximumDepth: maximumDepth,
                            maximumNodes: maximumNodes,
                            maximumStringBytes: maximumStringBytes)))
            }
            return .object(fields)
        }
    }
}

enum OpenSearchDatabaseJSONValueError: Error, Equatable, Sendable {
    case invalid
    case limitExceeded
}

enum OpenSearchDatabaseJSONCodec {
    static func encode(_ value: OpenSearchDatabaseJSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= OpenSearchDatabaseTransport.maximumRequestBytes else {
            throw OpenSearchDatabaseJSONValueError.limitExceeded
        }
        return data
    }
}
