import CoreFoundation
import Foundation

public enum DatabaseJSONDocumentCodecError: Error, Equatable, Sendable {
    case invalidJSON
    case invalidDocument
    case unsupportedValue
    case resourceLimit
}

public enum DatabaseJSONDocumentCodec {
    public static let maximumBytes = 1_048_576
    public static let maximumDepth = 16
    public static let maximumElements = 4_096

    public static func decode(_ text: String) throws -> DatabaseValue {
        let data = Data(text.utf8)
        guard !data.isEmpty, data.count <= maximumBytes else {
            throw data.isEmpty
                ? DatabaseJSONDocumentCodecError.invalidJSON
                : DatabaseJSONDocumentCodecError.resourceLimit
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw DatabaseJSONDocumentCodecError.invalidJSON
        }
        var remaining = maximumElements
        return try value(object, depth: 0, remaining: &remaining)
    }

    public static func decodeObject(_ text: String) throws -> [DatabaseObjectField] {
        guard case let .object(fields) = try decode(text) else {
            throw DatabaseJSONDocumentCodecError.invalidDocument
        }
        return fields
    }

    public static func encode(_ value: DatabaseValue, pretty: Bool = true) throws -> String {
        var remaining = maximumElements
        let object = try object(value, depth: 0, remaining: &remaining)
        guard JSONSerialization.isValidJSONObject(object) else {
            throw DatabaseJSONDocumentCodecError.unsupportedValue
        }
        var options: JSONSerialization.WritingOptions = [.sortedKeys, .withoutEscapingSlashes]
        if pretty { options.insert(.prettyPrinted) }
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object, options: options)
        } catch {
            throw DatabaseJSONDocumentCodecError.unsupportedValue
        }
        guard data.count <= maximumBytes, let text = String(data: data, encoding: .utf8) else {
            throw DatabaseJSONDocumentCodecError.resourceLimit
        }
        return text
    }

    public static func encodeObject(
        _ fields: [DatabaseObjectField],
        pretty: Bool = true
    ) throws -> String {
        try encode(.object(fields), pretty: pretty)
    }

    private static func value(
        _ object: Any,
        depth: Int,
        remaining: inout Int
    ) throws -> DatabaseValue {
        try consume(depth: depth, remaining: &remaining)
        if object is NSNull { return .null }
        if let string = object as? String { return .string(string) }
        if let number = object as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .boolean(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                let value = number.doubleValue
                guard value.isFinite else {
                    throw DatabaseJSONDocumentCodecError.unsupportedValue
                }
                return .floatingPoint(value)
            }
            if number.stringValue.hasPrefix("-") {
                guard let value = Int64(number.stringValue) else {
                    throw DatabaseJSONDocumentCodecError.unsupportedValue
                }
                return .signedInteger(value)
            }
            if let value = Int64(number.stringValue) { return .signedInteger(value) }
            guard let value = UInt64(number.stringValue) else {
                throw DatabaseJSONDocumentCodecError.unsupportedValue
            }
            return .unsignedInteger(value)
        }
        if let array = object as? [Any] {
            return .array(
                try array.map { try value($0, depth: depth + 1, remaining: &remaining) })
        }
        guard let dictionary = object as? [String: Any] else {
            throw DatabaseJSONDocumentCodecError.unsupportedValue
        }
        if dictionary.count == 1 {
            if let raw = dictionary["$oid"] as? String {
                return .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "objectId",
                        textRepresentation: raw))
            }
            if let raw = dictionary["$date"] as? String {
                return .timestamp(DatabaseTimestampValue(text: raw))
            }
            if let raw = dictionary["$uuid"] as? String, let value = UUID(uuidString: raw) {
                return .uuid(value)
            }
            if let raw = dictionary["$binary"] as? String, let data = Data(base64Encoded: raw) {
                return .binary(.complete(data: data, mediaType: nil, digest: nil))
            }
        }
        return .object(
            try dictionary.keys.sorted().map { key in
                guard !key.isEmpty, !key.contains("\0") else {
                    throw DatabaseJSONDocumentCodecError.invalidDocument
                }
                return DatabaseObjectField(
                    name: key,
                    value: try value(
                        dictionary[key]!,
                        depth: depth + 1,
                        remaining: &remaining))
            })
    }

    private static func object(
        _ value: DatabaseValue,
        depth: Int,
        remaining: inout Int
    ) throws -> Any {
        try consume(depth: depth, remaining: &remaining)
        switch value {
        case .missing:
            throw DatabaseJSONDocumentCodecError.unsupportedValue
        case .null:
            return NSNull()
        case .boolean(let value):
            return value
        case .signedInteger(let value):
            return value
        case .unsignedInteger(let value):
            return value
        case .decimal:
            throw DatabaseJSONDocumentCodecError.unsupportedValue
        case .floatingPoint(let value):
            guard value.isFinite else {
                throw DatabaseJSONDocumentCodecError.unsupportedValue
            }
            return value
        case .string(let value):
            return value
        case .binary(let value):
            guard value.isComplete else {
                throw DatabaseJSONDocumentCodecError.unsupportedValue
            }
            return ["$binary": value.availableBytes.base64EncodedString()]
        case .date(let value):
            return ["$date": value.text]
        case .time(let value):
            return value.text
        case .timestamp(let value):
            return ["$date": value.text]
        case .uuid(let value):
            return ["$uuid": value.uuidString.lowercased()]
        case .array(let values):
            return try values.map { try object($0, depth: depth + 1, remaining: &remaining) }
        case .object(let fields):
            guard Set(fields.map(\.name)).count == fields.count else {
                throw DatabaseJSONDocumentCodecError.invalidDocument
            }
            return try Dictionary(
                uniqueKeysWithValues: fields.map { field in
                    (
                        field.name,
                        try object(field.value, depth: depth + 1, remaining: &remaining)
                    )
                })
        case .productSpecific(let value):
            guard value.product == nil || value.product == .mongoDB,
                value.typeName == "objectId",
                let text = value.textRepresentation
            else {
                throw DatabaseJSONDocumentCodecError.unsupportedValue
            }
            return ["$oid": text]
        }
    }

    private static func consume(depth: Int, remaining: inout Int) throws {
        guard depth <= maximumDepth, remaining > 0 else {
            throw DatabaseJSONDocumentCodecError.resourceLimit
        }
        remaining -= 1
    }
}
