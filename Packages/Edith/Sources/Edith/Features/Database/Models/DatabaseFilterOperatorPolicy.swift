import EdithDatabase

enum DatabaseFilterFieldKind: Equatable {
    case analyzedText
    case text
    case identifier
    case boolean
    case number
    case temporal
    case structured
    case unknown
}

struct DatabaseFilterOperatorPolicy {
    static func operators(
        product: DatabaseProduct,
        field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        switch product {
        case .redis, .valkey:
            return keyValueOperators(field)
        case .postgresql, .mysql, .mariaDB, .sqlite:
            return relationalOperators(field)
        case .mongoDB:
            return documentOperators(field)
        case .elasticsearch, .openSearch:
            return searchOperators(field)
        case .clickHouse:
            return analyticalOperators(field)
        }
    }

    static func defaultOperator(
        product: DatabaseProduct?,
        field: DatabaseFieldDescriptor
    ) -> DatabaseFilterOperator {
        guard let product else {
            return fieldKind(product: nil, typeName: field.typeName) == .text
                ? .contains : .equal
        }
        let available = operators(product: product, field: field)
        if available.contains(.fullText),
            fieldKind(product: product, typeName: field.typeName) == .analyzedText
        {
            return .fullText
        }
        if available.contains(.contains) {
            return .contains
        }
        return available.first ?? .equal
    }

    static func supportsCaseSensitivity(
        product: DatabaseProduct,
        field: DatabaseFieldDescriptor,
        operation: DatabaseFilterOperator
    ) -> Bool {
        let kind = fieldKind(product: product, typeName: field.typeName)
        switch product {
        case .redis, .valkey:
            return false
        case .postgresql, .mysql, .mariaDB, .sqlite, .mongoDB, .clickHouse:
            return kind == .text
                && [.contains, .startsWith, .endsWith].contains(operation)
        case .elasticsearch, .openSearch:
            return kind == .text
                && [
                    .equal, .notEqual, .contains, .startsWith, .endsWith,
                    .regularExpression,
                ].contains(operation)
        }
    }

    static func defaultCaseSensitivity(
        product: DatabaseProduct?,
        field: DatabaseFieldDescriptor?,
        operation: DatabaseFilterOperator
    ) -> DatabaseFilterCaseSensitivity {
        guard let product, let field,
            supportsCaseSensitivity(product: product, field: field, operation: operation)
        else {
            return .productDefault
        }
        switch operation {
        case .contains, .startsWith, .endsWith:
            return .insensitive
        default:
            return .productDefault
        }
    }

    static func supportsDisjunction(product: DatabaseProduct?) -> Bool {
        guard let product else { return true }
        return product != .redis && product != .valkey
    }

    static func title(
        product: DatabaseProduct,
        operation: DatabaseFilterOperator
    ) -> String {
        switch operation {
        case .equal: "Is"
        case .notEqual: "Is not"
        case .greaterThan: "Greater than"
        case .greaterThanOrEqual: "At least"
        case .lessThan: "Less than"
        case .lessThanOrEqual: "At most"
        case .contains:
            product.family == .relational ? "Contains (LIKE)" : "Contains"
        case .startsWith: "Starts with"
        case .endsWith: "Ends with"
        case .in: "In list"
        case .notIn: "Not in list"
        case .between: "Between"
        case .isNull: "Is null"
        case .isNotNull: "Is not null"
        case .isMissing:
            product.family == .search ? "Is absent or null" : "Is missing"
        case .isNotMissing:
            product.family == .search ? "Has indexed value" : "Is present"
        case .regularExpression: "Matches regex"
        case .fullText:
            product == .clickHouse ? "Contains token" : "Full-text match"
        }
    }

    private static let equality: [DatabaseFilterOperator] = [
        .equal, .notEqual, .in, .notIn,
    ]

    private static let ordered: [DatabaseFilterOperator] = [
        .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan,
        .lessThanOrEqual, .between, .in, .notIn,
    ]

    private static let text: [DatabaseFilterOperator] = [
        .contains, .equal, .notEqual, .startsWith, .endsWith, .greaterThan,
        .greaterThanOrEqual, .lessThan, .lessThanOrEqual, .between, .in, .notIn,
    ]

    private static func keyValueOperators(
        _ field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        field.typeName.lowercased() == "redis-type"
            ? [.equal] : [.equal, .contains, .startsWith, .endsWith]
    }

    private static func relationalOperators(
        _ field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        let base: [DatabaseFilterOperator]
        switch fieldKind(product: nil, typeName: field.typeName) {
        case .analyzedText, .text:
            base = text
        case .identifier, .boolean, .structured:
            base = equality
        case .number, .temporal, .unknown:
            base = ordered
        }
        return appendNullChecks(to: base, when: field.isNullable)
    }

    private static func documentOperators(
        _ field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        let base: [DatabaseFilterOperator]
        switch fieldKind(product: .mongoDB, typeName: field.typeName) {
        case .analyzedText, .text:
            base = text
        case .identifier, .number, .temporal:
            base = ordered
        case .boolean:
            base = equality
        case .structured, .unknown:
            base = []
        }
        return base + [.isNull, .isNotNull, .isMissing, .isNotMissing]
    }

    private static func searchOperators(
        _ field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        let presence: [DatabaseFilterOperator] = [.isMissing, .isNotMissing]
        switch fieldKind(product: .elasticsearch, typeName: field.typeName) {
        case .analyzedText:
            return [.fullText] + presence
        case .text:
            return [
                .equal, .notEqual, .contains, .startsWith, .endsWith, .in, .notIn,
                .regularExpression,
            ] + presence
        case .identifier, .number, .temporal:
            return ordered + presence
        case .boolean:
            return equality + presence
        case .structured, .unknown:
            return presence
        }
    }

    private static func analyticalOperators(
        _ field: DatabaseFieldDescriptor
    ) -> [DatabaseFilterOperator] {
        let base: [DatabaseFilterOperator]
        switch fieldKind(product: .clickHouse, typeName: field.typeName) {
        case .analyzedText, .text:
            base = text + [.regularExpression, .fullText]
        case .identifier, .number, .temporal:
            base = ordered
        case .boolean:
            base = equality
        case .structured, .unknown:
            base = []
        }
        return appendNullChecks(to: base, when: field.isNullable)
    }

    private static func appendNullChecks(
        to operators: [DatabaseFilterOperator],
        when nullable: Bool
    ) -> [DatabaseFilterOperator] {
        nullable ? operators + [.isNull, .isNotNull] : operators
    }

    private static func fieldKind(
        product: DatabaseProduct?,
        typeName: String
    ) -> DatabaseFilterFieldKind {
        var type = typeName.lowercased()
        for prefix in ["runtime:", "derived:"] where type.hasPrefix(prefix) {
            type.removeFirst(prefix.count)
        }
        if product == .elasticsearch || product == .openSearch {
            if ["text", "match_only_text", "search_as_you_type"].contains(type) {
                return .analyzedText
            }
            if ["keyword", "wildcard", "constant_keyword"].contains(type) {
                return .text
            }
            if [
                "object", "nested", "flattened", "geo_point", "geo_shape", "dense_vector",
                "sparse_vector", "rank_features", "completion", "binary",
            ].contains(type) {
                return .structured
            }
        }
        if type == "redis-type" {
            return .identifier
        }
        if type == "uuid" || type == "objectid" || type == "ip" || type == "version" {
            return .identifier
        }
        if type.contains("array") || type.contains("map") || type.contains("tuple")
            || type.contains("object") || type.contains("json") || type == "dynamic"
        {
            return .structured
        }
        if type.contains("bool") {
            return .boolean
        }
        if type.contains("timestamp") || type.contains("datetime") || type == "date"
            || type.hasPrefix("time") || type.contains("interval")
        {
            return .temporal
        }
        if type.contains("int") || type.contains("serial") || type.contains("numeric")
            || type.contains("decimal") || type.contains("float") || type.contains("double")
            || type.contains("real") || type.contains("number") || type.contains("money")
            || ["long", "short", "byte", "unsigned_long"].contains(type)
        {
            return .number
        }
        if type.contains("char") || type.contains("text") || type.contains("string")
            || type == "name" || type == "bytes"
        {
            return .text
        }
        return .unknown
    }
}
