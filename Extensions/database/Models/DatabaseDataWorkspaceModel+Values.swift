import DatabaseCore
import Foundation

extension DatabaseDataWorkspaceModel {
    static func text(for value: DatabaseValue) -> String {
        switch value {
        case .missing: "missing"
        case .null: "null"
        case .boolean(let value): value ? "true" : "false"
        case .signedInteger(let value): value.formatted()
        case .unsignedInteger(let value): value.formatted()
        case .decimal(let value): value.rawValue
        case .floatingPoint(let value): value.formatted()
        case .string(let value): value
        case .binary(let value): "\(value.byteCount.formatted()) bytes"
        case .date(let value): value.text
        case .time(let value): value.text
        case .timestamp(let value): value.text
        case .uuid(let value): value.uuidString.lowercased()
        case .array(let values): "[\(values.count) values]"
        case .object(let fields): "{\(fields.count) fields}"
        case .productSpecific(let value): value.textRepresentation ?? value.typeName
        }
    }

    static func supportsEditing(_ value: DatabaseValue) -> Bool {
        switch value {
        case .missing, .binary, .array, .object, .productSpecific:
            false
        case .null, .boolean, .signedInteger, .unsignedInteger, .decimal, .floatingPoint,
            .string, .date, .time, .timestamp, .uuid:
            true
        }
    }

    static func supportsEditing(typeName: String) -> Bool {
        let type = typeName.lowercased()
        return !type.contains("bytea") && !type.contains("json") && !type.hasSuffix("[]")
    }

    static func value(from field: DatabaseRowFieldDraft) throws -> DatabaseValue {
        if field.isNull {
            guard field.isNullable else {
                throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
            }
            return .null
        }
        if field.isJSON {
            guard let data = field.text.data(using: .utf8),
                (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
            else { throw DatabaseRowEditorError.invalidValue(field.id, field.typeName) }
            return .string(field.text)
        }
        if let enumValues = field.enumValues {
            guard enumValues.contains(field.text) else {
                throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
            }
            return .string(field.text)
        }
        let trimmed = field.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let original = field.originalValue {
            switch original {
            case .boolean:
                guard let value = parseBoolean(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .boolean(value)
            case .signedInteger:
                guard let value = Int64(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .signedInteger(value)
            case .unsignedInteger:
                guard let value = UInt64(trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .unsignedInteger(value)
            case .decimal:
                return try decimalValue(trimmed, fieldName: field.id, typeName: field.typeName)
            case .floatingPoint:
                guard let value = Double(trimmed), value.isFinite else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .floatingPoint(value)
            case .string:
                return .string(field.text)
            case .date:
                return .date(DatabaseDateValue(text: trimmed))
            case .time:
                return .time(DatabaseTimeValue(text: trimmed))
            case .timestamp:
                return .timestamp(DatabaseTimestampValue(text: trimmed))
            case .uuid:
                guard let value = UUID(uuidString: trimmed) else {
                    throw DatabaseRowEditorError.invalidValue(field.id, field.typeName)
                }
                return .uuid(value)
            case .null:
                break
            case .missing, .binary, .array, .object, .productSpecific:
                throw DatabaseRowEditorError.unsupportedValue(field.id)
            }
        }
        return try value(from: field.text, typeName: field.typeName, fieldName: field.id)
    }

    static func value(from text: String, typeName: String, fieldName: String) throws
        -> DatabaseValue
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let type = typeName.lowercased()
        if type == "objectid" {
            guard isMongoDBObjectID(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .productSpecific(
                DatabaseProductValue(
                    product: .mongoDB, typeName: "objectId", textRepresentation: trimmed))
        }
        if type.contains("bool") {
            guard let value = parseBoolean(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .boolean(value)
        }
        if type == "unsigned_long" {
            guard let value = UInt64(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .unsignedInteger(value)
        }
        if ["long", "short", "byte"].contains(type) || type.contains("int")
            || type.contains("serial")
        {
            guard let value = Int64(trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .signedInteger(value)
        }
        if type.contains("numeric") || type.contains("decimal") {
            return try decimalValue(trimmed, fieldName: fieldName, typeName: typeName)
        }
        if type.contains("real") || type.contains("double")
            || ["float", "half_float", "scaled_float"].contains(type)
        {
            guard let value = Double(trimmed), value.isFinite else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .floatingPoint(value)
        }
        if type == "uuid" {
            guard let value = UUID(uuidString: trimmed) else {
                throw DatabaseRowEditorError.invalidValue(fieldName, typeName)
            }
            return .uuid(value)
        }
        if type.contains("timestamp") { return .timestamp(DatabaseTimestampValue(text: trimmed)) }
        if type == "date" { return .date(DatabaseDateValue(text: trimmed)) }
        if type.hasPrefix("time") { return .time(DatabaseTimeValue(text: trimmed)) }
        return .string(text)
    }

    private static func decimalValue(_ value: String, fieldName: String, typeName: String) throws
        -> DatabaseValue
    {
        guard
            value.range(
                of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
                options: .regularExpression) != nil
        else { throw DatabaseRowEditorError.invalidValue(fieldName, typeName) }
        return .decimal(DatabaseDecimalValue(rawValue: value))
    }

    static func isMongoDBObjectID(_ value: String) -> Bool {
        value.utf8.count == 24
            && value.utf8.allSatisfy { byte in
                switch byte {
                case 48...57, 65...70, 97...102: true
                default: false
                }
            }
    }

    private static func parseBoolean(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "t", "1", "yes": true
        case "false", "f", "0", "no": false
        default: nil
        }
    }
}

enum DatabaseDataWorkspaceInputError: Error {
    case invalidTarget(String)
    case invalidQuery(String)
    case invalidFilter(String)
}

enum DatabaseRowEditorError: Error {
    case notEditing
    case unsupportedDatabase
    case missingIdentity
    case changedIdentity
    case invalidValue(String, String)
    case unsupportedValue(String)
}
