import Foundation
import MongoKitten

enum MongoDBDatabaseValueCodecFailure: Error, Sendable {
    case invalidValue
    case resourceLimit
}

struct MongoDBDatabaseConvertedRecord: Sendable {
    let record: DatabaseRecord
    let objectID: ObjectId?
    let truncated: Bool
}

enum MongoDBDatabaseValueCodec {
    static let maximumQueryDepth = 16
    static let maximumQueryElements = 2_048
    static let maximumQueryBytes = 1_048_576
    static let maximumRecordDepth = 16
    static let maximumRecordElements = 4_096
    static let maximumRecordValueBytes = 524_288
    static let maximumScalarPreviewBytes = 8_192

    static func queryPrimitive(_ value: DatabaseValue) throws -> Primitive {
        var budget = MongoDBDatabaseValueCodecBudget(
            remainingBytes: maximumQueryBytes,
            remainingElements: maximumQueryElements)
        return try queryPrimitive(value, depth: 0, budget: &budget)
    }

    static func queryDocument(_ value: DatabaseValue) throws -> Document {
        guard let document = try queryPrimitive(value) as? Document, !document.isArray else {
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        }
        return document
    }

    static func convertedRecord(
        _ document: Document,
        hidesObjectID: Bool
    ) throws -> MongoDBDatabaseConvertedRecord {
        var budget = MongoDBDatabaseValueCodecBudget(
            remainingBytes: maximumRecordValueBytes,
            remainingElements: maximumRecordElements)
        var fields: [DatabaseObjectField] = []
        fields.reserveCapacity(min(document.count, DatabaseAdapterBounds.maximumRecordFields))
        var seen = Set<String>()
        var truncated = false

        for (name, primitive) in document {
            try validateFieldName(name)
            guard seen.insert(name).inserted else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            if name == "_id", hidesObjectID {
                continue
            }
            guard fields.count < DatabaseAdapterBounds.maximumRecordFields else {
                truncated = true
                break
            }
            guard budget.consume(bytes: name.utf8.count, elements: 1) else {
                truncated = true
                break
            }
            let converted = try outputValue(primitive, depth: 0, budget: &budget)
            fields.append(DatabaseObjectField(name: name, value: converted.value))
            truncated = truncated || converted.truncated
        }

        let objectID = document["_id"] as? ObjectId
        let identity: DatabaseRecordIdentity?
        if let rawIdentity = document["_id"] {
            var identityBudget = MongoDBDatabaseValueCodecBudget(
                remainingBytes: 32_768,
                remainingElements: 32)
            let convertedIdentity = try outputValue(
                rawIdentity,
                depth: 0,
                budget: &identityBudget)
            if convertedIdentity.truncated {
                identity = nil
                truncated = true
            } else {
                identity = DatabaseRecordIdentity(
                    kind: .documentID,
                    components: [
                        DatabaseIdentityComponent(name: "_id", value: convertedIdentity.value)
                    ])
            }
        } else {
            identity = nil
        }
        let metadata =
            truncated
            ? [DatabaseStringAttribute(name: "mongodb.truncated", value: "true")]
            : []
        return MongoDBDatabaseConvertedRecord(
            record: DatabaseRecord(identity: identity, fields: fields, metadata: metadata),
            objectID: objectID,
            truncated: truncated)
    }

    static func typeName(_ value: DatabaseValue) -> String {
        switch value {
        case .missing:
            "missing"
        case .null:
            "null"
        case .boolean:
            "boolean"
        case .signedInteger:
            "integer"
        case .unsignedInteger:
            "unsignedInteger"
        case .decimal:
            "decimal"
        case .floatingPoint:
            "double"
        case .string:
            "string"
        case .binary:
            "binary"
        case .date:
            "date"
        case .time:
            "time"
        case .timestamp:
            "timestamp"
        case .uuid:
            "uuid"
        case .array:
            "array"
        case .object:
            "object"
        case let .productSpecific(value):
            value.typeName
        }
    }

    private static func queryPrimitive(
        _ value: DatabaseValue,
        depth: Int,
        budget: inout MongoDBDatabaseValueCodecBudget
    ) throws -> Primitive {
        guard depth <= maximumQueryDepth,
            budget.consume(bytes: 1, elements: 1)
        else {
            throw MongoDBDatabaseValueCodecFailure.resourceLimit
        }
        switch value {
        case .missing, .date, .time:
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        case .null:
            return Null()
        case let .boolean(value):
            return value
        case let .signedInteger(value):
            guard let value = Int(exactly: value) else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            return value
        case let .unsignedInteger(value):
            guard let value = Int(exactly: value) else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            return value
        case .decimal:
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        case let .floatingPoint(value):
            guard value.isFinite else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            return value
        case let .string(value):
            guard value.utf8.count <= 262_144,
                !value.contains("\0"),
                budget.consume(bytes: value.utf8.count)
            else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return value
        case let .binary(value):
            guard case let .complete(data, _, _) = value,
                data.count <= 262_144,
                budget.consume(bytes: data.count)
            else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return binary(data: data, subtype: .generic)
        case let .timestamp(value):
            guard let date = parseTimestamp(value.text) else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            return date
        case let .uuid(value):
            var bytes = value.uuid
            let data = withUnsafeBytes(of: &bytes) { Data($0) }
            guard budget.consume(bytes: data.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return binary(data: data, subtype: .uuid)
        case let .array(values):
            guard values.count <= maximumQueryElements else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            var document = Document(isArray: true)
            for (index, value) in values.enumerated() {
                document[String(index)] = try queryPrimitive(
                    value,
                    depth: depth + 1,
                    budget: &budget)
            }
            return document
        case let .object(fields):
            guard fields.count <= maximumQueryElements else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            var document = Document()
            var seen = Set<String>()
            for field in fields {
                try validateQueryKey(field.name)
                guard seen.insert(field.name).inserted,
                    budget.consume(bytes: field.name.utf8.count)
                else {
                    throw MongoDBDatabaseValueCodecFailure.invalidValue
                }
                document[field.name] = try queryPrimitive(
                    field.value,
                    depth: depth + 1,
                    budget: &budget)
            }
            return document
        case let .productSpecific(value):
            guard value.product == nil || value.product == .mongoDB,
                value.typeName == "objectId",
                value.binaryRepresentation == nil,
                value.attributes.isEmpty,
                let text = value.textRepresentation,
                let objectID = ObjectId(text)
            else {
                throw MongoDBDatabaseValueCodecFailure.invalidValue
            }
            return objectID
        }
    }

    private static func outputValue(
        _ primitive: Primitive,
        depth: Int,
        budget: inout MongoDBDatabaseValueCodecBudget
    ) throws -> (value: DatabaseValue, truncated: Bool) {
        guard depth <= maximumRecordDepth else {
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "depthPreview",
                        attributes: [DatabaseStringAttribute(name: "truncated", value: "true")])),
                true
            )
        }
        guard budget.consume(bytes: 1, elements: 1) else {
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "valuePreview",
                        attributes: [DatabaseStringAttribute(name: "truncated", value: "true")])),
                true
            )
        }
        switch primitive {
        case is Null:
            return (.null, false)
        case let value as Bool:
            return (.boolean(value), false)
        case let value as Int32:
            return (.signedInteger(Int64(value)), false)
        case let value as Int:
            return (.signedInteger(Int64(value)), false)
        case let value as Double:
            return (.floatingPoint(value), false)
        case let value as String:
            let preview = preview(
                value, byteLimit: min(max(0, budget.remainingBytes), maximumScalarPreviewBytes))
            guard budget.consume(bytes: preview.text.utf8.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            if preview.truncated {
                return (
                    .productSpecific(
                        DatabaseProductValue(
                            product: .mongoDB,
                            typeName: "stringPreview",
                            textRepresentation: preview.text,
                            attributes: [
                                DatabaseStringAttribute(
                                    name: "byteCount",
                                    value: String(value.utf8.count)),
                                DatabaseStringAttribute(name: "truncated", value: "true"),
                            ])),
                    true
                )
            }
            return (.string(value), false)
        case let value as ObjectId:
            guard budget.consume(bytes: value.hexString.utf8.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "objectId",
                        textRepresentation: value.hexString)),
                false
            )
        case let value as Date:
            let text = timestampText(value)
            guard budget.consume(bytes: text.utf8.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (
                .timestamp(
                    DatabaseTimestampValue(
                        text: text,
                        timeZoneIdentifier: "UTC",
                        timeZoneOffsetMinutes: 0,
                        precision: 3)),
                false
            )
        case let value as Binary:
            return try outputBinary(value, budget: &budget)
        case let value as Decimal128:
            var wrapper = Document()
            wrapper["value"] = value
            let data = wrapper.makeData()
            let available = min(
                data.count, maximumScalarPreviewBytes, max(0, budget.remainingBytes))
            guard budget.consume(bytes: available) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "decimal128",
                        binaryRepresentation: Data(data.prefix(available)),
                        attributes: data.count == available
                            ? []
                            : [
                                DatabaseStringAttribute(
                                    name: "byteCount",
                                    value: String(data.count)),
                                DatabaseStringAttribute(name: "truncated", value: "true"),
                            ])),
                data.count != available
            )
        case let value as Timestamp:
            let seconds = UInt32(bitPattern: value.timestamp)
            let increment = UInt32(bitPattern: value.increment)
            let text = "\(seconds):\(increment)"
            guard budget.consume(bytes: text.utf8.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "timestamp",
                        textRepresentation: text,
                        attributes: [
                            DatabaseStringAttribute(
                                name: "seconds",
                                value: String(seconds)),
                            DatabaseStringAttribute(
                                name: "increment",
                                value: String(increment)),
                        ])),
                false
            )
        case let value as RegularExpression:
            let pattern = preview(
                value.pattern,
                byteLimit: min(max(0, budget.remainingBytes), maximumScalarPreviewBytes))
            guard budget.consume(bytes: pattern.text.utf8.count + value.options.utf8.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (
                .productSpecific(
                    DatabaseProductValue(
                        product: .mongoDB,
                        typeName: "regularExpression",
                        textRepresentation: pattern.text,
                        attributes: [
                            DatabaseStringAttribute(name: "options", value: value.options),
                            DatabaseStringAttribute(
                                name: "truncated",
                                value: pattern.truncated ? "true" : "false"),
                        ])),
                pattern.truncated
            )
        case let value as JavaScriptCode:
            return try outputCode(value.code, typeName: "javascript", budget: &budget)
        case let value as JavaScriptCodeWithScope:
            let output = try outputCode(
                value.code,
                typeName: "javascriptWithScope",
                budget: &budget)
            return (output.value, true)
        case is MinKey:
            return (
                .productSpecific(
                    DatabaseProductValue(product: .mongoDB, typeName: "minKey")),
                false
            )
        case is MaxKey:
            return (
                .productSpecific(
                    DatabaseProductValue(product: .mongoDB, typeName: "maxKey")),
                false
            )
        case let value as Document:
            if value.isArray {
                var values: [DatabaseValue] = []
                values.reserveCapacity(min(value.count, 512))
                var truncated = false
                for (_, primitive) in value {
                    guard budget.remainingElements > 0, budget.remainingBytes > 0 else {
                        truncated = true
                        break
                    }
                    let converted = try outputValue(
                        primitive,
                        depth: depth + 1,
                        budget: &budget)
                    values.append(converted.value)
                    truncated = truncated || converted.truncated
                }
                return (.array(values), truncated)
            }
            var fields: [DatabaseObjectField] = []
            fields.reserveCapacity(min(value.count, 512))
            var seen = Set<String>()
            var truncated = false
            for (name, primitive) in value {
                try validateFieldName(name)
                guard seen.insert(name).inserted else {
                    throw MongoDBDatabaseValueCodecFailure.invalidValue
                }
                guard fields.count < 512,
                    budget.consume(bytes: name.utf8.count, elements: 1)
                else {
                    truncated = true
                    break
                }
                let converted = try outputValue(
                    primitive,
                    depth: depth + 1,
                    budget: &budget)
                fields.append(DatabaseObjectField(name: name, value: converted.value))
                truncated = truncated || converted.truncated
            }
            return (.object(fields), truncated)
        default:
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        }
    }

    private static func outputBinary(
        _ value: Binary,
        budget: inout MongoDBDatabaseValueCodecBudget
    ) throws -> (value: DatabaseValue, truncated: Bool) {
        let data = value.data
        if case .uuid = value.subType, data.count == 16 {
            let bytes = [UInt8](data)
            let uuid = UUID(
                uuid: (
                    bytes[0], bytes[1], bytes[2], bytes[3],
                    bytes[4], bytes[5], bytes[6], bytes[7],
                    bytes[8], bytes[9], bytes[10], bytes[11],
                    bytes[12], bytes[13], bytes[14], bytes[15]
                ))
            guard budget.consume(bytes: data.count) else {
                throw MongoDBDatabaseValueCodecFailure.resourceLimit
            }
            return (.uuid(uuid), false)
        }
        let available = min(data.count, maximumScalarPreviewBytes, max(0, budget.remainingBytes))
        guard budget.consume(bytes: available) else {
            throw MongoDBDatabaseValueCodecFailure.resourceLimit
        }
        let mediaType = "application/vnd.mongodb.binary; subtype=\(binarySubtype(value.subType))"
        if available == data.count {
            return (
                .binary(.complete(data: data, mediaType: mediaType, digest: nil)),
                false
            )
        }
        return (
            .binary(
                .preview(
                    byteCount: UInt64(data.count),
                    bytes: Data(data.prefix(available)),
                    mediaType: mediaType,
                    digest: nil)),
            true
        )
    }

    private static func outputCode(
        _ code: String,
        typeName: String,
        budget: inout MongoDBDatabaseValueCodecBudget
    ) throws -> (value: DatabaseValue, truncated: Bool) {
        let preview = preview(
            code,
            byteLimit: min(max(0, budget.remainingBytes), maximumScalarPreviewBytes))
        guard budget.consume(bytes: preview.text.utf8.count) else {
            throw MongoDBDatabaseValueCodecFailure.resourceLimit
        }
        return (
            .productSpecific(
                DatabaseProductValue(
                    product: .mongoDB,
                    typeName: typeName,
                    textRepresentation: preview.text,
                    attributes: [
                        DatabaseStringAttribute(name: "executable", value: "false"),
                        DatabaseStringAttribute(
                            name: "truncated",
                            value: preview.truncated ? "true" : "false"),
                    ])),
            preview.truncated
        )
    }

    private static func preview(
        _ value: String,
        byteLimit: Int
    ) -> (text: String, truncated: Bool) {
        guard value.utf8.count > byteLimit else { return (value, false) }
        guard byteLimit > 0 else { return ("", true) }
        var result = ""
        result.reserveCapacity(byteLimit)
        var used = 0
        for character in value {
            let count = String(character).utf8.count
            guard used + count <= byteLimit else { break }
            result.append(character)
            used += count
        }
        return (result, true)
    }

    private static func binary(data: Data, subtype: Binary.SubType) -> Binary {
        var buffer = ByteBufferAllocator().buffer(capacity: data.count)
        buffer.writeBytes(data)
        return Binary(subType: subtype, buffer: buffer)
    }

    private static func binarySubtype(_ subtype: Binary.SubType) -> String {
        switch subtype {
        case .generic:
            "generic"
        case .function:
            "function"
        case .uuid:
            "uuid"
        case .md5:
            "md5"
        case let .userDefined(value):
            "user-\(value)"
        }
    }

    private static func parseTimestamp(_ text: String) -> Date? {
        guard text.utf8.count <= 128 else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.date(from: text)
            ?? ISO8601DateFormatter().date(from: text)
    }

    private static func timestampText(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func validateFieldName(_ name: String) throws {
        guard !name.isEmpty,
            name.utf8.count <= 1_024,
            !name.contains("\0"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        }
    }

    private static func validateQueryKey(_ name: String) throws {
        guard !name.isEmpty,
            name.utf8.count <= 1_024,
            !name.contains("\0"),
            !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw MongoDBDatabaseValueCodecFailure.invalidValue
        }
    }
}

private struct MongoDBDatabaseValueCodecBudget {
    private(set) var remainingBytes: Int
    private(set) var remainingElements: Int

    mutating func consume(bytes: Int = 0, elements: Int = 0) -> Bool {
        guard bytes >= 0,
            elements >= 0,
            bytes <= remainingBytes,
            elements <= remainingElements
        else {
            return false
        }
        remainingBytes -= bytes
        remainingElements -= elements
        return true
    }
}
