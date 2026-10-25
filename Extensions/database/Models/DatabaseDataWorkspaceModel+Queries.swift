import DatabaseCore
import Foundation

extension DatabaseDataWorkspaceModel {
    func queryRequest(
        _ connection: DatabaseConnectionSummary, continuation: DatabaseContinuationToken?
    ) throws -> DatabaseQueryRequest {
        let text = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw DatabaseDataWorkspaceInputError.invalidQuery("Enter a query to run.")
        }
        let page = DatabasePageRequest(
            pageSize: try DatabasePageSize(pageSize), continuation: continuation)
        switch connection.product {
        case .postgresql, .mysql, .mariaDB, .sqlite, .clickHouse:
            return DatabaseQueryRequest(
                target: DatabaseTargetIdentifier(connectionID: connection.id),
                language: connection.product == .clickHouse ? .clickHouseSQL : .sql,
                command: text, page: page)
        case .redis, .valkey:
            let parts = text.split(
                maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard parts.count == 2 else {
                throw DatabaseDataWorkspaceInputError.invalidQuery(
                    "Enter a read command and key, such as GET session:1.")
            }
            return DatabaseQueryRequest(
                target: try target(connection), language: .redisCommand, command: String(parts[0]),
                parameters: [
                    DatabaseQueryParameter(
                        name: "key",
                        value: .string(String(parts[1]).trimmingCharacters(in: .whitespaces)))
                ], page: page)
        case .mongoDB:
            let fields = try queryBody(text, preservingExtendedJSON: true)
            return DatabaseQueryRequest(
                target: try target(connection), language: .mongoQuery, command: "find",
                body: fields.isEmpty ? nil : .object(fields), page: page)
        case .elasticsearch, .openSearch:
            return DatabaseQueryRequest(
                target: try target(connection), language: .searchQueryDSL,
                command: searchQueryOperation.rawValue,
                body: .object(try queryBody(text, preservingExtendedJSON: false)), page: page)
        }
    }

    private func queryBody(_ text: String, preservingExtendedJSON: Bool) throws
        -> [DatabaseObjectField]
    {
        do {
            return try preservingExtendedJSON
                ? DatabaseJSONDocumentCodec.decodeObject(text)
                : DatabaseJSONDocumentCodec.decodePlainObject(text)
        } catch {
            throw DatabaseDataWorkspaceInputError.invalidQuery("Enter one valid JSON object.")
        }
    }

    func browseRequest(
        _ connection: DatabaseConnectionSummary, continuation: DatabaseContinuationToken?
    ) throws -> DatabaseBrowseRequest {
        let pageSize = try DatabasePageSize(pageSize)
        let filter = try workspaceFilter()
        let sorts = orderedSorts.map {
            DatabaseSort(field: fieldPath(named: $0.field), direction: $0.direction)
        }
        return DatabaseBrowseRequest(
            target: try target(connection),
            page: DatabasePageRequest(
                pageSize: pageSize, continuation: continuation, filter: filter, sorts: sorts))
    }

    private func workspaceFilter() throws -> DatabaseFilter? {
        let filters = try filterClauses.filter(\.isEnabled).map(filter(for:))
        if filters.count == 1 { return filters[0] }
        guard !filters.isEmpty else { return nil }
        return filterConjunction == .and ? .all(filters) : .any(filters)
    }

    private func filter(for clause: DatabaseWorkspaceFilterClause) throws -> DatabaseFilter {
        let normalizedField = clause.field.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedField.isEmpty else {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Choose a field for every enabled filter.")
        }
        if let activeProduct,
            let descriptor = fields.first(where: {
                $0.path.segments.joined(separator: ".") == normalizedField
            })
        {
            guard
                DatabaseFilterOperatorPolicy.operators(product: activeProduct, field: descriptor)
                    .contains(clause.operation)
            else {
                throw DatabaseDataWorkspaceInputError.invalidFilter(
                    "\(DatabaseFilterOperatorPolicy.title(product: activeProduct, operation: clause.operation)) is not available for \(descriptor.displayName)."
                )
            }
            guard
                clause.caseSensitivity == .productDefault
                    || DatabaseFilterOperatorPolicy.supportsCaseSensitivity(
                        product: activeProduct, field: descriptor, operation: clause.operation)
            else {
                throw DatabaseDataWorkspaceInputError.invalidFilter(
                    "Case matching is not available for \(descriptor.displayName).")
            }
        }
        return .predicate(
            DatabaseFilterPredicate(
                field: fieldPath(named: normalizedField), operation: clause.operation,
                values: try filterValues(for: clause, fieldName: normalizedField),
                caseSensitivity: clause.caseSensitivity))
    }

    private func filterValues(for clause: DatabaseWorkspaceFilterClause, fieldName: String) throws
        -> [DatabaseValue]
    {
        switch clause.operation {
        case .isNull, .isNotNull, .isMissing, .isNotMissing: return []
        default: break
        }
        let descriptor = fields.first { $0.path.segments.joined(separator: ".") == fieldName }
        let valueTexts: [String]
        switch clause.operation {
        case .in, .notIn, .between:
            valueTexts = try Self.listValueTexts(clause.valueText, fieldName: fieldName)
        default:
            let value = clause.valueText.trimmingCharacters(in: .whitespacesAndNewlines)
            valueTexts =
                descriptor?.enumValues != nil ? [clause.valueText] : (value.isEmpty ? [] : [value])
        }
        if clause.operation == .between, valueTexts.count != 2 {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Enter two values as a JSON array or comma-separated list for the \(fieldName) filter."
            )
        }
        if [.in, .notIn].contains(clause.operation), valueTexts.count > 100 {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Use at most 100 values for the \(fieldName) filter.")
        }
        guard !valueTexts.isEmpty else {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Enter a value for the \(fieldName) filter.")
        }
        let typeName = descriptor?.typeName ?? "text"
        if let choices = descriptor?.enumValues {
            guard valueTexts.allSatisfy(choices.contains) else {
                throw DatabaseDataWorkspaceInputError.invalidFilter(
                    "Choose a declared enum value for the \(fieldName) filter.")
            }
        }
        do {
            return try valueTexts.map {
                if descriptor?.enumValues != nil { return DatabaseValue.string($0) }
                return try Self.value(from: $0, typeName: typeName, fieldName: fieldName)
            }
        } catch {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Enter a valid \(typeName) value for the \(fieldName) filter.")
        }
    }

    private func fieldPath(named name: String) -> DatabaseFieldPath {
        fields.first { $0.path.segments.joined(separator: ".") == name }?.path
            ?? DatabaseFieldPath(
                activeProduct == .postgresql ? name.components(separatedBy: ".") : [name])
    }

    private nonisolated static func listValueTexts(_ text: String, fieldName: String) throws
        -> [String]
    {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") else {
            return trimmed.split(separator: ",", omittingEmptySubsequences: true).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let data = trimmed.data(using: .utf8),
            let values = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            throw DatabaseDataWorkspaceInputError.invalidFilter(
                "Enter a valid JSON array or comma-separated list for the \(fieldName) filter.")
        }
        return try values.map { value in
            if let value = value as? String { return value }
            if value is NSNull { return "NULL" }
            guard value is NSNumber,
                let data = try? JSONSerialization.data(
                    withJSONObject: value, options: [.fragmentsAllowed]),
                let text = String(data: data, encoding: .utf8)
            else {
                throw DatabaseDataWorkspaceInputError.invalidFilter(
                    "Use only text, numbers, booleans, or null in the \(fieldName) list.")
            }
            return text
        }
    }

    func target(_ connection: DatabaseConnectionSummary) throws -> DatabaseTargetIdentifier {
        if let selectedObject {
            return DatabaseTargetIdentifier(connectionID: connection.id, object: selectedObject)
        }
        let entered = targetText.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = entered.split(separator: ".", omittingEmptySubsequences: true).map(
            String.init)
        let object: DatabaseObjectIdentifier
        switch connection.product {
        case .postgresql:
            object = DatabaseObjectIdentifier(
                kind: .table,
                path: try relationalPath(
                    segments, defaultNamespace: connection.defaultSchema ?? "public",
                    product: connection.product))
        case .sqlite:
            guard (1...2).contains(segments.count) else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter a table name, such as customers.")
            }
            object = DatabaseObjectIdentifier(kind: .table, path: segments)
        case .mysql, .mariaDB, .clickHouse, .mongoDB:
            object = DatabaseObjectIdentifier(
                kind: connection.product == .mongoDB ? .collection : .table,
                path: try relationalPath(
                    segments, defaultNamespace: connection.defaultDatabase,
                    product: connection.product))
        case .redis, .valkey:
            guard segments.count <= 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one logical database number or leave it empty.")
            }
            let path = segments.isEmpty ? connection.logicalDatabase.map { [$0] } ?? [] : segments
            object = DatabaseObjectIdentifier(kind: .keyspace, path: path)
        case .elasticsearch, .openSearch:
            guard segments.count == 1 else {
                throw DatabaseDataWorkspaceInputError.invalidTarget(
                    "Enter one index name, such as products.")
            }
            object = DatabaseObjectIdentifier(kind: .index, path: segments)
        }
        return DatabaseTargetIdentifier(connectionID: connection.id, object: object)
    }

    private func relationalPath(
        _ segments: [String], defaultNamespace: String?, product: DatabaseProduct
    ) throws -> [String] {
        if segments.count == 2 { return segments }
        if segments.count == 1, let defaultNamespace { return [defaultNamespace, segments[0]] }
        throw DatabaseDataWorkspaceInputError.invalidTarget(
            "Enter a namespace and object, such as public.customers, for \(product.displayName).")
    }

    static func initialTargetText(_ connection: DatabaseConnectionSummary) -> String {
        switch connection.product {
        case .redis, .valkey: connection.logicalDatabase ?? ""
        case .postgresql: "\(connection.defaultSchema ?? "public")."
        case .mysql, .mariaDB, .mongoDB, .clickHouse:
            connection.defaultDatabase.map { "\($0)." } ?? ""
        case .sqlite, .elasticsearch, .openSearch: ""
        }
    }

    static func defaultQueryText(
        _ product: DatabaseProduct, object: DatabaseObjectIdentifier,
        operation: DatabaseSearchQueryOperation
    ) -> String {
        switch product {
        case .postgresql, .sqlite:
            return "SELECT * FROM " + object.path.map(DoubleQuoted.wrap).joined(separator: ".")
        case .mysql, .mariaDB, .clickHouse:
            return "SELECT * FROM " + object.path.map(BacktickQuoted.wrap).joined(separator: ".")
        case .redis, .valkey: return "TYPE session:1"
        case .mongoDB: return "{}"
        case .elasticsearch, .openSearch:
            if operation == .aggregate {
                return
                    "{\n  \"aggs\": {\n    \"values\": {\n      \"terms\": { \"field\": \"field.keyword\" }\n    }\n  }\n}"
            }
            return "{\n  \"query\": {\n    \"match_all\": {}\n  }\n}"
        }
    }

    static func replay(_ request: DatabaseQueryRequest, continuation: DatabaseContinuationToken)
        -> DatabaseQueryRequest
    {
        DatabaseQueryRequest(
            version: request.version, target: request.target, language: request.language,
            command: request.command, parameters: request.parameters, body: request.body,
            page: DatabasePageRequest(
                pageSize: request.page.pageSize, continuation: continuation,
                projection: request.page.projection, filter: request.page.filter,
                sorts: request.page.sorts, consistency: request.page.consistency),
            operation: request.operation)
    }
}
