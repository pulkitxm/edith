import Foundation

private struct MySQLDatabaseReadContinuation: Codable, Equatable, Sendable {
    let sessionID: UUID
    let kind: String
    let path: [String]
    let names: [String]
    let values: [DatabaseValue]
}

private struct MySQLDatabaseColumnMetadata: Equatable, Sendable {
    let name: String
    let typeName: String
    let isNullable: Bool
    let isPrimaryKey: Bool
}

private struct MySQLDatabaseOrderField: Equatable, Sendable {
    let column: MySQLDatabaseColumnMetadata
    let direction: DatabaseSortDirection
}

enum MySQLDatabaseReadSupport {
    private static let maximumResponseBytes = DatabaseAdapterBounds.maximumPageBytes
    private static let systemDatabases = [
        "information_schema", "mysql", "performance_schema", "sys",
    ]

    static func readPage(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        sessionID: DatabaseAdapterSessionID,
        client: any MySQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        guard request.target.connectionID == connectionID, request.target.record == nil else {
            throw MySQLDatabaseAdapterSupport.invalidTarget
        }
        guard [.productDefault, .bestEffort, .session].contains(request.consistency) else {
            throw MySQLDatabaseAdapterSupport.invalidRequest
        }
        guard let object = request.target.object else {
            return try await databases(
                request,
                sessionID: sessionID,
                client: client,
                startedAt: startedAt)
        }
        switch object.kind {
        case .server where object.path.isEmpty:
            return try await databases(
                request,
                sessionID: sessionID,
                client: client,
                startedAt: startedAt)
        case .catalog, .database,
            .schema where object.path.count == 1:
            return try await relations(
                request,
                database: object.path[0],
                sessionID: sessionID,
                client: client,
                startedAt: startedAt)
        case .table,
            .view where object.path.count == 2:
            return try await rows(
                request,
                database: object.path[0],
                table: object.path[1],
                sessionID: sessionID,
                client: client,
                startedAt: startedAt)
        default:
            throw MySQLDatabaseAdapterSupport.invalidTarget
        }
    }

    static func query(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        client: any MySQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        guard request.source.target.connectionID == connectionID,
            request.source.target.record == nil,
            request.language == .sql,
            request.body == nil,
            request.source.continuation == nil,
            request.source.projection == nil,
            request.source.filter == nil,
            request.source.sorts.isEmpty,
            request.parameters.count <= DatabaseExecutionValidator.maximumParameterCount
        else {
            throw MySQLDatabaseAdapterSupport.invalidRequest
        }
        let statement = try readOnlyStatement(request.command)
        let parameters = try request.parameters.map { parameter in
            guard parameter.name == nil else {
                throw MySQLDatabaseAdapterSupport.invalidRequest
            }
            return try bind(parameter.value)
        }
        let limit = request.source.pageSize.value + 1
        let result = try await client.read(
            MySQLDatabaseReadPlan(
                sql: "SELECT * FROM (\(statement)) AS `_edith_query` LIMIT ?",
                binds: parameters + [.signedInteger(Int64(limit))],
                maximumResponseBytes: maximumResponseBytes))
        let hasMore = result.rows.count > request.source.pageSize.value
        let visibleRows = Array(result.rows.prefix(request.source.pageSize.value))
        let fields = try fieldDescriptors(result.columns)
        let records = try visibleRows.map { row in
            try record(row, columns: result.columns, visibleNames: Set(result.columns.map(\.name)))
        }
        let warnings =
            hasMore
            ? [
                DatabaseWarning(
                    code: "mysql.query.truncated",
                    message: "The query result was bounded to the requested page size.",
                    severity: .information)
            ] : []
        return try page(
            records: records,
            fields: fields,
            hasMore: hasMore,
            continuation: nil,
            startedAt: startedAt,
            warnings: warnings)
    }

    private static func databases(
        _ request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        client: any MySQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try requireMetadataRequest(request)
        let continuation = try continuation(
            request.continuation,
            sessionID: sessionID,
            kind: "databases",
            path: [])
        let limit = request.pageSize.value + 1
        let lastName = continuation?.values.first.flatMap(stringValue)
        var sql = """
            SELECT SCHEMA_NAME AS name
            FROM information_schema.SCHEMATA
            """
        var binds: [MySQLDatabaseBind] = []
        if let lastName {
            sql += " WHERE SCHEMA_NAME > ?"
            binds.append(.string(lastName))
        }
        sql += " ORDER BY SCHEMA_NAME LIMIT ?"
        binds.append(.signedInteger(Int64(limit)))
        let result = try await client.read(
            MySQLDatabaseReadPlan(
                sql: sql,
                binds: binds,
                maximumResponseBytes: maximumResponseBytes))
        let hasMore = result.rows.count > request.pageSize.value
        let visible = Array(result.rows.prefix(request.pageSize.value))
        let records = try visible.map { row in
            let name = try string("name", row: row, result: result)
            return DatabaseRecord(
                fields: [
                    DatabaseObjectField(name: "name", value: .string(name)),
                    DatabaseObjectField(
                        name: "system", value: .boolean(systemDatabases.contains(name))),
                ])
        }
        let next =
            try hasMore
            ? makeContinuation(
                sessionID: sessionID,
                kind: "databases",
                path: [],
                names: ["name"],
                values: [try value("name", row: visible.last!, result: result)])
            : nil
        return try page(
            records: records,
            fields: metadataFields([("name", "VARCHAR"), ("system", "BOOLEAN")]),
            hasMore: hasMore,
            continuation: next,
            startedAt: startedAt)
    }

    private static func relations(
        _ request: DatabaseAdapterPageRequest,
        database: String,
        sessionID: DatabaseAdapterSessionID,
        client: any MySQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try requireIdentifier(database)
        try requireMetadataRequest(request)
        let continuation = try continuation(
            request.continuation,
            sessionID: sessionID,
            kind: "relations",
            path: [database])
        let limit = request.pageSize.value + 1
        var sql = """
            SELECT
                TABLE_NAME AS name,
                CASE TABLE_TYPE WHEN 'VIEW' THEN 'view' ELSE 'table' END AS kind,
                COALESCE(ENGINE, '') AS engine,
                TABLE_ROWS AS estimatedRows
            FROM information_schema.TABLES
            WHERE TABLE_SCHEMA = ?
            """
        var binds: [MySQLDatabaseBind] = [.string(database)]
        if let lastName = continuation?.values.first.flatMap(stringValue) {
            sql += " AND TABLE_NAME > ?"
            binds.append(.string(lastName))
        }
        sql += " ORDER BY TABLE_NAME LIMIT ?"
        binds.append(.signedInteger(Int64(limit)))
        let result = try await client.read(
            MySQLDatabaseReadPlan(
                sql: sql,
                binds: binds,
                maximumResponseBytes: maximumResponseBytes))
        let hasMore = result.rows.count > request.pageSize.value
        let visible = Array(result.rows.prefix(request.pageSize.value))
        let records = try visible.map { row in
            DatabaseRecord(fields: [
                DatabaseObjectField(
                    name: "name", value: .string(try string("name", row: row, result: result))),
                DatabaseObjectField(
                    name: "kind", value: .string(try string("kind", row: row, result: result))),
                DatabaseObjectField(
                    name: "engine",
                    value: .string(try string("engine", row: row, result: result))),
                DatabaseObjectField(
                    name: "estimatedRows",
                    value: try value("estimatedRows", row: row, result: result)),
            ])
        }
        let next =
            try hasMore
            ? makeContinuation(
                sessionID: sessionID,
                kind: "relations",
                path: [database],
                names: ["name"],
                values: [try value("name", row: visible.last!, result: result)])
            : nil
        return try page(
            records: records,
            fields: metadataFields([
                ("name", "VARCHAR"), ("kind", "VARCHAR"), ("engine", "VARCHAR"),
                ("estimatedRows", "BIGINT UNSIGNED"),
            ]),
            hasMore: hasMore,
            continuation: next,
            startedAt: startedAt)
    }

    private static func rows(
        _ request: DatabaseAdapterPageRequest,
        database: String,
        table: String,
        sessionID: DatabaseAdapterSessionID,
        client: any MySQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try requireIdentifier(database)
        try requireIdentifier(table)
        let columns = try await columns(database: database, table: table, client: client)
        guard !columns.isEmpty else { throw MySQLDatabaseAdapterSupport.invalidTarget }
        let visible = try visibleColumns(request.projection, columns: columns)
        let order = try orderFields(request.sorts, columns: columns)
        let continuation = try continuation(
            request.continuation,
            sessionID: sessionID,
            kind: "rows",
            path: [database, table])
        if let continuation {
            guard continuation.names == order.map({ $0.column.name }),
                continuation.values.count == order.count
            else {
                throw MySQLDatabaseAdapterSupport.invalidContinuation
            }
        }
        let selected = appendHiddenKeys(visible, order: order)
        var binds: [MySQLDatabaseBind] = []
        var predicates: [String] = []
        if let filter = request.filter {
            predicates.append(try filterSQL(filter, columns: columns, binds: &binds))
        }
        if let continuation {
            predicates.append(
                try keysetSQL(order: order, values: continuation.values, binds: &binds))
        }
        var sql = "SELECT " + selected.map { quote($0.name) }.joined(separator: ", ")
        sql += " FROM \(quote(database)).\(quote(table))"
        if !predicates.isEmpty {
            sql += " WHERE " + predicates.map { "(\($0))" }.joined(separator: " AND ")
        }
        if !order.isEmpty {
            sql +=
                " ORDER BY "
                + order.map { field in
                    quote(field.column.name)
                        + (field.direction == .ascending ? " ASC" : " DESC")
                }.joined(separator: ", ")
        }
        let requestLimit = order.isEmpty ? request.pageSize.value : request.pageSize.value + 1
        sql += " LIMIT ?"
        binds.append(.signedInteger(Int64(requestLimit)))
        let result = try await client.read(
            MySQLDatabaseReadPlan(
                sql: sql,
                binds: binds,
                maximumResponseBytes: maximumResponseBytes))
        let hasMore = !order.isEmpty && result.rows.count > request.pageSize.value
        let visibleRows = Array(result.rows.prefix(request.pageSize.value))
        let visibleNames = Set(visible.map(\.name))
        let records = try visibleRows.map { row in
            try record(row, columns: result.columns, visibleNames: visibleNames)
        }
        let next =
            try hasMore
            ? makeContinuation(
                sessionID: sessionID,
                kind: "rows",
                path: [database, table],
                names: order.map({ $0.column.name }),
                values: try order.map { field in
                    try value(field.column.name, row: visibleRows.last!, result: result)
                })
            : nil
        let warnings =
            order.isEmpty && result.rows.count == request.pageSize.value
            ? [
                DatabaseWarning(
                    code: "mysql.pagination.unstable",
                    message:
                        "This object has no primary key, so only one bounded page is available.",
                    severity: .caution,
                    target: request.target)
            ] : []
        return try page(
            records: records,
            fields: visible.map { fieldDescriptor($0) },
            hasMore: hasMore || !warnings.isEmpty,
            continuation: next,
            startedAt: startedAt,
            warnings: warnings)
    }

    private static func columns(
        database: String,
        table: String,
        client: any MySQLDatabaseClient
    ) async throws -> [MySQLDatabaseColumnMetadata] {
        let result = try await client.read(
            MySQLDatabaseReadPlan(
                sql: """
                    SELECT
                        COLUMN_NAME AS name,
                        COLUMN_TYPE AS typeName,
                        IS_NULLABLE = 'YES' AS nullable,
                        COLUMN_KEY = 'PRI' AS primaryKey
                    FROM information_schema.COLUMNS
                    WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ?
                    ORDER BY ORDINAL_POSITION
                    """,
                binds: [.string(database), .string(table)],
                maximumResponseBytes: maximumResponseBytes))
        guard result.rows.count <= DatabaseAdapterBounds.maximumPageFields else {
            throw MySQLDatabaseAdapterSupport.invalidTarget
        }
        return try result.rows.map { row in
            MySQLDatabaseColumnMetadata(
                name: try string("name", row: row, result: result),
                typeName: try string("typeName", row: row, result: result),
                isNullable: try boolean("nullable", row: row, result: result),
                isPrimaryKey: try boolean("primaryKey", row: row, result: result))
        }
    }

    private static func visibleColumns(
        _ projection: DatabaseProjection?,
        columns: [MySQLDatabaseColumnMetadata]
    ) throws -> [MySQLDatabaseColumnMetadata] {
        guard let projection else { return columns }
        let names = try Set(
            projection.fields.map { field in
                guard field.path.segments.count == 1, field.alias == nil,
                    let name = field.path.segments.first,
                    columns.contains(where: { $0.name == name })
                else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                return name
            })
        let selected = columns.filter { column in
            projection.mode == .include ? names.contains(column.name) : !names.contains(column.name)
        }
        guard !selected.isEmpty else { throw MySQLDatabaseAdapterSupport.invalidRequest }
        return selected
    }

    private static func orderFields(
        _ sorts: [DatabaseSort],
        columns: [MySQLDatabaseColumnMetadata]
    ) throws -> [MySQLDatabaseOrderField] {
        let primaryKeys = columns.filter(\.isPrimaryKey)
        guard !primaryKeys.isEmpty else {
            guard sorts.isEmpty else { throw MySQLDatabaseAdapterSupport.invalidRequest }
            return []
        }
        var result: [MySQLDatabaseOrderField] = []
        var seen: Set<String> = []
        for sort in sorts {
            guard sort.field.segments.count == 1,
                let name = sort.field.segments.first,
                let column = primaryKeys.first(where: { $0.name == name }),
                sort.nullPlacement == .productDefault,
                seen.insert(name).inserted
            else {
                throw MySQLDatabaseAdapterSupport.invalidRequest
            }
            result.append(MySQLDatabaseOrderField(column: column, direction: sort.direction))
        }
        for column in primaryKeys where seen.insert(column.name).inserted {
            result.append(MySQLDatabaseOrderField(column: column, direction: .ascending))
        }
        return result
    }

    private static func appendHiddenKeys(
        _ visible: [MySQLDatabaseColumnMetadata],
        order: [MySQLDatabaseOrderField]
    ) -> [MySQLDatabaseColumnMetadata] {
        var result = visible
        let existing = Set(visible.map(\.name))
        result.append(contentsOf: order.map(\.column).filter { !existing.contains($0.name) })
        return result
    }

    private static func filterSQL(
        _ filter: DatabaseFilter,
        columns: [MySQLDatabaseColumnMetadata],
        binds: inout [MySQLDatabaseBind]
    ) throws -> String {
        switch filter {
        case .predicate(let predicate):
            guard predicate.field.segments.count == 1,
                let name = predicate.field.segments.first,
                columns.contains(where: { $0.name == name })
            else {
                throw MySQLDatabaseAdapterSupport.invalidRequest
            }
            let field = quote(name)
            switch predicate.operation {
            case .isNull, .isNotNull:
                guard predicate.values.isEmpty else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                return field + (predicate.operation == .isNull ? " IS NULL" : " IS NOT NULL")
            case .equal, .notEqual, .greaterThan, .greaterThanOrEqual, .lessThan,
                .lessThanOrEqual:
                guard predicate.values.count == 1 else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                binds.append(try bind(predicate.values[0]))
                let operation: String =
                    switch predicate.operation {
                    case .equal: " = "
                    case .notEqual: " <> "
                    case .greaterThan: " > "
                    case .greaterThanOrEqual: " >= "
                    case .lessThan: " < "
                    default: " <= "
                    }
                return caseAdjusted(field, predicate: predicate) + operation
                    + caseAdjusted("?", predicate: predicate)
            case .contains, .startsWith, .endsWith:
                guard predicate.values.count == 1,
                    let value = stringValue(predicate.values[0])
                else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern: String =
                    switch predicate.operation {
                    case .contains: "%\(escaped)%"
                    case .startsWith: "\(escaped)%"
                    default: "%\(escaped)"
                    }
                binds.append(.string(pattern))
                return caseAdjusted(field, predicate: predicate) + " LIKE "
                    + caseAdjusted("?", predicate: predicate) + " ESCAPE '\\\\'"
            case .in, .notIn:
                guard !predicate.values.isEmpty,
                    predicate.values.count <= DatabaseExecutionValidator.maximumParameterCount
                else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                binds.append(contentsOf: try predicate.values.map(bind))
                return field + (predicate.operation == .in ? " IN (" : " NOT IN (")
                    + Array(repeating: "?", count: predicate.values.count).joined(separator: ", ")
                    + ")"
            case .between:
                guard predicate.values.count == 2 else {
                    throw MySQLDatabaseAdapterSupport.invalidRequest
                }
                binds.append(contentsOf: try predicate.values.map(bind))
                return field + " BETWEEN ? AND ?"
            case .isMissing, .isNotMissing, .regularExpression, .fullText:
                throw MySQLDatabaseAdapterSupport.invalidRequest
            }
        case .all(let filters), .any(let filters):
            guard !filters.isEmpty else { throw MySQLDatabaseAdapterSupport.invalidRequest }
            let separator = if case .all = filter { " AND " } else { " OR " }
            return try filters.map { child in
                "(" + (try filterSQL(child, columns: columns, binds: &binds)) + ")"
            }.joined(separator: separator)
        case .not(let child):
            return "NOT (" + (try filterSQL(child, columns: columns, binds: &binds)) + ")"
        }
    }

    private static func keysetSQL(
        order: [MySQLDatabaseOrderField],
        values: [DatabaseValue],
        binds: inout [MySQLDatabaseBind]
    ) throws -> String {
        guard !order.isEmpty, order.count == values.count else {
            throw MySQLDatabaseAdapterSupport.invalidContinuation
        }
        var clauses: [String] = []
        for index in order.indices {
            var terms: [String] = []
            for prefix in 0..<index {
                terms.append(quote(order[prefix].column.name) + " = ?")
                binds.append(try bind(values[prefix]))
            }
            let comparison = order[index].direction == .ascending ? " > ?" : " < ?"
            terms.append(quote(order[index].column.name) + comparison)
            binds.append(try bind(values[index]))
            clauses.append("(" + terms.joined(separator: " AND ") + ")")
        }
        return clauses.joined(separator: " OR ")
    }

    private static func record(
        _ row: MySQLDatabaseReadRow,
        columns: [MySQLDatabaseReadColumn],
        visibleNames: Set<String>
    ) throws -> DatabaseRecord {
        guard row.values.count == columns.count else {
            throw MySQLDatabaseAdapterSupport.readFailed
        }
        let pairs = Array(zip(columns, row.values))
        let fields = pairs.compactMap { column, value in
            visibleNames.contains(column.name)
                ? DatabaseObjectField(name: column.name, value: value) : nil
        }
        let keys = pairs.compactMap { column, value in
            column.isPrimaryKey
                ? DatabaseIdentityComponent(name: column.name, value: value) : nil
        }
        return DatabaseRecord(
            identity: keys.isEmpty
                ? nil : DatabaseRecordIdentity(kind: .primaryKey, components: keys),
            fields: fields)
    }

    private static func fieldDescriptors(
        _ columns: [MySQLDatabaseReadColumn]
    ) throws -> [DatabaseFieldDescriptor] {
        guard columns.count <= DatabaseAdapterBounds.maximumPageFields else {
            throw MySQLDatabaseAdapterSupport.readFailed
        }
        return columns.map { column in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(column.name),
                displayName: column.name,
                typeName: column.typeName,
                isNullable: column.isNullable,
                isSortable: column.isPrimaryKey,
                isFilterable: true)
        }
    }

    private static func fieldDescriptor(
        _ column: MySQLDatabaseColumnMetadata
    ) -> DatabaseFieldDescriptor {
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath(column.name),
            displayName: column.name,
            typeName: column.typeName,
            isNullable: column.isNullable,
            isSortable: column.isPrimaryKey,
            isFilterable: true)
    }

    private static func metadataFields(
        _ values: [(String, String)]
    ) -> [DatabaseFieldDescriptor] {
        values.map { name, typeName in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(name),
                displayName: name,
                typeName: typeName,
                isNullable: true,
                isSortable: name == "name",
                isFilterable: name == "name")
        }
    }

    private static func page(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor],
        hasMore: Bool,
        continuation: DatabaseAdapterContinuation?,
        startedAt: Date,
        warnings: [DatabaseWarning] = []
    ) throws -> DatabaseAdapterPage {
        let elapsed = max(0, Date().timeIntervalSince(startedAt) * 1_000)
        return try DatabaseAdapterPage(
            records: records,
            fields: fields,
            nextContinuation: continuation,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: hasMore ? .partial : .complete,
                    reason: hasMore ? "More data may be available." : nil),
                count: DatabaseCountMetadata(
                    value: UInt64(records.count),
                    accuracy: hasMore ? .lowerBound : .exact),
                timing: DatabaseQueryTiming(durationMilliseconds: UInt64(elapsed.rounded())),
                warnings: warnings))
    }

    private static func requireMetadataRequest(
        _ request: DatabaseAdapterPageRequest
    ) throws {
        guard request.projection == nil, request.filter == nil, request.sorts.isEmpty else {
            throw MySQLDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func continuation(
        _ value: DatabaseAdapterContinuation?,
        sessionID: DatabaseAdapterSessionID,
        kind: String,
        path: [String]
    ) throws -> MySQLDatabaseReadContinuation? {
        guard let value else { return nil }
        guard value.mode == .keyset,
            value.expiresAt.map({ $0 > Date() }) ?? true,
            let decoded = try? JSONDecoder().decode(
                MySQLDatabaseReadContinuation.self,
                from: value.payload),
            decoded.sessionID == sessionID.rawValue,
            decoded.kind == kind,
            decoded.path == path
        else {
            throw MySQLDatabaseAdapterSupport.invalidContinuation
        }
        return decoded
    }

    private static func makeContinuation(
        sessionID: DatabaseAdapterSessionID,
        kind: String,
        path: [String],
        names: [String],
        values: [DatabaseValue]
    ) throws -> DatabaseAdapterContinuation {
        do {
            let data = try JSONEncoder().encode(
                MySQLDatabaseReadContinuation(
                    sessionID: sessionID.rawValue,
                    kind: kind,
                    path: path,
                    names: names,
                    values: values))
            return try DatabaseAdapterContinuation(mode: .keyset, payload: data)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw MySQLDatabaseAdapterSupport.invalidContinuation
        }
    }

    private static func readOnlyStatement(
        _ command: String
    ) throws -> String {
        var statement = command.trimmingCharacters(in: .whitespacesAndNewlines)
        while statement.hasSuffix(";") {
            statement.removeLast()
            statement = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !statement.isEmpty,
            statement.utf8.count <= DatabaseExecutionValidator.maximumCommandBytes,
            !statement.contains("\0"),
            !statement.contains(";"),
            let keyword = statement.split(whereSeparator: { $0.isWhitespace }).first?
                .lowercased(),
            ["select", "with"].contains(keyword)
        else {
            throw MySQLDatabaseAdapterSupport.readOnlyViolation
        }
        return statement
    }

    private static func bind(
        _ value: DatabaseValue
    ) throws -> MySQLDatabaseBind {
        switch value {
        case .null:
            return .null
        case .boolean(let value):
            return .boolean(value)
        case .signedInteger(let value):
            return .signedInteger(value)
        case .unsignedInteger(let value):
            return .unsignedInteger(value)
        case .decimal(let value):
            return .decimal(value.rawValue)
        case .floatingPoint(let value) where value.isFinite:
            return .floatingPoint(value)
        case .string(let value):
            return .string(value)
        case .binary(let value) where value.isComplete:
            return .binary(value.availableBytes)
        case .date(let value):
            return .string(value.text)
        case .time(let value):
            return .string(value.text)
        case .timestamp(let value):
            return .string(value.text)
        case .uuid(let value):
            return .string(value.uuidString)
        case .productSpecific(let value):
            if let text = value.textRepresentation { return .string(text) }
            if let binary = value.binaryRepresentation { return .binary(binary) }
            fallthrough
        case .missing, .floatingPoint, .binary, .array, .object:
            throw MySQLDatabaseAdapterSupport.invalidRequest
        }
    }

    private static func caseAdjusted(
        _ expression: String,
        predicate: DatabaseFilterPredicate
    ) -> String {
        predicate.caseSensitivity == .insensitive ? "LOWER(\(expression))" : expression
    }

    private static func quote(_ identifier: String) -> String {
        "`" + identifier.replacingOccurrences(of: "`", with: "``") + "`"
    }

    private static func requireIdentifier(
        _ value: String
    ) throws {
        guard !value.isEmpty, value.utf8.count <= 1_024, !value.contains("\0"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw MySQLDatabaseAdapterSupport.invalidTarget
        }
    }

    private static func value(
        _ name: String,
        row: MySQLDatabaseReadRow,
        result: MySQLDatabaseReadResult
    ) throws -> DatabaseValue {
        guard let index = result.columns.firstIndex(where: { $0.name == name }),
            row.values.indices.contains(index)
        else {
            throw MySQLDatabaseAdapterSupport.readFailed
        }
        return row.values[index]
    }

    private static func string(
        _ name: String,
        row: MySQLDatabaseReadRow,
        result: MySQLDatabaseReadResult
    ) throws -> String {
        switch try value(name, row: row, result: result) {
        case .string(let value):
            return value
        case .binary(let value) where value.isComplete:
            guard let text = String(data: value.availableBytes, encoding: .utf8) else {
                throw MySQLDatabaseAdapterSupport.readFailed
            }
            return text
        default:
            throw MySQLDatabaseAdapterSupport.readFailed
        }
    }

    private static func boolean(
        _ name: String,
        row: MySQLDatabaseReadRow,
        result: MySQLDatabaseReadResult
    ) throws -> Bool {
        switch try value(name, row: row, result: result) {
        case .boolean(let value): return value
        case .signedInteger(let value): return value != 0
        case .unsignedInteger(let value): return value != 0
        default: throw MySQLDatabaseAdapterSupport.readFailed
        }
    }

    private static func stringValue(_ value: DatabaseValue) -> String? {
        if case .string(let value) = value { return value }
        return nil
    }
}
