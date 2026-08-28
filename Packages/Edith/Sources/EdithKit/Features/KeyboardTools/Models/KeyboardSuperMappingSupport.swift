import Foundation

public struct KeyboardSuperMapping: Equatable, Sendable {
    public let source: UInt64
    public let destination: UInt64

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

public enum KeyboardSuperMappingSupport {
    public static let property = "UserKeyMapping"

    public static var ownedMapping: KeyboardSuperMapping {
        KeyboardSuperMapping(
            source: KeyboardSuperState.capsLockUsage,
            destination: KeyboardSuperState.triggerUsage)
    }

    public static func desiredMappings(
        enabling: Bool, existing: [KeyboardSuperMapping], ownsMapping: Bool
    ) -> [KeyboardSuperMapping]? {
        let external = existing.filter { !ownsMapping || $0 != ownedMapping }
        guard enabling else { return external }
        guard !external.contains(where: { $0.source == ownedMapping.source }) else { return nil }
        return [ownedMapping] + external
    }

    public static func mappingArgument(_ mappings: [KeyboardSuperMapping]) -> String {
        let values = mappings.map {
            "{\"HIDKeyboardModifierMappingSrc\":\($0.source),\"HIDKeyboardModifierMappingDst\":\($0.destination)}"
        }
        return "{\"UserKeyMapping\":[\(values.joined(separator: ","))]}"
    }

    public static func parseMappings(_ report: String) -> [KeyboardSuperMapping] {
        var result: [KeyboardSuperMapping] = []
        for block in report.components(separatedBy: "{").dropFirst() {
            let body = block.components(separatedBy: "}").first ?? ""
            guard
                let source = number(after: "HIDKeyboardModifierMappingSrc", in: body),
                let destination = number(after: "HIDKeyboardModifierMappingDst", in: body)
            else { continue }
            let mapping = KeyboardSuperMapping(source: source, destination: destination)
            if !result.contains(mapping) { result.append(mapping) }
        }
        return result
    }

    public static func mappingTables(_ report: String) -> [[KeyboardSuperMapping]] {
        var tables: [[KeyboardSuperMapping]] = []
        var block = ""
        for line in report.components(separatedBy: .newlines) {
            let fields = line.trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace)
            if fields.count >= 2, fields[1] == property {
                if !block.isEmpty { tables.append(parseMappings(block)) }
                block = line
            } else if !block.isEmpty {
                block += "\n" + line
            }
        }
        if !block.isEmpty { tables.append(parseMappings(block)) }
        return tables
    }

    public static func consistentMappings(
        _ report: String, ownsMapping: Bool
    ) -> [KeyboardSuperMapping]? {
        let tables = mappingTables(report).map { mappings in
            mappings.filter { !ownsMapping || $0 != ownedMapping }
        }
        guard let first = tables.first,
            tables.dropFirst().allSatisfy({ mappingsMatch($0, first) })
        else { return nil }
        return first
    }

    public static func reportConfirms(
        _ report: String, expected: [KeyboardSuperMapping]
    ) -> Bool {
        let tables = mappingTables(report)
        return !tables.isEmpty && tables.allSatisfy { mappingsMatch($0, expected) }
    }

    private static func mappingsMatch(
        _ lhs: [KeyboardSuperMapping], _ rhs: [KeyboardSuperMapping]
    ) -> Bool {
        lhs.count == rhs.count && lhs.allSatisfy(rhs.contains)
    }

    private static func number(after field: String, in body: String) -> UInt64? {
        guard let range = body.range(of: field) else { return nil }
        let remaining = body[range.upperBound...].drop {
            $0 == " " || $0 == "=" || $0 == "\""
        }
        let token = remaining.prefix { $0.isNumber || $0 == "-" }
        if let value = UInt64(token) { return value }
        guard let value = Int64(token) else { return nil }
        return UInt64(bitPattern: value)
    }
}
