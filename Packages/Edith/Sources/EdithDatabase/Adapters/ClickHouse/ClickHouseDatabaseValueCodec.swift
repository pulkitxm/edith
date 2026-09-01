import Foundation

enum ClickHouseDatabaseValueCodecFailure: Error, Equatable, Sendable {
    case invalidResponse
    case responseTooLarge
}

struct ClickHouseDatabaseDecodedCell: Equatable, Sendable {
    let value: DatabaseValue
    let parameterText: String?
}

struct ClickHouseDatabaseDecodedRow: Equatable, Sendable {
    let cells: [ClickHouseDatabaseDecodedCell]
}

struct ClickHouseDatabaseTabularResult: Equatable, Sendable {
    let names: [String]
    let types: [String]
    let fields: [DatabaseFieldDescriptor]
    let rows: [ClickHouseDatabaseDecodedRow]
}

enum ClickHouseDatabaseValueCodec {
    static let maximumBodyBytes = DatabaseAdapterBounds.maximumPageBytes
    static let maximumColumns = DatabaseAdapterBounds.maximumPageFields
    static let maximumRows = DatabaseAdapterBounds.maximumPageRecords + 1
    static let maximumNameBytes = 1_024
    static let maximumTypeBytes = 2_048
    static let maximumTextBytes = 1_048_576
    static let maximumPreviewBytes = 65_536
    static let maximumCollectionElements = 4_096
    static let maximumDepth = 16

    static func decode(_ body: Data) throws -> ClickHouseDatabaseTabularResult {
        guard body.count <= maximumBodyBytes else {
            throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
        }
        let lines = body.split(separator: 0x0A, omittingEmptySubsequences: true)
        guard lines.count >= 2,
            lines.count <= maximumRows + 2,
            let names = try decodeLine(lines[0]) as? [Any],
            let types = try decodeLine(lines[1]) as? [Any]
        else {
            throw ClickHouseDatabaseValueCodecFailure.invalidResponse
        }
        let decodedNames = try strings(names, maximumBytes: maximumNameBytes)
        let decodedTypes = try strings(types, maximumBytes: maximumTypeBytes)
        guard !decodedNames.isEmpty,
            decodedNames.count <= maximumColumns,
            decodedNames.count == decodedTypes.count,
            Set(decodedNames).count == decodedNames.count
        else {
            throw ClickHouseDatabaseValueCodecFailure.invalidResponse
        }
        let fields = try zip(decodedNames, decodedTypes).map { name, type in
            guard !name.isEmpty, !type.isEmpty else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return DatabaseFieldDescriptor(
                path: DatabaseFieldPath(name),
                displayName: name,
                typeName: type,
                isNullable: nullable(type),
                isSortable: true,
                isFilterable: true)
        }
        let rows = try lines.dropFirst(2).map { line in
            guard let rawValues = try decodeLine(line) as? [Any],
                rawValues.count == decodedTypes.count
            else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedRow(
                cells: try zip(rawValues, decodedTypes).map { rawValue, type in
                    try decode(rawValue, type: type, depth: 0)
                })
        }
        return ClickHouseDatabaseTabularResult(
            names: decodedNames,
            types: decodedTypes,
            fields: fields,
            rows: rows)
    }

    static func record(
        _ row: ClickHouseDatabaseDecodedRow,
        names: [String],
        identity: DatabaseRecordIdentity? = nil,
        metadata: [DatabaseStringAttribute] = []
    ) throws -> DatabaseRecord {
        guard row.cells.count == names.count else {
            throw ClickHouseDatabaseValueCodecFailure.invalidResponse
        }
        return DatabaseRecord(
            identity: identity,
            fields: zip(names, row.cells).map {
                DatabaseObjectField(name: $0.0, value: $0.1.value)
            },
            metadata: metadata)
    }

    private static func decodeLine(_ line: Data.SubSequence) throws -> Any {
        do {
            return try JSONSerialization.jsonObject(
                with: Data(line),
                options: [.fragmentsAllowed])
        } catch {
            throw ClickHouseDatabaseValueCodecFailure.invalidResponse
        }
    }

    private static func strings(
        _ values: [Any],
        maximumBytes: Int
    ) throws -> [String] {
        try values.map { value in
            guard let value = value as? String,
                value.utf8.count <= maximumBytes,
                !value.contains("\0")
            else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return value
        }
    }

    private static func decode(
        _ rawValue: Any,
        type: String,
        depth: Int
    ) throws -> ClickHouseDatabaseDecodedCell {
        guard depth <= maximumDepth else {
            throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
        }
        if let nested = nestedType(type, wrapper: "Nullable") {
            if rawValue is NSNull {
                return ClickHouseDatabaseDecodedCell(value: .null, parameterText: nil)
            }
            return try decode(rawValue, type: nested, depth: depth + 1)
        }
        guard !(rawValue is NSNull) else {
            throw ClickHouseDatabaseValueCodecFailure.invalidResponse
        }
        if let nested = nestedType(type, wrapper: "LowCardinality") {
            return try decode(rawValue, type: nested, depth: depth + 1)
        }
        if let nested = nestedType(type, wrapper: "Array") {
            guard let values = rawValue as? [Any],
                values.count <= maximumCollectionElements
            else {
                throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
            }
            let cells = try values.map {
                try decode($0, type: nested, depth: depth + 1)
            }
            return ClickHouseDatabaseDecodedCell(
                value: .array(cells.map(\.value)),
                parameterText: serializedParameter(rawValue))
        }
        return try decodePrimitive(rawValue, type: type, depth: depth)
    }

    private static func decodePrimitive(
        _ rawValue: Any,
        type: String,
        depth: Int
    ) throws -> ClickHouseDatabaseDecodedCell {
        if type == "Bool" {
            guard let value = boolean(rawValue) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(
                value: .boolean(value),
                parameterText: value ? "1" : "0")
        }
        if type.hasPrefix("UInt") {
            guard let text = scalarText(rawValue), let value = UInt64(text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(
                value: .unsignedInteger(value),
                parameterText: text)
        }
        if type.hasPrefix("Int") {
            guard let text = scalarText(rawValue), let value = Int64(text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(
                value: .signedInteger(value),
                parameterText: text)
        }
        if type.hasPrefix("Decimal") {
            guard let text = scalarText(rawValue), validDecimal(text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(
                value: .decimal(DatabaseDecimalValue(rawValue: text)),
                parameterText: text)
        }
        if type.hasPrefix("Float") {
            guard let text = scalarText(rawValue), let value = Double(text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(
                value: .floatingPoint(value),
                parameterText: text)
        }
        if type == "UUID" {
            guard let text = rawValue as? String, let value = UUID(uuidString: text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return ClickHouseDatabaseDecodedCell(value: .uuid(value), parameterText: text)
        }
        if type == "Date" || type == "Date32" {
            let text = try boundedString(rawValue)
            return ClickHouseDatabaseDecodedCell(
                value: .date(DatabaseDateValue(text: text)),
                parameterText: text)
        }
        if type.hasPrefix("DateTime") {
            let text = try boundedString(rawValue)
            return ClickHouseDatabaseDecodedCell(
                value: .timestamp(
                    DatabaseTimestampValue(
                        text: text,
                        timeZoneIdentifier: timeZone(type),
                        precision: precision(type))),
                parameterText: text)
        }
        if stringType(type) {
            let text = try boundedString(rawValue)
            return ClickHouseDatabaseDecodedCell(
                value: textValue(text, type: type),
                parameterText: text.utf8.count <= maximumTextBytes ? text : nil)
        }
        return ClickHouseDatabaseDecodedCell(
            value: try genericValue(rawValue, type: type, depth: depth + 1),
            parameterText: serializedParameter(rawValue))
    }

    private static func genericValue(
        _ rawValue: Any,
        type: String,
        depth: Int
    ) throws -> DatabaseValue {
        guard depth <= maximumDepth else {
            throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
        }
        if let value = rawValue as? String {
            return textValue(value, type: type)
        }
        if let value = rawValue as? NSNumber {
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return .boolean(value.boolValue)
            }
            let text = value.stringValue
            if let integer = Int64(text) {
                return .signedInteger(integer)
            }
            guard let floatingPoint = Double(text) else {
                throw ClickHouseDatabaseValueCodecFailure.invalidResponse
            }
            return .floatingPoint(floatingPoint)
        }
        if let value = rawValue as? Bool {
            return .boolean(value)
        }
        if let values = rawValue as? [Any] {
            guard values.count <= maximumCollectionElements else {
                throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
            }
            return .array(
                try values.map {
                    try genericValue($0, type: type, depth: depth + 1)
                })
        }
        if let values = rawValue as? [String: Any] {
            guard values.count <= maximumCollectionElements else {
                throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
            }
            return .object(
                try values.keys.sorted().map { key in
                    guard key.utf8.count <= maximumNameBytes, !key.contains("\0"),
                        let value = values[key]
                    else {
                        throw ClickHouseDatabaseValueCodecFailure.invalidResponse
                    }
                    return DatabaseObjectField(
                        name: key,
                        value: try genericValue(value, type: type, depth: depth + 1))
                })
        }
        throw ClickHouseDatabaseValueCodecFailure.invalidResponse
    }

    private static func scalarText(_ value: Any) -> String? {
        if let value = value as? String {
            return value
        }
        guard let number = value as? NSNumber,
            CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        return number.stringValue
    }

    private static func boundedString(_ value: Any) throws -> String {
        guard let value = value as? String,
            value.utf8.count <= maximumTextBytes,
            !value.contains("\0")
        else {
            throw ClickHouseDatabaseValueCodecFailure.responseTooLarge
        }
        return value
    }

    private static func textValue(_ value: String, type: String) -> DatabaseValue {
        guard value.utf8.count > maximumPreviewBytes else {
            return .string(value)
        }
        let preview = String(decoding: value.utf8.prefix(maximumPreviewBytes), as: UTF8.self)
        return .productSpecific(
            DatabaseProductValue(
                product: .clickHouse,
                typeName: type,
                textRepresentation: preview,
                attributes: [
                    DatabaseStringAttribute(name: "byteCount", value: String(value.utf8.count)),
                    DatabaseStringAttribute(name: "truncated", value: "true"),
                ]))
    }

    private static func serializedParameter(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
            let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            data.count <= maximumTextBytes
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func boolean(_ value: Any) -> Bool? {
        if let number = value as? NSNumber,
            CFGetTypeID(number) == CFBooleanGetTypeID()
        {
            return number.boolValue
        }
        guard let text = scalarText(value) else { return nil }
        switch text {
        case "0":
            return false
        case "1":
            return true
        default:
            return nil
        }
    }

    private static func validDecimal(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 256 else { return false }
        var index = value.startIndex
        if value[index] == "+" || value[index] == "-" {
            index = value.index(after: index)
        }
        guard index < value.endIndex else { return false }
        var digits = 0
        var decimalPoints = 0
        while index < value.endIndex {
            let character = value[index]
            if character.isNumber {
                digits += 1
            } else if character == "." {
                decimalPoints += 1
                guard decimalPoints == 1 else { return false }
            } else {
                return false
            }
            index = value.index(after: index)
        }
        return digits > 0
    }

    private static func stringType(_ type: String) -> Bool {
        type == "String" || type.hasPrefix("FixedString(")
            || type.hasPrefix("Enum8(") || type.hasPrefix("Enum16(")
            || type == "IPv4" || type == "IPv6"
    }

    private static func nestedType(_ type: String, wrapper: String) -> String? {
        let prefix = "\(wrapper)("
        guard type.hasPrefix(prefix), type.hasSuffix(")") else { return nil }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(before: type.endIndex)
        guard start < end else { return nil }
        return String(type[start..<end])
    }

    private static func nullable(_ type: String) -> Bool {
        nestedType(type, wrapper: "Nullable") != nil
    }

    private static func precision(_ type: String) -> Int? {
        guard type.hasPrefix("DateTime64("),
            let opening = type.firstIndex(of: "("),
            let closing = type[opening...].firstIndex(where: { $0 == "," || $0 == ")" })
        else {
            return nil
        }
        return Int(type[type.index(after: opening)..<closing])
    }

    private static func timeZone(_ type: String) -> String? {
        guard let firstQuote = type.firstIndex(of: "'"),
            let secondQuote = type[type.index(after: firstQuote)...].firstIndex(of: "'")
        else {
            return nil
        }
        let value = String(type[type.index(after: firstQuote)..<secondQuote])
        return value.utf8.count <= 256 ? value : nil
    }
}
