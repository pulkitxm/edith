import Foundation

public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static func number(_ value: Int64) -> JSONValue { .int(Int(value)) }

    public static func optional(_ value: String?) -> JSONValue {
        value.map { .string($0) } ?? .null
    }

    public static func optional(_ value: Double?) -> JSONValue {
        value.map { .double($0) } ?? .null
    }

    public static func optional(_ value: Int?) -> JSONValue {
        value.map { .int($0) } ?? .null
    }

    public static func date(_ value: Date?) -> JSONValue {
        guard let value else { return .null }
        return .string(JSONSerializer.iso.string(from: value))
    }

    public static func strings(_ values: [String]) -> JSONValue {
        .array(values.map { .string($0) })
    }

    public static func doubles(_ values: [Double]) -> JSONValue {
        .array(values.map { .double($0) })
    }
}

public enum JSONSerializer {
    public static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func string(_ value: JSONValue, pretty: Bool = true) -> String {
        var out = ""
        write(value, into: &out, indent: 0, pretty: pretty)
        return out
    }

    private static func write(_ value: JSONValue, into out: inout String, indent: Int, pretty: Bool)
    {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .int(number):
            out += String(number)
        case let .double(number):
            out += numberText(number)
        case let .string(text):
            out += quoted(text)
        case let .array(items):
            writeArray(items, into: &out, indent: indent, pretty: pretty)
        case let .object(fields):
            writeObject(fields, into: &out, indent: indent, pretty: pretty)
        }
    }

    private static func writeArray(
        _ items: [JSONValue], into out: inout String, indent: Int, pretty: Bool
    ) {
        guard !items.isEmpty else {
            out += "[]"
            return
        }
        let inner = indent + 1
        out += pretty ? "[\n" : "["
        for (offset, item) in items.enumerated() {
            if pretty { out += pad(inner) }
            write(item, into: &out, indent: inner, pretty: pretty)
            if offset < items.count - 1 { out += "," }
            if pretty { out += "\n" }
        }
        if pretty { out += pad(indent) }
        out += "]"
    }

    private static func writeObject(
        _ fields: [String: JSONValue], into out: inout String, indent: Int, pretty: Bool
    ) {
        guard !fields.isEmpty else {
            out += "{}"
            return
        }
        let keys = fields.keys.sorted()
        let inner = indent + 1
        out += pretty ? "{\n" : "{"
        for (offset, key) in keys.enumerated() {
            if pretty { out += pad(inner) }
            out += quoted(key)
            out += pretty ? ": " : ":"
            write(fields[key] ?? .null, into: &out, indent: inner, pretty: pretty)
            if offset < keys.count - 1 { out += "," }
            if pretty { out += "\n" }
        }
        if pretty { out += pad(indent) }
        out += "}"
    }

    private static func pad(_ level: Int) -> String {
        String(repeating: "  ", count: level)
    }

    private static func numberText(_ value: Double) -> String {
        guard value.isFinite else { return "null" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int64(value))
        }
        return String(value)
    }

    private static func quoted(_ text: String) -> String {
        var out = "\""
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out + "\""
    }
}
