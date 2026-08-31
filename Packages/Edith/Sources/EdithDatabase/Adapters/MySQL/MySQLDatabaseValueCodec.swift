import Foundation
import MySQLNIO
import NIOCore

enum MySQLDatabaseValueCodec {
    static let maximumInlineBytes = 65_536

    static func bind(_ value: MySQLDatabaseBind) throws -> MySQLData {
        switch value {
        case .null:
            return .null
        case .boolean(let value):
            return MySQLData(bool: value)
        case .signedInteger(let value):
            var buffer = ByteBufferAllocator().buffer(capacity: 8)
            buffer.writeInteger(value, endianness: .little)
            return MySQLData(type: .longlong, buffer: buffer)
        case .unsignedInteger(let value):
            var buffer = ByteBufferAllocator().buffer(capacity: 8)
            buffer.writeInteger(value, endianness: .little)
            return MySQLData(type: .longlong, buffer: buffer, isUnsigned: true)
        case .decimal(let value), .string(let value):
            return MySQLData(string: value)
        case .floatingPoint(let value):
            guard value.isFinite else { throw MySQLDatabaseDriverFailure.configuration }
            return MySQLData(double: value)
        case .binary(let value):
            var buffer = ByteBufferAllocator().buffer(capacity: value.count)
            buffer.writeBytes(value)
            return MySQLData(type: .blob, buffer: buffer)
        }
    }

    static func result(_ rows: [MySQLRow]) throws -> MySQLDatabaseReadResult {
        guard let first = rows.first else {
            return MySQLDatabaseReadResult(columns: [], rows: [])
        }
        let columns = try normalizedColumns(first.columnDefinitions)
        let decodedRows = try rows.map { row in
            guard row.columnDefinitions.count == columns.count, row.values.count == columns.count
            else {
                throw MySQLDatabaseDriverFailure.server(nil)
            }
            return MySQLDatabaseReadRow(
                values: try zip(row.columnDefinitions, row.values).map { column, buffer in
                    try value(
                        MySQLData(
                            type: column.columnType,
                            format: row.format,
                            buffer: buffer,
                            isUnsigned: column.flags.contains(.COLUMN_UNSIGNED)),
                        column: column)
                })
        }
        return MySQLDatabaseReadResult(columns: columns, rows: decodedRows)
    }

    private static func normalizedColumns(
        _ definitions: [MySQLProtocol.ColumnDefinition41]
    ) throws -> [MySQLDatabaseReadColumn] {
        guard !definitions.isEmpty,
            definitions.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw MySQLDatabaseDriverFailure.resourceLimit
        }
        var names: [String: Int] = [:]
        return try definitions.map { column in
            guard validName(column.name) else { throw MySQLDatabaseDriverFailure.server(nil) }
            let occurrence = names[column.name, default: 0] + 1
            names[column.name] = occurrence
            let name = occurrence == 1 ? column.name : "\(column.name) #\(occurrence)"
            return MySQLDatabaseReadColumn(
                name: name,
                typeName: typeName(column),
                isNullable: !column.flags.contains(.COLUMN_NOT_NULL),
                isPrimaryKey: column.flags.contains(.PRIMARY_KEY))
        }
    }

    private static func value(
        _ data: MySQLData,
        column: MySQLProtocol.ColumnDefinition41
    ) throws -> DatabaseValue {
        guard data.buffer != nil else { return .null }
        switch column.columnType {
        case .tiny where column.columnLength == 1:
            guard let value = data.bool else { throw MySQLDatabaseDriverFailure.server(nil) }
            return .boolean(value)
        case .tiny, .short, .long, .longlong, .int24, .year, .bit:
            if data.isUnsigned {
                guard let value = data.uint64 else {
                    throw MySQLDatabaseDriverFailure.server(nil)
                }
                return .unsignedInteger(value)
            }
            guard let value = data.int64 else { throw MySQLDatabaseDriverFailure.server(nil) }
            return .signedInteger(value)
        case .decimal, .newdecimal:
            let value: String?
            if let string = data.string {
                value = string
            } else {
                value = String(data: try rawBytes(data), encoding: .utf8)
            }
            guard let value, validDecimal(value) else {
                throw MySQLDatabaseDriverFailure.server(nil)
            }
            return .decimal(DatabaseDecimalValue(rawValue: value))
        case .float, .double:
            guard let value = data.double, value.isFinite else {
                throw MySQLDatabaseDriverFailure.server(nil)
            }
            return .floatingPoint(value)
        case .date, .newdate:
            return .date(DatabaseDateValue(text: try dateText(data)))
        case .time, .time2:
            return .time(DatabaseTimeValue(text: try timeText(data)))
        case .datetime, .datetime2, .timestamp, .timestamp2:
            return .timestamp(DatabaseTimestampValue(text: try timestampText(data)))
        case .json:
            guard let value = String(data: try rawBytes(data), encoding: .utf8) else {
                throw MySQLDatabaseDriverFailure.server(nil)
            }
            return try productText(data, typeName: "JSON", fallback: value)
        case .geometry:
            return try productBinary(data, typeName: "GEOMETRY")
        case .blob, .tinyBlob, .mediumBlob,
            .longBlob where column.characterSet == .binary:
            return try binary(data)
        case .varchar, .varString, .string, .enum, .set, .blob, .tinyBlob, .mediumBlob,
            .longBlob:
            guard let value = data.string else { throw MySQLDatabaseDriverFailure.server(nil) }
            return boundedString(value, typeName: typeName(column))
        case .null:
            return .null
        default:
            if let value = data.string {
                return try productText(data, typeName: typeName(column), fallback: value)
            }
            return try productBinary(data, typeName: typeName(column))
        }
    }

    private static func boundedString(_ value: String, typeName: String) -> DatabaseValue {
        let bytes = Array(value.utf8)
        guard bytes.count > maximumInlineBytes else { return .string(value) }
        let prefix = String(decoding: bytes.prefix(maximumInlineBytes), as: UTF8.self)
        return .productSpecific(
            DatabaseProductValue(
                product: .mysql,
                typeName: typeName,
                textRepresentation: prefix,
                attributes: [
                    DatabaseStringAttribute(name: "byteCount", value: String(bytes.count)),
                    DatabaseStringAttribute(name: "truncated", value: "true"),
                ]))
    }

    private static func binary(_ data: MySQLData) throws -> DatabaseValue {
        let bytes = try rawBytes(data)
        if bytes.count <= maximumInlineBytes {
            return .binary(.complete(data: bytes, mediaType: nil, digest: nil))
        }
        return .binary(
            .preview(
                byteCount: UInt64(bytes.count),
                bytes: bytes.prefix(maximumInlineBytes),
                mediaType: nil,
                digest: nil))
    }

    private static func productText(
        _ data: MySQLData,
        typeName: String,
        fallback: String? = nil
    ) throws -> DatabaseValue {
        guard let text = fallback ?? data.string else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        let bounded = boundedString(text, typeName: typeName)
        if case .string(let value) = bounded {
            return .productSpecific(
                DatabaseProductValue(
                    product: .mysql,
                    typeName: typeName,
                    textRepresentation: value))
        }
        return bounded
    }

    private static func productBinary(
        _ data: MySQLData,
        typeName: String
    ) throws -> DatabaseValue {
        let bytes = try rawBytes(data)
        return .productSpecific(
            DatabaseProductValue(
                product: .mysql,
                typeName: typeName,
                binaryRepresentation: Data(bytes.prefix(maximumInlineBytes)),
                attributes: bytes.count > maximumInlineBytes
                    ? [
                        DatabaseStringAttribute(name: "byteCount", value: String(bytes.count)),
                        DatabaseStringAttribute(name: "truncated", value: "true"),
                    ] : []))
    }

    private static func rawBytes(_ data: MySQLData) throws -> Data {
        guard let buffer = data.buffer else { throw MySQLDatabaseDriverFailure.server(nil) }
        return Data(buffer.readableBytesView)
    }

    private static func dateText(_ data: MySQLData) throws -> String {
        guard let value = mysqlTime(data), let year = value.year, let month = value.month,
            let day = value.day
        else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func timeText(_ data: MySQLData) throws -> String {
        guard let value = mysqlTime(data) else {
            throw MySQLDatabaseDriverFailure.server(nil)
        }
        let hour = value.hour ?? 0
        let minute = value.minute ?? 0
        let second = value.second ?? 0
        let base = String(format: "%02d:%02d:%02d", hour, minute, second)
        guard let microsecond = value.microsecond, microsecond > 0 else { return base }
        return base + String(format: ".%06d", microsecond)
    }

    private static func timestampText(_ data: MySQLData) throws -> String {
        try dateText(data) + " " + timeText(data)
    }

    private static func mysqlTime(_ data: MySQLData) -> MySQLTime? {
        if let value = data.time { return value }
        let type: MySQLProtocol.DataType
        switch data.type {
        case .newdate:
            type = .date
        case .timestamp2:
            type = .timestamp
        case .datetime2:
            type = .datetime
        case .time2:
            type = .time
        default:
            return nil
        }
        return MySQLData(
            type: type,
            format: data.format,
            buffer: data.buffer,
            isUnsigned: data.isUnsigned
        ).time
    }

    private static func typeName(_ column: MySQLProtocol.ColumnDefinition41) -> String {
        var value = column.columnType.name.replacingOccurrences(of: "MYSQL_TYPE_", with: "")
        if column.flags.contains(.COLUMN_UNSIGNED) {
            value += " UNSIGNED"
        }
        return value
    }

    private static func validName(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4_096 && !value.contains("\0")
    }

    private static func validDecimal(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 1_024 else { return false }
        var seenDigit = false
        for character in value {
            if character.isNumber {
                seenDigit = true
            } else if !["+", "-", ".", "e", "E"].contains(character) {
                return false
            }
        }
        return seenDigit
    }
}
