import CryptoKit
import Foundation

struct ClickHouseDatabaseColumn: Equatable, Sendable {
    let name: String
    let type: String
    let position: UInt64
    let isPrimaryKey: Bool
    let isSortingKey: Bool

    var descriptor: DatabaseFieldDescriptor {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath(name),
            displayName: name,
            typeName: type,
            isNullable: type.hasPrefix("Nullable("),
            isSortable: true,
            isFilterable: true)
    }
}

struct ClickHouseDatabaseTableDescription: Equatable, Sendable {
    let database: String
    let table: String
    let columns: [ClickHouseDatabaseColumn]

    var sortingColumns: [ClickHouseDatabaseColumn] {
        columns.filter(\.isSortingKey)
    }
}

struct ClickHouseDatabaseSelectedColumn: Sendable {
    let source: ClickHouseDatabaseColumn
    let outputName: String
}

struct ClickHouseDatabaseOrderingColumn: Codable, Hashable, Sendable {
    let name: String
    let type: String
    let direction: DatabaseSortDirection
}

enum ClickHouseDatabaseContinuationScope: String, Codable, Sendable {
    case databases
    case tables
    case columns
    case browse
}

struct ClickHouseDatabaseContinuationPayload: Codable, Sendable {
    let version: Int
    let sessionID: UUID
    let scope: ClickHouseDatabaseContinuationScope
    let requestDigest: String
    let order: [ClickHouseDatabaseOrderingColumn]
    let values: [String]
    let seenRows: UInt64
    let expiresAt: Date
}

struct ClickHouseDatabaseMetadataPlan: Sendable {
    let query: String
    let parameters: [ClickHouseDatabaseHTTPParameter]
    let scope: ClickHouseDatabaseContinuationScope
    let requestDigest: String
    let order: [ClickHouseDatabaseOrderingColumn]
    let seenRows: UInt64
}

struct ClickHouseDatabaseBrowsePlan: Sendable {
    let query: String
    let parameters: [ClickHouseDatabaseHTTPParameter]
    let selected: [ClickHouseDatabaseSelectedColumn]
    let order: [ClickHouseDatabaseOrderingColumn]
    let identityColumns: [ClickHouseDatabaseColumn]
    let requestDigest: String
    let seenRows: UInt64
}

struct ClickHouseDatabaseQueryPlan: Sendable {
    let query: String
    let parameters: [ClickHouseDatabaseHTTPParameter]
}

enum ClickHouseDatabaseReadCompiler {
    static let continuationLifetime: TimeInterval = 60
    static let maximumFilterNodes = 100
    static let maximumFilterValues = 100
    static let maximumIdentifierBytes = 1_024

    static func descriptionQuery(
        database: String,
        table: String
    ) throws(DatabaseAdapterFailure) -> String {
        try validateIdentifier(database)
        try validateIdentifier(table)
        return """
            SELECT name, type, toUInt64(position) AS position,
                toUInt64(is_in_primary_key) AS is_in_primary_key,
                toUInt64(is_in_sorting_key) AS is_in_sorting_key
            FROM system.columns
            WHERE database = {_edith_database:String}
                AND table = {_edith_table:String}
            ORDER BY position, name
            LIMIT 513
            FORMAT JSONCompactEachRowWithNamesAndTypes
            """
    }

    static func tableDescription(
        response: ClickHouseDatabaseHTTPResponse,
        database: String,
        table: String
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseTableDescription {
        let result = try decode(response)
        guard
            result.names
                == ["name", "type", "position", "is_in_primary_key", "is_in_sorting_key"],
            !result.rows.isEmpty,
            result.rows.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidResponse
        }
        var names = Set<String>()
        var columns: [ClickHouseDatabaseColumn] = []
        for row in result.rows {
            guard row.cells.count == 5,
                let name = string(row.cells[0].value),
                let type = string(row.cells[1].value),
                let position = unsigned(row.cells[2].value),
                let primary = unsigned(row.cells[3].value),
                let sorting = unsigned(row.cells[4].value),
                !name.isEmpty,
                !type.isEmpty,
                names.insert(name).inserted,
                position > 0,
                primary <= 1,
                sorting <= 1
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
            try validateIdentifier(name)
            guard type.utf8.count <= 2_048, !type.contains("\0") else {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
            columns.append(
                ClickHouseDatabaseColumn(
                    name: name,
                    type: type,
                    position: position,
                    isPrimaryKey: primary == 1,
                    isSortingKey: sorting == 1))
        }
        return ClickHouseDatabaseTableDescription(
            database: database,
            table: table,
            columns: columns.sorted {
                if $0.position == $1.position { return $0.name < $1.name }
                return $0.position < $1.position
            })
    }

    static func compileMetadata(
        _ request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseMetadataPlan {
        guard request.target.record == nil,
            request.projection == nil,
            request.filter == nil,
            request.sorts.isEmpty,
            request.consistency != .strong
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let scope = try metadataScope(request.target)
        let digest = try requestDigest(request, scope: scope)
        let order: [ClickHouseDatabaseOrderingColumn]
        var parameters: [ClickHouseDatabaseHTTPParameter] = []
        let base: String
        switch scope {
        case .databases:
            order = [ordering("name", type: "String")]
            base = "SELECT name, engine FROM system.databases"
        case .tables:
            let database = try path(request.target, count: 1)[0]
            order = [ordering("name", type: "String")]
            parameters.append(parameter("_edith_database", database))
            base = """
                SELECT database, name, engine, total_rows, total_bytes,
                    sorting_key, primary_key, partition_key, comment
                FROM system.tables
                WHERE database = {_edith_database:String}
                """
        case .columns:
            let components = try path(request.target, count: 2)
            order = [
                ordering("position", type: "UInt64"),
                ordering("name", type: "String"),
            ]
            parameters.append(parameter("_edith_database", components[0]))
            parameters.append(parameter("_edith_table", components[1]))
            base = """
                SELECT database, table, name, type, toUInt64(position) AS position,
                    default_kind, default_expression, compression_codec,
                    toUInt64(is_in_primary_key) AS is_in_primary_key,
                    toUInt64(is_in_sorting_key) AS is_in_sorting_key
                FROM system.columns
                WHERE database = {_edith_database:String}
                    AND table = {_edith_table:String}
                """
        case .browse:
            throw ClickHouseDatabaseAdapterSupport.invalidTarget
        }
        let continuation = try continuation(
            request.continuation,
            sessionID: sessionID,
            scope: scope,
            digest: digest,
            order: order)
        var query = base
        if let continuation {
            let predicate = comparison(
                order: order,
                values: continuation.values,
                parameterPrefix: "_edith_after",
                parameters: &parameters)
            query += scope == .databases ? " WHERE \(predicate)" : " AND \(predicate)"
        }
        query += " ORDER BY " + order.map(orderSQL).joined(separator: ", ")
        query += " LIMIT \(request.pageSize.value + 1)"
        query += " FORMAT JSONCompactEachRowWithNamesAndTypes"
        return ClickHouseDatabaseMetadataPlan(
            query: query,
            parameters: parameters,
            scope: scope,
            requestDigest: digest,
            order: order,
            seenRows: continuation?.seenRows ?? 0)
    }

    static func compileBrowse(
        _ request: DatabaseAdapterPageRequest,
        description: ClickHouseDatabaseTableDescription,
        sessionID: DatabaseAdapterSessionID
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseBrowsePlan {
        guard request.target.record == nil,
            [.productDefault, .bestEffort, .eventual].contains(request.consistency),
            let object = request.target.object,
            [.table, .view, .materializedView].contains(object.kind),
            object.nativeIdentifier == nil,
            object.path == [description.database, description.table]
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let selected = try selectedColumns(
            description.columns,
            projection: request.projection)
        let order = try orderingColumns(
            request.sorts,
            description: description)
        guard selected.count + order.count <= DatabaseAdapterBounds.maximumPageFields else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let digest = try requestDigest(request, scope: .browse, order: order)
        let continuation = try continuation(
            request.continuation,
            sessionID: sessionID,
            scope: .browse,
            digest: digest,
            order: order)
        var filterState = ClickHouseDatabaseFilterState()
        let filterSQL: String?
        if let filter = request.filter {
            filterSQL = try compileFilter(
                filter,
                available: description.columns,
                state: &filterState,
                depth: 0)
        } else {
            filterSQL = nil
        }
        var parameters = filterState.parameters
        var predicates = filterSQL.map { [$0] } ?? []
        if let continuation {
            predicates.append(
                comparison(
                    order: order,
                    values: continuation.values,
                    parameterPrefix: "_edith_after",
                    parameters: &parameters))
        }
        var selections = selected.map {
            "\(quote($0.source.name)) AS \(quote($0.outputName))"
        }
        selections.append(
            contentsOf: order.enumerated().map { index, column in
                "\(quote(column.name)) AS \(quote("_edith_sort_\(index)"))"
            })
        var query = "SELECT \(selections.joined(separator: ", ")) FROM "
        query += "\(quote(description.database)).\(quote(description.table))"
        if !predicates.isEmpty {
            query += " WHERE \(predicates.map { "(\($0))" }.joined(separator: " AND "))"
        }
        query += " ORDER BY " + order.map(orderSQL).joined(separator: ", ")
        query += " LIMIT \(request.pageSize.value + 1)"
        query += " FORMAT JSONCompactEachRowWithNamesAndTypes"
        return ClickHouseDatabaseBrowsePlan(
            query: query,
            parameters: parameters,
            selected: selected,
            order: order,
            identityColumns: description.sortingColumns,
            requestDigest: digest,
            seenRows: continuation?.seenRows ?? 0)
    }

    static func compileQuery(
        _ request: DatabaseAdapterQueryRequest
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseQueryPlan {
        guard request.language == .clickHouseSQL,
            request.body == nil,
            request.source.continuation == nil,
            request.source.projection == nil,
            request.source.filter == nil,
            request.source.sorts.isEmpty,
            request.source.recordless,
            request.source.consistency != .strong,
            request.parameters.count <= ClickHouseDatabaseHTTPTransport.maximumParameters,
            let command = validatedReadCommand(request.command)
        else {
            throw ClickHouseDatabaseAdapterSupport.unsafeRequest
        }
        var names = Set<String>()
        var parameters: [ClickHouseDatabaseHTTPParameter] = []
        for parameterValue in request.parameters {
            guard let name = parameterValue.name,
                validParameterName(name),
                names.insert(name).inserted,
                let value = parameterText(parameterValue.value)
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            parameters.append(parameter(name, value))
        }
        let query: String
        if command.lowercased().hasPrefix("explain") {
            query = command + "\nFORMAT JSONCompactEachRowWithNamesAndTypes"
        } else {
            query = """
                SELECT * FROM (
                \(command)
                ) AS _edith_query
                LIMIT \(request.source.pageSize.value + 1)
                FORMAT JSONCompactEachRowWithNamesAndTypes
                """
        }
        return ClickHouseDatabaseQueryPlan(query: query, parameters: parameters)
    }

    static func metadataPage(
        response: ClickHouseDatabaseHTTPResponse,
        plan: ClickHouseDatabaseMetadataPlan,
        request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let result = try decode(response)
        let hasMore = result.rows.count > request.pageSize.value
        let rows = Array(result.rows.prefix(request.pageSize.value))
        var records: [DatabaseRecord] = []
        for row in rows {
            let identity = try metadataIdentity(
                row: row,
                names: result.names,
                scope: plan.scope)
            do {
                records.append(
                    try ClickHouseDatabaseValueCodec.record(
                        row,
                        names: result.names,
                        identity: identity))
            } catch {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
        }
        let next = try nextContinuation(
            row: hasMore ? rows.last : nil,
            names: result.names,
            order: plan.order,
            scope: plan.scope,
            digest: plan.requestDigest,
            sessionID: sessionID,
            seenRows: plan.seenRows + UInt64(records.count))
        return try page(
            records: records,
            fields: result.fields,
            next: next,
            hasMore: hasMore,
            seenRows: plan.seenRows,
            bytes: response.body.count,
            startedAt: startedAt,
            warning: nil)
    }

    static func browsePage(
        response: ClickHouseDatabaseHTTPResponse,
        plan: ClickHouseDatabaseBrowsePlan,
        request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let result = try decode(response)
        let expectedNames =
            plan.selected.map(\.outputName)
            + plan.order.indices.map { "_edith_sort_\($0)" }
        guard result.names == expectedNames else {
            throw ClickHouseDatabaseAdapterSupport.invalidResponse
        }
        let hasMore = result.rows.count > request.pageSize.value
        let rows = Array(result.rows.prefix(request.pageSize.value))
        let visibleCount = plan.selected.count
        var records: [DatabaseRecord] = []
        for row in rows {
            guard row.cells.count == expectedNames.count else {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
            let sortCells = Array(row.cells.dropFirst(visibleCount))
            let identity = try recordIdentity(
                columns: plan.identityColumns,
                order: plan.order,
                cells: sortCells)
            do {
                records.append(
                    try ClickHouseDatabaseValueCodec.record(
                        ClickHouseDatabaseDecodedRow(
                            cells: Array(row.cells.prefix(visibleCount))),
                        names: Array(expectedNames.prefix(visibleCount)),
                        identity: identity))
            } catch {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
        }
        let fields = plan.selected.map { selected in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(selected.outputName),
                displayName: selected.outputName,
                typeName: selected.source.type,
                isNullable: selected.source.descriptor.isNullable,
                isSortable: true,
                isFilterable: true)
        }
        let next = try nextContinuation(
            row: hasMore ? rows.last : nil,
            names: expectedNames,
            order: plan.order,
            scope: .browse,
            digest: plan.requestDigest,
            sessionID: sessionID,
            seenRows: plan.seenRows + UInt64(records.count))
        let warning = DatabaseWarning(
            code: "clickhouse.pagination.best_effort",
            message:
                "Keyset pages are stable while the selected MergeTree ordering values remain unchanged.",
            severity: .information,
            target: request.target)
        return try page(
            records: records,
            fields: fields,
            next: next,
            hasMore: hasMore,
            seenRows: plan.seenRows,
            bytes: response.body.count,
            startedAt: startedAt,
            warning: warning)
    }

    static func queryPage(
        response: ClickHouseDatabaseHTTPResponse,
        request: DatabaseAdapterPageRequest,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let result = try decode(response)
        let hasMore = result.rows.count > request.pageSize.value
        var records: [DatabaseRecord] = []
        for row in result.rows.prefix(request.pageSize.value) {
            do {
                records.append(
                    try ClickHouseDatabaseValueCodec.record(row, names: result.names))
            } catch {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
        }
        let warning =
            hasMore
            ? DatabaseWarning(
                code: "clickhouse.query.truncated",
                message:
                    "The bounded query page was truncated; narrow the query to retrieve a complete result.",
                severity: .caution,
                target: request.target)
            : nil
        return try page(
            records: records,
            fields: result.fields,
            next: nil,
            hasMore: hasMore,
            seenRows: 0,
            bytes: response.body.count,
            startedAt: startedAt,
            warning: warning)
    }

    static func degradedMetadataPage(
        request: DatabaseAdapterPageRequest,
        startedAt: ContinuousClock.Instant
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        try DatabaseAdapterPage(
            records: [],
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: .partial,
                    reason: "ClickHouse metadata access was denied."),
                count: DatabaseCountMetadata(accuracy: .unknown),
                timing: timing(startedAt),
                warnings: [
                    DatabaseWarning(
                        code: "clickhouse.metadata.permission_denied",
                        message:
                            "The connected user cannot read the requested ClickHouse metadata.",
                        severity: .caution,
                        target: request.target)
                ]))
    }

    static func targetTable(
        _ target: DatabaseTargetIdentifier
    ) throws(DatabaseAdapterFailure) -> (database: String, table: String)? {
        guard let object = target.object,
            [.table, .view, .materializedView].contains(object.kind)
        else {
            return nil
        }
        let components = try path(target, count: 2)
        return (components[0], components[1])
    }

    private static func decode(
        _ response: ClickHouseDatabaseHTTPResponse
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseTabularResult {
        do {
            return try ClickHouseDatabaseValueCodec.decode(response.body)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidResponse
        }
    }

    private static func selectedColumns(
        _ available: [ClickHouseDatabaseColumn],
        projection: DatabaseProjection?
    ) throws(DatabaseAdapterFailure) -> [ClickHouseDatabaseSelectedColumn] {
        guard let projection else {
            return available.map {
                ClickHouseDatabaseSelectedColumn(source: $0, outputName: $0.name)
            }
        }
        var selected: [ClickHouseDatabaseSelectedColumn] = []
        switch projection.mode {
        case .include:
            guard !projection.fields.isEmpty else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            var sources = Set<String>()
            for field in projection.fields {
                let column = try resolve(field.path, available: available)
                guard sources.insert(column.name).inserted else {
                    throw ClickHouseDatabaseAdapterSupport.invalidRequest
                }
                let output = field.alias ?? column.name
                try validateIdentifier(output)
                guard !output.hasPrefix("_edith_") else {
                    throw ClickHouseDatabaseAdapterSupport.invalidRequest
                }
                selected.append(
                    ClickHouseDatabaseSelectedColumn(source: column, outputName: output))
            }
        case .exclude:
            var excluded = Set<String>()
            for field in projection.fields {
                guard field.alias == nil else {
                    throw ClickHouseDatabaseAdapterSupport.invalidRequest
                }
                let column = try resolve(field.path, available: available)
                guard excluded.insert(column.name).inserted else {
                    throw ClickHouseDatabaseAdapterSupport.invalidRequest
                }
            }
            selected = available.compactMap {
                excluded.contains($0.name)
                    ? nil
                    : ClickHouseDatabaseSelectedColumn(source: $0, outputName: $0.name)
            }
        }
        var outputs = Set<String>()
        guard !selected.isEmpty,
            selected.count <= DatabaseAdapterBounds.maximumProjectionFields,
            selected.allSatisfy({ outputs.insert($0.outputName).inserted })
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        return selected
    }

    private static func orderingColumns(
        _ sorts: [DatabaseSort],
        description: ClickHouseDatabaseTableDescription
    ) throws(DatabaseAdapterFailure) -> [ClickHouseDatabaseOrderingColumn] {
        guard !description.sortingColumns.isEmpty else {
            throw ClickHouseDatabaseAdapterSupport.unstableTarget
        }
        var output: [ClickHouseDatabaseOrderingColumn] = []
        var names = Set<String>()
        for sort in sorts {
            let column = try resolve(sort.field, available: description.columns)
            guard !column.descriptor.isNullable,
                names.insert(column.name).inserted
            else {
                throw ClickHouseDatabaseAdapterSupport.unstableTarget
            }
            output.append(
                ClickHouseDatabaseOrderingColumn(
                    name: column.name,
                    type: column.type,
                    direction: sort.direction))
        }
        for column in description.sortingColumns where names.insert(column.name).inserted {
            guard !column.descriptor.isNullable else {
                throw ClickHouseDatabaseAdapterSupport.unstableTarget
            }
            output.append(
                ClickHouseDatabaseOrderingColumn(
                    name: column.name,
                    type: column.type,
                    direction: .ascending))
        }
        guard output.count <= DatabaseAdapterBounds.maximumSorts else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        return output
    }

    private static func compileFilter(
        _ filter: DatabaseFilter,
        available: [ClickHouseDatabaseColumn],
        state: inout ClickHouseDatabaseFilterState,
        depth: Int
    ) throws(DatabaseAdapterFailure) -> String {
        guard depth <= 16, state.nodes < maximumFilterNodes else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        state.nodes += 1
        switch filter {
        case let .predicate(predicate):
            return try predicateSQL(predicate, available: available, state: &state)
        case let .all(children):
            guard !children.isEmpty else { return "1" }
            var expressions: [String] = []
            for child in children {
                expressions.append(
                    try
                        "(\(compileFilter(child, available: available, state: &state, depth: depth + 1)))"
                )
            }
            return expressions.joined(separator: " AND ")
        case let .any(children):
            guard !children.isEmpty else { return "0" }
            var expressions: [String] = []
            for child in children {
                expressions.append(
                    try
                        "(\(compileFilter(child, available: available, state: &state, depth: depth + 1)))"
                )
            }
            return expressions.joined(separator: " OR ")
        case let .not(child):
            return try
                "NOT (\(compileFilter(child, available: available, state: &state, depth: depth + 1)))"
        }
    }

    private static func predicateSQL(
        _ predicate: DatabaseFilterPredicate,
        available: [ClickHouseDatabaseColumn],
        state: inout ClickHouseDatabaseFilterState
    ) throws(DatabaseAdapterFailure) -> String {
        let column = try resolve(predicate.field, available: available)
        let field = quote(column.name)
        switch predicate.operation {
        case .isNull, .isMissing:
            guard predicate.values.isEmpty else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            return "isNull(\(field))"
        case .isNotNull, .isNotMissing:
            guard predicate.values.isEmpty else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            return "isNotNull(\(field))"
        case .in, .notIn:
            guard !predicate.values.isEmpty,
                predicate.values.count <= maximumFilterValues
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            var values: [String] = []
            for value in predicate.values {
                values.append(
                    try filterParameter(value, column: column, state: &state))
            }
            return
                "\(field) \(predicate.operation == .in ? "IN" : "NOT IN") (\(values.joined(separator: ", ")))"
        case .between:
            guard predicate.values.count == 2 else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            let lower = try filterParameter(predicate.values[0], column: column, state: &state)
            let upper = try filterParameter(predicate.values[1], column: column, state: &state)
            return "\(field) BETWEEN \(lower) AND \(upper)"
        case .contains, .startsWith, .endsWith, .regularExpression, .fullText:
            guard predicate.values.count == 1,
                let text = parameterText(predicate.values[0])
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            let name = "_edith_filter_\(state.parameters.count)"
            state.parameters.append(parameter(name, text))
            let value = "{\(name):String}"
            let source =
                predicate.caseSensitivity == .insensitive
                ? "lowerUTF8(toString(\(field)))"
                : "toString(\(field))"
            let needle =
                predicate.caseSensitivity == .insensitive
                ? "lowerUTF8(\(value))"
                : value
            switch predicate.operation {
            case .contains:
                return "positionUTF8(\(source), \(needle)) > 0"
            case .startsWith:
                return "startsWith(\(source), \(needle))"
            case .endsWith:
                return "endsWith(\(source), \(needle))"
            case .regularExpression:
                return "match(\(source), \(needle))"
            case .fullText:
                return "hasToken(\(source), \(needle))"
            default:
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
        case .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan,
            .lessThanOrEqual:
            guard predicate.values.count == 1 else {
                throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            let value = try filterParameter(predicate.values[0], column: column, state: &state)
            let operation: String
            switch predicate.operation {
            case .equal: operation = "="
            case .notEqual: operation = "!="
            case .greaterThan: operation = ">"
            case .greaterThanOrEqual: operation = ">="
            case .lessThan: operation = "<"
            case .lessThanOrEqual: operation = "<="
            default: throw ClickHouseDatabaseAdapterSupport.invalidRequest
            }
            if predicate.caseSensitivity == .insensitive {
                return "lowerUTF8(toString(\(field))) \(operation) lowerUTF8(toString(\(value)))"
            }
            return "\(field) \(operation) \(value)"
        }
    }

    private static func filterParameter(
        _ value: DatabaseValue,
        column: ClickHouseDatabaseColumn,
        state: inout ClickHouseDatabaseFilterState
    ) throws(DatabaseAdapterFailure) -> String {
        guard let text = parameterText(value) else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        let name = "_edith_filter_\(state.parameters.count)"
        state.parameters.append(parameter(name, text))
        return "CAST({\(name):String}, \(stringLiteral(column.type)))"
    }

    private static func comparison(
        order: [ClickHouseDatabaseOrderingColumn],
        values: [String],
        parameterPrefix: String,
        parameters: inout [ClickHouseDatabaseHTTPParameter]
    ) -> String {
        var branches: [String] = []
        for index in order.indices {
            var components: [String] = []
            for equalIndex in 0..<index {
                let name = "\(parameterPrefix)\(equalIndex)"
                components.append(
                    "\(quote(order[equalIndex].name)) = CAST({\(name):String}, \(stringLiteral(order[equalIndex].type)))"
                )
            }
            let name = "\(parameterPrefix)\(index)"
            let operation = order[index].direction == .ascending ? ">" : "<"
            components.append(
                "\(quote(order[index].name)) \(operation) CAST({\(name):String}, \(stringLiteral(order[index].type)))"
            )
            branches.append("(\(components.joined(separator: " AND ")))")
        }
        for index in order.indices {
            parameters.append(parameter("\(parameterPrefix)\(index)", values[index]))
        }
        return branches.joined(separator: " OR ")
    }

    private static func continuation(
        _ continuation: DatabaseAdapterContinuation?,
        sessionID: DatabaseAdapterSessionID,
        scope: ClickHouseDatabaseContinuationScope,
        digest: String,
        order: [ClickHouseDatabaseOrderingColumn]
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseContinuationPayload? {
        guard let continuation else { return nil }
        guard continuation.mode == .keyset,
            let expiresAt = continuation.expiresAt,
            expiresAt.timeIntervalSinceReferenceDate.isFinite,
            expiresAt > Date()
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidContinuation
        }
        let payload: ClickHouseDatabaseContinuationPayload
        do {
            payload = try JSONDecoder().decode(
                ClickHouseDatabaseContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidContinuation
        }
        guard payload.version == 1,
            payload.sessionID == sessionID.rawValue,
            payload.scope == scope,
            payload.requestDigest == digest,
            payload.order == order,
            payload.values.count == order.count,
            payload.values.allSatisfy({ $0.utf8.count <= 1_048_576 && !$0.contains("\0") }),
            payload.expiresAt == expiresAt,
            payload.expiresAt > Date()
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidContinuation
        }
        return payload
    }

    private static func nextContinuation(
        row: ClickHouseDatabaseDecodedRow?,
        names: [String],
        order: [ClickHouseDatabaseOrderingColumn],
        scope: ClickHouseDatabaseContinuationScope,
        digest: String,
        sessionID: DatabaseAdapterSessionID,
        seenRows: UInt64
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterContinuation? {
        guard let row else { return nil }
        var values: [String] = []
        for (orderIndex, ordering) in order.enumerated() {
            let sourceIndex =
                scope == .browse
                ? names.firstIndex(of: "_edith_sort_\(orderIndex)")
                : names.firstIndex(of: ordering.name)
            guard let index = sourceIndex,
                row.cells.indices.contains(index),
                let value = row.cells[index].parameterText
            else {
                throw ClickHouseDatabaseAdapterSupport.unstableTarget
            }
            values.append(value)
        }
        let expiresAt = Date().addingTimeInterval(continuationLifetime)
        let payload: Data
        do {
            payload = try JSONEncoder().encode(
                ClickHouseDatabaseContinuationPayload(
                    version: 1,
                    sessionID: sessionID.rawValue,
                    scope: scope,
                    requestDigest: digest,
                    order: order,
                    values: values,
                    seenRows: seenRows,
                    expiresAt: expiresAt))
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidContinuation
        }
        return try DatabaseAdapterContinuation(
            mode: .keyset,
            payload: payload,
            expiresAt: expiresAt)
    }

    private static func recordIdentity(
        columns: [ClickHouseDatabaseColumn],
        order: [ClickHouseDatabaseOrderingColumn],
        cells: [ClickHouseDatabaseDecodedCell]
    ) throws(DatabaseAdapterFailure) -> DatabaseRecordIdentity {
        var components: [DatabaseIdentityComponent] = []
        for column in columns {
            guard let index = order.firstIndex(where: { $0.name == column.name }),
                cells.indices.contains(index)
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
            components.append(
                DatabaseIdentityComponent(name: column.name, value: cells[index].value))
        }
        return DatabaseRecordIdentity(kind: .key, components: components)
    }

    private static func metadataIdentity(
        row: ClickHouseDatabaseDecodedRow,
        names: [String],
        scope: ClickHouseDatabaseContinuationScope
    ) throws(DatabaseAdapterFailure) -> DatabaseRecordIdentity {
        let identityNames: [String]
        switch scope {
        case .databases:
            identityNames = ["name"]
        case .tables:
            identityNames = ["database", "name"]
        case .columns:
            identityNames = ["database", "table", "name"]
        case .browse:
            throw ClickHouseDatabaseAdapterSupport.invalidResponse
        }
        var components: [DatabaseIdentityComponent] = []
        for name in identityNames {
            guard let index = names.firstIndex(of: name), row.cells.indices.contains(index) else {
                throw ClickHouseDatabaseAdapterSupport.invalidResponse
            }
            components.append(
                DatabaseIdentityComponent(name: name, value: row.cells[index].value))
        }
        return DatabaseRecordIdentity(kind: .key, components: components)
    }

    private static func page(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor],
        next: DatabaseAdapterContinuation?,
        hasMore: Bool,
        seenRows: UInt64,
        bytes: Int,
        startedAt: ContinuousClock.Instant,
        warning: DatabaseWarning?
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterPage {
        let total = seenRows + UInt64(records.count)
        return try DatabaseAdapterPage(
            records: records,
            fields: fields,
            nextContinuation: next,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: hasMore ? .partial : .complete,
                    reason: hasMore ? "More rows are available through keyset pagination." : nil),
                count: DatabaseCountMetadata(
                    value: total,
                    accuracy: hasMore ? .lowerBound : .exact),
                timing: timing(startedAt),
                bytesReceived: UInt64(bytes),
                warnings: warning.map { [$0] } ?? []))
    }

    private static func timing(
        _ startedAt: ContinuousClock.Instant
    ) -> DatabaseQueryTiming {
        let duration = startedAt.duration(to: .now)
        let components = duration.components
        let milliseconds = max(
            0,
            components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
        return DatabaseQueryTiming(durationMilliseconds: UInt64(milliseconds))
    }

    private static func metadataScope(
        _ target: DatabaseTargetIdentifier
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseContinuationScope {
        guard target.record == nil else { throw ClickHouseDatabaseAdapterSupport.invalidTarget }
        guard let object = target.object else { return .databases }
        guard object.nativeIdentifier == nil else {
            throw ClickHouseDatabaseAdapterSupport.invalidTarget
        }
        switch object.kind {
        case .database:
            _ = try path(target, count: 1)
            return .tables
        case .column:
            _ = try path(target, count: 2)
            return .columns
        default:
            throw ClickHouseDatabaseAdapterSupport.invalidTarget
        }
    }

    private static func path(
        _ target: DatabaseTargetIdentifier,
        count: Int
    ) throws(DatabaseAdapterFailure) -> [String] {
        guard let object = target.object,
            object.path.count == count,
            object.path.allSatisfy({ !$0.isEmpty })
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidTarget
        }
        for component in object.path { try validateIdentifier(component) }
        return object.path
    }

    private static func resolve(
        _ path: DatabaseFieldPath,
        available: [ClickHouseDatabaseColumn]
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseColumn {
        guard path.segments.count == 1,
            let name = path.segments.first,
            let column = available.first(where: { $0.name == name })
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        return column
    }

    private static func ordering(
        _ name: String,
        type: String
    ) -> ClickHouseDatabaseOrderingColumn {
        ClickHouseDatabaseOrderingColumn(name: name, type: type, direction: .ascending)
    }

    private static func orderSQL(_ order: ClickHouseDatabaseOrderingColumn) -> String {
        "\(quote(order.name)) \(order.direction == .ascending ? "ASC" : "DESC")"
    }

    private static func requestDigest(
        _ request: DatabaseAdapterPageRequest,
        scope: ClickHouseDatabaseContinuationScope,
        order: [ClickHouseDatabaseOrderingColumn] = []
    ) throws(DatabaseAdapterFailure) -> String {
        let binding = ClickHouseDatabaseDigestBinding(
            scope: scope,
            target: request.target,
            pageSize: request.pageSize.value,
            projection: request.projection,
            filter: request.filter,
            sorts: request.sorts,
            consistency: request.consistency,
            order: order)
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(binding)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func validatedReadCommand(_ value: String) -> String? {
        guard !value.isEmpty,
            value.utf8.count <= ClickHouseDatabaseHTTPTransport.maximumQueryBytes,
            !value.contains("\0")
        else {
            return nil
        }
        let bytes = Array(value.utf8)
        var tokens: [String] = []
        var index = 0
        var terminalSemicolon = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte <= 32 {
                index += 1
                continue
            }
            if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 45 { return nil }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 { return nil }
            if byte == 35 { return nil }
            if byte == 59 {
                terminalSemicolon = true
                index += 1
                guard bytes[index...].allSatisfy({ $0 <= 32 }) else { return nil }
                break
            }
            if byte == 39 || byte == 34 || byte == 96 {
                let quote = byte
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 {
                        index += 2
                        continue
                    }
                    if bytes[index] == quote {
                        if index + 1 < bytes.count, bytes[index + 1] == quote {
                            index += 2
                            continue
                        }
                        index += 1
                        closed = true
                        break
                    }
                    index += 1
                }
                guard closed else { return nil }
                continue
            }
            if asciiWord(byte) {
                let start = index
                while index < bytes.count, asciiWord(bytes[index]) { index += 1 }
                tokens.append(String(decoding: bytes[start..<index], as: UTF8.self).lowercased())
                continue
            }
            guard byte >= 32 && byte != 127 else { return nil }
            index += 1
        }
        guard let first = tokens.first,
            ["select", "with", "explain"].contains(first),
            tokens.contains("select")
        else {
            return nil
        }
        let forbidden: Set<String> = [
            "alter", "attach", "create", "delete", "detach", "drop", "grant", "insert",
            "kill", "move", "optimize", "rename", "replace", "revoke", "set", "system",
            "truncate", "update", "use", "watch", "into", "outfile", "format", "settings",
            "executable", "executablepool", "file", "url", "s3", "hdfs", "jdbc", "odbc",
            "mysql", "postgresql", "remote", "remotesecure", "cluster", "clusterallreplicas",
            "input", "generateRandom", "dictionary",
        ].map { $0.lowercased() }.reduce(into: Set<String>()) { $0.insert($1) }
        guard tokens.allSatisfy({ !forbidden.contains($0) }) else { return nil }
        let end =
            terminalSemicolon
            ? value[..<value.lastIndex(of: ";")!]
            : value[...]
        let command = end.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? nil : command
    }

    private static func asciiWord(_ byte: UInt8) -> Bool {
        (byte >= 48 && byte <= 57) || (byte >= 65 && byte <= 90)
            || (byte >= 97 && byte <= 122) || byte == 95 || byte == 36
    }

    private static func validParameterName(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= ClickHouseDatabaseHTTPTransport.maximumParameterNameBytes,
            let first = value.utf8.first,
            (first >= 65 && first <= 90) || (first >= 97 && first <= 122) || first == 95
        else {
            return false
        }
        return value.utf8.dropFirst().allSatisfy {
            ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122)
                || ($0 >= 48 && $0 <= 57) || $0 == 95
        }
    }

    private static func parameterText(_ value: DatabaseValue) -> String? {
        let output: String?
        switch value {
        case let .boolean(value): output = value ? "1" : "0"
        case let .signedInteger(value): output = String(value)
        case let .unsignedInteger(value): output = String(value)
        case let .decimal(value): output = value.rawValue
        case let .floatingPoint(value): output = value.isFinite ? String(value) : nil
        case let .string(value): output = value
        case let .date(value): output = value.text
        case let .time(value): output = value.text
        case let .timestamp(value): output = value.text
        case let .uuid(value): output = value.uuidString.lowercased()
        case let .productSpecific(value):
            output =
                value.product == .clickHouse && value.binaryRepresentation == nil
                ? value.textRepresentation
                : nil
        case .missing, .null, .binary, .array, .object:
            output = nil
        }
        guard let output,
            output.utf8.count <= ClickHouseDatabaseHTTPTransport.maximumParameterValueBytes,
            !output.contains("\0")
        else {
            return nil
        }
        return output
    }

    private static func validateIdentifier(
        _ value: String
    ) throws(DatabaseAdapterFailure) {
        guard !value.isEmpty,
            value.utf8.count <= maximumIdentifierBytes,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func quote(_ value: String) -> String {
        "`\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`"
    }

    private static func stringLiteral(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
    }

    private static func parameter(
        _ name: String,
        _ value: String
    ) -> ClickHouseDatabaseHTTPParameter {
        ClickHouseDatabaseHTTPParameter(name: name, value: value)
    }

    private static func string(_ value: DatabaseValue) -> String? {
        if case let .string(value) = value { return value }
        return nil
    }

    private static func unsigned(_ value: DatabaseValue) -> UInt64? {
        switch value {
        case let .unsignedInteger(value): return value
        case let .signedInteger(value) where value >= 0: return UInt64(value)
        default: return nil
        }
    }
}

private struct ClickHouseDatabaseFilterState {
    var nodes = 0
    var parameters: [ClickHouseDatabaseHTTPParameter] = []
}

private struct ClickHouseDatabaseDigestBinding: Encodable {
    let scope: ClickHouseDatabaseContinuationScope
    let target: DatabaseTargetIdentifier
    let pageSize: Int
    let projection: DatabaseProjection?
    let filter: DatabaseFilter?
    let sorts: [DatabaseSort]
    let consistency: DatabaseConsistencyPreference
    let order: [ClickHouseDatabaseOrderingColumn]
}

private extension DatabaseAdapterPageRequest {
    var recordless: Bool {
        target.record == nil
    }
}
