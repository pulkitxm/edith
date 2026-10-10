import Foundation

public struct HostCLISetting: Codable, Equatable, Sendable {
    public enum ValueType: String, Codable, Sendable {
        case bool, int, number, string, csv, stringList, map
    }
    public let key: String
    public let type: ValueType
    public let group: String
    public let summary: String
    public let scope: String
    public let allowed: [String]
    public let minimum: Int64?
    public let maximum: Int64?
    public let fallback: HostCLIJSON
    public let readOnly: Bool

    public init(
        _ key: String, _ type: ValueType, group: String, summary: String,
        scope: String = "shared", allowed: [String] = [], minimum: Int64? = nil,
        maximum: Int64? = nil, fallback: HostCLIJSON = .null, readOnly: Bool = false
    ) {
        self.key = key; self.type = type; self.group = group; self.summary = summary
        self.scope = scope; self.allowed = allowed; self.minimum = minimum; self.maximum = maximum
        self.fallback = fallback; self.readOnly = readOnly
    }

    public func validate() throws {
        guard !key.isEmpty, key.utf8.count <= 128, !key.utf8.contains(0),
            !group.isEmpty, group.utf8.count <= 80, summary.utf8.count <= 4096,
            ["shared", "standard"].contains(scope), allowed.count <= 256,
            allowed.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
            minimum == nil || maximum == nil || minimum! <= maximum!,
            try fallback.encoded().count <= 65536
        else { throw HostCLIError.rejected("Invalid setting definition.") }
        if fallback != .null { _ = try coerce(fallback) }
    }

    public func parse(_ raw: String) throws -> HostCLIJSON {
        let value: HostCLIJSON
        switch type {
        case .bool:
            switch raw.lowercased() {
            case "true", "1", "yes", "on": value = .bool(true)
            case "false", "0", "no", "off": value = .bool(false)
            default: throw HostCLIError.usage("Expected true or false for \(key).")
            }
        case .int:
            guard let number = Int64(raw) else {
                throw HostCLIError.usage("Expected an integer for \(key).")
            }
            value = .integer(number)
        case .number:
            guard let number = Double(raw), number.isFinite else {
                throw HostCLIError.usage("Expected a finite number for \(key).")
            }
            value = .number(number)
        case .string, .csv: value = .string(raw)
        case .stringList:
            value = .strings(
                raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        case .map: value = try JSONDecoder().decode(HostCLIJSON.self, from: Data(raw.utf8))
        }
        return try coerce(value)
    }

    public func coerce(_ value: HostCLIJSON) throws -> HostCLIJSON {
        switch (type, value) {
        case (.bool, .bool), (.string, .string), (.csv, .string), (.map, .object): break
        case (.int, .integer(let number)):
            guard minimum.map({ number >= $0 }) ?? true, maximum.map({ number <= $0 }) ?? true
            else {
                throw HostCLIError.usage("\(key) is outside its allowed range.")
            }
        case (.number, .number(let number)):
            guard number.isFinite else { throw HostCLIError.usage("Expected a finite number.") }
        case (.number, .integer): break
        case (.stringList, .array(let values)):
            guard values.allSatisfy({ $0.string != nil }) else {
                throw HostCLIError.usage("Expected a list of strings.")
            }
        default: throw HostCLIError.usage("Invalid value for \(key).")
        }
        if !allowed.isEmpty, let string = value.string, !allowed.contains(string) {
            throw HostCLIError.usage("\(key) allows: " + allowed.joined(separator: ", "))
        }
        guard try value.encoded().count <= 65536 else {
            throw HostCLIError.usage("The setting exceeds its size limit.")
        }
        return value
    }

    public var schema: HostCLIJSON {
        var result: [String: HostCLIJSON] = [
            "description": .string(summary), "x-group": .string(group), "x-scope": .string(scope),
            "type": .string(
                type == .bool
                    ? "boolean"
                    : type == .int
                        ? "integer"
                        : type == .stringList
                            ? "array"
                            : type == .map ? "object" : type == .number ? "number" : "string"),
        ]
        if type == .csv { result["x-format"] = .string("comma-separated") }
        if type == .stringList { result["items"] = .object(["type": .string("string")]) }
        if !allowed.isEmpty { result["enum"] = .strings(allowed) }
        if let minimum { result["minimum"] = .integer(minimum) }
        if let maximum { result["maximum"] = .integer(maximum) }
        if fallback != .null { result["default"] = fallback }
        return .object(result)
    }
}
