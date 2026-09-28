import EdithDatabase
import Foundation

enum DatabaseDataWorkspaceState: Equatable, Sendable {
    case idle
    case loading
    case loaded
    case failed(String)
}

enum DatabaseRowEditorMode: Equatable, Sendable {
    case insert
    case update(recordIndex: Int)
}

enum DatabaseDataResultMode: Equatable, Sendable {
    case browse
    case query
}

enum DatabaseSearchQueryOperation: String, CaseIterable, Sendable {
    case search
    case aggregate

    var title: String {
        switch self {
        case .search: "Search"
        case .aggregate: "Aggregate"
        }
    }
}

enum DatabaseWorkspaceFilterConjunction: String, CaseIterable, Sendable {
    case and
    case or

    var title: String { rawValue.uppercased() }
}

struct DatabaseWorkspaceFilterClause: Identifiable, Equatable, Sendable {
    let id: UUID
    var field: String
    var operation: DatabaseFilterOperator
    var valueText: String
    var isEnabled: Bool
    var caseSensitivity: DatabaseFilterCaseSensitivity

    init(
        id: UUID = UUID(),
        field: String,
        operation: DatabaseFilterOperator,
        valueText: String = "",
        isEnabled: Bool = true,
        caseSensitivity: DatabaseFilterCaseSensitivity = .productDefault
    ) {
        self.id = id
        self.field = field
        self.operation = operation
        self.valueText = valueText
        self.isEnabled = isEnabled
        self.caseSensitivity = caseSensitivity
    }

    var summary: String {
        let normalizedField = field.trimmingCharacters(in: .whitespacesAndNewlines)
        let fieldTitle = normalizedField.isEmpty ? "Field" : normalizedField
        if Self.usesNoValue(operation) {
            return "\(fieldTitle) \(Self.title(operation))"
        }
        let normalizedValue = valueText.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedValue.isEmpty
            ? "\(fieldTitle) \(Self.title(operation))"
            : "\(fieldTitle) \(Self.title(operation)) \(normalizedValue)"
    }

    private static func usesNoValue(_ operation: DatabaseFilterOperator) -> Bool {
        switch operation {
        case .isNull, .isNotNull, .isMissing, .isNotMissing: true
        default: false
        }
    }

    private static func title(_ operation: DatabaseFilterOperator) -> String {
        switch operation {
        case .equal: "is"
        case .notEqual: "is not"
        case .greaterThan: "is greater than"
        case .greaterThanOrEqual: "is at least"
        case .lessThan: "is less than"
        case .lessThanOrEqual: "is at most"
        case .contains: "contains"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .in: "is in"
        case .notIn: "is not in"
        case .between: "is between"
        case .isNull: "is null"
        case .isNotNull: "is not null"
        case .isMissing: "is missing"
        case .isNotMissing: "is present"
        case .regularExpression: "matches"
        case .fullText: "matches text"
        }
    }
}

struct DatabaseWorkspaceSort: Identifiable, Equatable, Sendable {
    var id: String { field }
    let field: String
    let direction: DatabaseSortDirection

    var summary: String {
        "\(field) \(direction == .ascending ? "ascending" : "descending")"
    }
}

struct DatabaseRowFieldDraft: Identifiable, Equatable, Sendable {
    let id: String
    let typeName: String
    let originalValue: DatabaseValue?
    let isIdentity: Bool
    let isEditable: Bool
    var text: String
    var isIncluded: Bool
    var enumValues: [String]? = nil
    var isNullable: Bool = true
    var isNull: Bool = false
    var isGenerated: Bool = false
    var hasDefault: Bool = false
    var isJSON: Bool = false

    var choiceValues: [String]? {
        enumValues
            ?? (["bool", "boolean"].contains(typeName.lowercased()) ? ["true", "false"] : nil)
    }
}
