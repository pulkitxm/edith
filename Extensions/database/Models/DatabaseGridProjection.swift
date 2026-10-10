import DatabaseCore
import Foundation

struct DatabaseGridProjection {
    static let rowCacheLimit = 128
    static let previewLimit = 512

    private(set) var fieldsByName: [String: DatabaseFieldDescriptor] = [:]
    private(set) var cachedRows: [Int: [String: DatabaseValue]] = [:]

    mutating func setFields(_ fields: [DatabaseFieldDescriptor]) {
        fieldsByName = Dictionary(
            fields.map { ($0.path.segments.joined(separator: "."), $0) },
            uniquingKeysWith: { first, _ in first })
    }

    mutating func invalidateRows() {
        cachedRows.removeAll(keepingCapacity: true)
    }

    mutating func value(named name: String, row: Int, records: [DatabaseRecord]) -> DatabaseValue {
        guard records.indices.contains(row) else { return .missing }
        if let values = cachedRows[row] { return values[name] ?? .missing }
        if cachedRows.count >= Self.rowCacheLimit { invalidateRows() }
        let values = Dictionary(
            records[row].fields.map { ($0.name, $0.value) },
            uniquingKeysWith: { first, _ in first })
        cachedRows[row] = values
        return values[name] ?? .missing
    }

    static func preview(_ value: String) -> String {
        let prefix = value.prefix(previewLimit + 1)
        let truncated = prefix.count > previewLimit
        let visible = truncated ? prefix.prefix(previewLimit - 1) : prefix
        let compact = visible.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        return truncated ? compact + "…" : compact
    }
}
