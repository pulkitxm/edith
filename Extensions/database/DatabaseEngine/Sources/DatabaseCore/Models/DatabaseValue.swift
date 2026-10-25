import Foundation

public struct DatabaseDecimalValue: RawRepresentable, Codable, Hashable, Sendable,
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

public enum DatabaseBinaryValue: Codable, Hashable, Sendable {
    case complete(data: Data, mediaType: String?, digest: String?)
    case preview(byteCount: UInt64, bytes: Data, mediaType: String?, digest: String?)

    public var byteCount: UInt64 {
        switch self {
        case let .complete(data, _, _):
            UInt64(data.count)
        case let .preview(byteCount, _, _, _):
            byteCount
        }
    }

    public var isComplete: Bool {
        if case .complete = self { return true }
        return false
    }

    public var availableBytes: Data {
        switch self {
        case let .complete(data, _, _):
            data
        case let .preview(_, bytes, _, _):
            bytes
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case data
        case byteCount
        case mediaType
        case digest
    }

    private enum Kind: String, Codable {
        case complete
        case preview
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mediaType = try container.decodeIfPresent(String.self, forKey: .mediaType)
        let digest = try container.decodeIfPresent(String.self, forKey: .digest)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .complete:
            self = .complete(
                data: try container.decode(Data.self, forKey: .data),
                mediaType: mediaType,
                digest: digest)
        case .preview:
            self = .preview(
                byteCount: try container.decode(UInt64.self, forKey: .byteCount),
                bytes: try container.decode(Data.self, forKey: .data),
                mediaType: mediaType,
                digest: digest)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .complete(data, mediaType, digest):
            try container.encode(Kind.complete, forKey: .kind)
            try container.encode(data, forKey: .data)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(digest, forKey: .digest)
        case let .preview(byteCount, bytes, mediaType, digest):
            try container.encode(Kind.preview, forKey: .kind)
            try container.encode(byteCount, forKey: .byteCount)
            try container.encode(bytes, forKey: .data)
            try container.encodeIfPresent(mediaType, forKey: .mediaType)
            try container.encodeIfPresent(digest, forKey: .digest)
        }
    }
}

public struct DatabaseDateValue: Codable, Hashable, Sendable {
    public let text: String
    public let calendarIdentifier: String?

    public init(text: String, calendarIdentifier: String? = nil) {
        self.text = text
        self.calendarIdentifier = calendarIdentifier
    }
}

public struct DatabaseTimeValue: Codable, Hashable, Sendable {
    public let text: String
    public let timeZoneOffsetMinutes: Int?
    public let precision: Int?

    public init(text: String, timeZoneOffsetMinutes: Int? = nil, precision: Int? = nil) {
        self.text = text
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.precision = precision
    }
}

public struct DatabaseTimestampValue: Codable, Hashable, Sendable {
    public let text: String
    public let timeZoneIdentifier: String?
    public let timeZoneOffsetMinutes: Int?
    public let precision: Int?

    public init(
        text: String,
        timeZoneIdentifier: String? = nil,
        timeZoneOffsetMinutes: Int? = nil,
        precision: Int? = nil
    ) {
        self.text = text
        self.timeZoneIdentifier = timeZoneIdentifier
        self.timeZoneOffsetMinutes = timeZoneOffsetMinutes
        self.precision = precision
    }
}

public struct DatabaseProductValue: Codable, Hashable, Sendable {
    public let product: DatabaseProduct?
    public let typeName: String
    public let textRepresentation: String?
    public let binaryRepresentation: Data?
    public let attributes: [DatabaseStringAttribute]

    public init(
        product: DatabaseProduct? = nil,
        typeName: String,
        textRepresentation: String? = nil,
        binaryRepresentation: Data? = nil,
        attributes: [DatabaseStringAttribute] = []
    ) {
        self.product = product
        self.typeName = typeName
        self.textRepresentation = textRepresentation
        self.binaryRepresentation = binaryRepresentation
        self.attributes = attributes
    }
}

public struct DatabaseObjectField: Codable, Hashable, Sendable {
    public let name: String
    public let value: DatabaseValue

    public init(name: String, value: DatabaseValue) {
        self.name = name
        self.value = value
    }
}

public indirect enum DatabaseValue: Hashable, Sendable {
    case missing
    case null
    case boolean(Bool)
    case signedInteger(Int64)
    case unsignedInteger(UInt64)
    case decimal(DatabaseDecimalValue)
    case floatingPoint(Double)
    case string(String)
    case binary(DatabaseBinaryValue)
    case date(DatabaseDateValue)
    case time(DatabaseTimeValue)
    case timestamp(DatabaseTimestampValue)
    case uuid(UUID)
    case array([DatabaseValue])
    case object([DatabaseObjectField])
    case productSpecific(DatabaseProductValue)
}

extension DatabaseValue: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case boolean
        case signedInteger
        case unsignedInteger
        case decimal
        case floatingPointBits
        case string
        case binary
        case date
        case time
        case timestamp
        case uuid
        case values
        case fields
        case productSpecific
    }

    private enum Kind: String, Codable {
        case missing
        case null
        case boolean
        case signedInteger
        case unsignedInteger
        case decimal
        case floatingPoint
        case string
        case binary
        case date
        case time
        case timestamp
        case uuid
        case array
        case object
        case productSpecific
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .missing:
            self = .missing
        case .null:
            self = .null
        case .boolean:
            self = .boolean(try container.decode(Bool.self, forKey: .boolean))
        case .signedInteger:
            self = .signedInteger(try container.decode(Int64.self, forKey: .signedInteger))
        case .unsignedInteger:
            self = .unsignedInteger(try container.decode(UInt64.self, forKey: .unsignedInteger))
        case .decimal:
            self = .decimal(
                DatabaseDecimalValue(
                    rawValue: try container.decode(String.self, forKey: .decimal)))
        case .floatingPoint:
            self = .floatingPoint(
                Double(
                    bitPattern: try container.decode(UInt64.self, forKey: .floatingPointBits)))
        case .string:
            self = .string(try container.decode(String.self, forKey: .string))
        case .binary:
            self = .binary(try container.decode(DatabaseBinaryValue.self, forKey: .binary))
        case .date:
            self = .date(try container.decode(DatabaseDateValue.self, forKey: .date))
        case .time:
            self = .time(try container.decode(DatabaseTimeValue.self, forKey: .time))
        case .timestamp:
            self = .timestamp(
                try container.decode(DatabaseTimestampValue.self, forKey: .timestamp))
        case .uuid:
            self = .uuid(try container.decode(UUID.self, forKey: .uuid))
        case .array:
            self = .array(try container.decode([DatabaseValue].self, forKey: .values))
        case .object:
            self = .object(try container.decode([DatabaseObjectField].self, forKey: .fields))
        case .productSpecific:
            self = .productSpecific(
                try container.decode(DatabaseProductValue.self, forKey: .productSpecific))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .missing:
            try container.encode(Kind.missing, forKey: .kind)
        case .null:
            try container.encode(Kind.null, forKey: .kind)
        case let .boolean(value):
            try container.encode(Kind.boolean, forKey: .kind)
            try container.encode(value, forKey: .boolean)
        case let .signedInteger(value):
            try container.encode(Kind.signedInteger, forKey: .kind)
            try container.encode(value, forKey: .signedInteger)
        case let .unsignedInteger(value):
            try container.encode(Kind.unsignedInteger, forKey: .kind)
            try container.encode(value, forKey: .unsignedInteger)
        case let .decimal(value):
            try container.encode(Kind.decimal, forKey: .kind)
            try container.encode(value.rawValue, forKey: .decimal)
        case let .floatingPoint(value):
            try container.encode(Kind.floatingPoint, forKey: .kind)
            try container.encode(value.bitPattern, forKey: .floatingPointBits)
        case let .string(value):
            try container.encode(Kind.string, forKey: .kind)
            try container.encode(value, forKey: .string)
        case let .binary(value):
            try container.encode(Kind.binary, forKey: .kind)
            try container.encode(value, forKey: .binary)
        case let .date(value):
            try container.encode(Kind.date, forKey: .kind)
            try container.encode(value, forKey: .date)
        case let .time(value):
            try container.encode(Kind.time, forKey: .kind)
            try container.encode(value, forKey: .time)
        case let .timestamp(value):
            try container.encode(Kind.timestamp, forKey: .kind)
            try container.encode(value, forKey: .timestamp)
        case let .uuid(value):
            try container.encode(Kind.uuid, forKey: .kind)
            try container.encode(value, forKey: .uuid)
        case let .array(values):
            try container.encode(Kind.array, forKey: .kind)
            try container.encode(values, forKey: .values)
        case let .object(fields):
            try container.encode(Kind.object, forKey: .kind)
            try container.encode(fields, forKey: .fields)
        case let .productSpecific(value):
            try container.encode(Kind.productSpecific, forKey: .kind)
            try container.encode(value, forKey: .productSpecific)
        }
    }
}
