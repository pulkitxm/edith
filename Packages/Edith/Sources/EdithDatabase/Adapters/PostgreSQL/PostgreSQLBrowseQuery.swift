import Foundation

enum PostgreSQLBrowseQuery {
    static func render(_ sql: String, parameters: [DatabaseValue]) throws -> String {
        var result = ""
        var index = sql.startIndex
        var quote: Character?
        while index < sql.endIndex {
            let character = sql[index]
            if let delimiter = quote {
                result.append(character)
                index = sql.index(after: index)
                if character == delimiter {
                    if index < sql.endIndex, sql[index] == delimiter {
                        result.append(sql[index])
                        index = sql.index(after: index)
                    } else {
                        quote = nil
                    }
                }
            } else if character == "'" || character == "\"" {
                quote = character
                result.append(character)
                index = sql.index(after: index)
            } else if character == "$" {
                let start = sql.index(after: index)
                var end = start
                while end < sql.endIndex, sql[end].isNumber { end = sql.index(after: end) }
                guard let number = Int(sql[start..<end]), parameters.indices.contains(number - 1)
                else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidRead
                }
                result += try literal(parameters[number - 1])
                index = end
            } else {
                result.append(character)
                index = sql.index(after: index)
            }
        }
        return result
    }

    private static func literal(_ value: DatabaseValue) throws -> String {
        switch value {
        case .null: return "NULL"
        case .boolean(let value): return value ? "TRUE" : "FALSE"
        case .signedInteger(let value): return String(value)
        case .unsignedInteger(let value): return String(value)
        case .decimal(let value): return value.rawValue
        case .floatingPoint(let value): return String(value)
        case .string(let value): return string(value)
        case .uuid(let value): return string(value.uuidString) + "::uuid"
        case .date(let value): return string(value.text) + "::date"
        case .time(let value):
            return string(value.text) + (value.timeZoneOffsetMinutes == nil ? "::time" : "::timetz")
        case .timestamp(let value):
            return string(value.text)
                + (value.timeZoneIdentifier == nil && value.timeZoneOffsetMinutes == nil
                    ? "::timestamp" : "::timestamptz")
        case .binary(let value):
            return "decode("
                + string(value.availableBytes.map { String(format: "%02x", $0) }.joined())
                + ", 'hex')"
        default: throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
    }

    private static func string(_ value: String) -> String {
        let parts = value.components(separatedBy: "\\").map {
            "'" + $0.replacingOccurrences(of: "'", with: "''") + "'"
        }
        return parts.count == 1 ? parts[0] : "(" + parts.joined(separator: " || chr(92) || ") + ")"
    }
}
