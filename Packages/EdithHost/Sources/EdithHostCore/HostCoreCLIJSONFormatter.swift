import Foundation

enum HostCoreCLIJSONFormatter {
    public static func string(_ value: HostCLIJSON, pretty: Bool = true) -> String {
        var out = ""
        write(value, into: &out, indent: 0, pretty: pretty)
        return out
    }

    private static func write(
        _ value: HostCLIJSON, into out: inout String, indent: Int, pretty: Bool
    ) {
        switch value {
        case .null:
            out += "null"
        case let .bool(flag):
            out += flag ? "true" : "false"
        case let .integer(number):
            out += String(number)
        case let .number(number):
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
        _ items: [HostCLIJSON], into out: inout String, indent: Int, pretty: Bool
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
        _ fields: [String: HostCLIJSON], into out: inout String, indent: Int, pretty: Bool
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
