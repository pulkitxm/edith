import Crypto
import Foundation
import PostgresNIO

private enum PostgreSQLDatabaseReadContinuationKind: String, Codable, Sendable {
    case schemas
    case relations
    case browse
    case query
}

private struct PostgreSQLDatabaseReadContinuationPayload: Codable, Sendable {
    let version: Int
    let sessionID: UUID
    let kind: PostgreSQLDatabaseReadContinuationKind
    let mode: DatabasePagingMode
    let requestDigest: String
    let position: UInt64
    let key: DatabaseValue?
    let expiresAt: Date
}

private struct PostgreSQLDatabaseReadFingerprint: Codable {
    let target: DatabaseTargetIdentifier
    let pageSize: Int
    let projection: DatabaseProjection?
    let filter: DatabaseFilter?
    let sorts: [DatabaseSort]
    let consistency: DatabaseConsistencyPreference
    let command: String?
    let parameters: [DatabaseQueryParameter]?
}

private struct PostgreSQLDatabaseReadColumn: Sendable {
    let name: String
    let typeName: String
    let typeOID: UInt32
    let isNullable: Bool
    let ordinal: Int
}

private struct PostgreSQLDatabaseReadRelation: Sendable {
    let schema: String
    let name: String
    let kind: DatabaseObjectKind
    let columns: [PostgreSQLDatabaseReadColumn]
    let keyColumn: PostgreSQLDatabaseReadColumn?
    let keyKind: DatabaseRecordIdentityKind?
}

private struct PostgreSQLDatabaseReadSelectedColumn: Sendable {
    let source: PostgreSQLDatabaseReadColumn
    let outputName: String
}

private struct PostgreSQLDatabaseReadSQLFragment: Sendable {
    let sql: String
    let parameters: [DatabaseValue]
}

private struct PostgreSQLDatabaseReadCursor: Sendable {
    let mode: DatabasePagingMode
    let position: UInt64
    let key: DatabaseValue?
}

enum PostgreSQLDatabaseReadSupport {
    static func readPage(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID,
        sessionID: DatabaseAdapterSessionID,
        client: any PostgreSQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try validateCommon(request, connectionID: connectionID)
        let digest = try fingerprint(request: request, command: nil, parameters: nil)
        guard let object = request.target.object else {
            return try await schemas(
                request,
                sessionID: sessionID,
                digest: digest,
                client: client,
                startedAt: startedAt)
        }
        switch object.kind {
        case .server, .catalog, .database:
            guard object.nativeIdentifier == nil, object.path.count <= 1 else {
                throw PostgreSQLDatabaseAdapterSupport.invalidRead
            }
            return try await schemas(
                request,
                sessionID: sessionID,
                digest: digest,
                client: client,
                startedAt: startedAt)
        case .schema:
            guard object.nativeIdentifier == nil, object.path.count == 1 else {
                throw PostgreSQLDatabaseAdapterSupport.invalidRead
            }
            try validateIdentifier(object.path[0])
            return try await relations(
                request,
                schema: object.path[0],
                sessionID: sessionID,
                digest: digest,
                client: client,
                startedAt: startedAt)
        case .table, .view, .materializedView:
            return try await browse(
                request,
                expectedKind: object.kind,
                connectionID: connectionID,
                sessionID: sessionID,
                digest: digest,
                client: client,
                startedAt: startedAt)
        default:
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
    }

    static func query(
        _ request: DatabaseAdapterQueryRequest,
        connectionID: DatabaseConnectionID,
        sessionID: DatabaseAdapterSessionID,
        client: any PostgreSQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try validateCommon(request.source, connectionID: connectionID)
        try validateQueryTarget(request.source.target, connectionID: connectionID)
        guard request.language == .sql,
            request.body == nil,
            request.command.utf8.count <= PostgreSQLDatabaseReadBounds.maximumCommandBytes,
            request.parameters.count <= PostgreSQLDatabaseReadBounds.maximumParameters,
            request.parameters.allSatisfy({ $0.name == nil })
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        try validateReadOnlySQL(
            request.command,
            parameterCount: request.parameters.count)
        let digest = try fingerprint(
            request: request.source,
            command: request.command,
            parameters: request.parameters)
        let cursor = try continuation(
            request.source.continuation,
            expectedMode: .offset,
            kind: .query,
            sessionID: sessionID,
            digest: digest)
        let selection = try querySelection(request.source.projection)
        let filter = try filterSQL(
            request.source.filter,
            available: nil,
            sourceAlias: "_edith_query",
            firstParameter: request.parameters.count + 1,
            failure: PostgreSQLDatabaseAdapterSupport.invalidQuery)
        let order = try orderSQL(
            request.source.sorts,
            available: nil,
            sourceAlias: "_edith_query",
            failure: PostgreSQLDatabaseAdapterSupport.invalidQuery)
        let limit = request.source.pageSize.value + 1
        var sql = "SELECT \(selection) FROM (\(request.command)\n) AS \(quote("_edith_query"))"
        if !filter.sql.isEmpty {
            sql += " WHERE \(filter.sql)"
        }
        if !order.isEmpty {
            sql += " ORDER BY \(order.joined(separator: ", "))"
        }
        sql += " LIMIT \(limit) OFFSET \(cursor.position)"
        let plan = try PostgreSQLDatabaseReadPlan(
            sql: sql,
            parameters: request.parameters.map(\.value) + filter.parameters,
            maximumRows: limit)
        let result = try await client.executeRead(plan)
        let visibleRows = Array(result.rows.prefix(request.source.pageSize.value))
        let fields = try queryFields(visibleRows.first)
        let records = try visibleRows.map { row in
            try record(row, fields: fields, preferredTypes: [:])
        }
        let hasMore = result.rows.count > request.source.pageSize.value
        var warnings = [offsetWarning(target: request.source.target)]
        if request.source.sorts.isEmpty {
            warnings.append(
                DatabaseWarning(
                    code: "postgresql.query.order.unspecified",
                    message: "Query paging has no stable caller-specified order.",
                    severity: .caution,
                    target: request.source.target))
        }
        return try page(
            records: records,
            fields: fields,
            hasMore: hasMore,
            cursor: cursor,
            nextKey: nil,
            kind: .query,
            sessionID: sessionID,
            digest: digest,
            target: request.source.target,
            warnings: warnings,
            bytesReceived: result.bytesReceived,
            startedAt: startedAt)
    }

    private static func schemas(
        _ request: DatabaseAdapterPageRequest,
        sessionID: DatabaseAdapterSessionID,
        digest: String,
        client: any PostgreSQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try requireDiscoveryShape(request)
        let cursor = try continuation(
            request.continuation,
            expectedMode: .offset,
            kind: .schemas,
            sessionID: sessionID,
            digest: digest)
        let limit = request.pageSize.value + 1
        let sql = """
            SELECT
                n.nspname::text AS schema_name,
                pg_catalog.has_schema_privilege(n.oid, 'USAGE') AS can_use,
                pg_catalog.has_schema_privilege(n.oid, 'CREATE') AS can_create
            FROM pg_catalog.pg_namespace AS n
            WHERE n.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
                AND n.nspname <> 'information_schema'
            ORDER BY n.nspname
            LIMIT \(limit) OFFSET \(cursor.position)
            """
        let result = try await client.executeRead(
            PostgreSQLDatabaseReadPlan(sql: sql, maximumRows: limit))
        let rows = Array(result.rows.prefix(request.pageSize.value))
        let records = try rows.map { row in
            DatabaseRecord(
                fields: [
                    DatabaseObjectField(
                        name: "name",
                        value: .string(try requiredString("schema_name", in: row))),
                    DatabaseObjectField(
                        name: "canUse",
                        value: .boolean(try requiredBool("can_use", in: row))),
                    DatabaseObjectField(
                        name: "canCreate",
                        value: .boolean(try requiredBool("can_create", in: row))),
                ])
        }
        return try page(
            records: records,
            fields: schemaFields,
            hasMore: result.rows.count > request.pageSize.value,
            cursor: cursor,
            nextKey: nil,
            kind: .schemas,
            sessionID: sessionID,
            digest: digest,
            target: request.target,
            warnings: [offsetWarning(target: request.target)],
            bytesReceived: result.bytesReceived,
            startedAt: startedAt)
    }

    private static func relations(
        _ request: DatabaseAdapterPageRequest,
        schema: String,
        sessionID: DatabaseAdapterSessionID,
        digest: String,
        client: any PostgreSQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        try requireDiscoveryShape(request)
        let cursor = try continuation(
            request.continuation,
            expectedMode: .offset,
            kind: .relations,
            sessionID: sessionID,
            digest: digest)
        let limit = request.pageSize.value + 1
        let sql = """
            SELECT
                c.relname::text AS relation_name,
                CASE c.relkind
                    WHEN 'r' THEN 'table'
                    WHEN 'p' THEN 'table'
                    WHEN 'f' THEN 'table'
                    WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'materializedView'
                END::text AS relation_kind,
                GREATEST(c.reltuples, 0)::int8 AS estimated_rows,
                (
                    SELECT count(*)::int8
                    FROM pg_catalog.pg_attribute AS a
                    WHERE a.attrelid = c.oid
                        AND a.attnum > 0
                        AND NOT a.attisdropped
                ) AS column_count
            FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
            WHERE n.nspname = $1
                AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
            ORDER BY c.relname, c.oid
            LIMIT \(limit) OFFSET \(cursor.position)
            """
        let result = try await client.executeRead(
            PostgreSQLDatabaseReadPlan(
                sql: sql,
                parameters: [.string(schema)],
                maximumRows: limit))
        let rows = Array(result.rows.prefix(request.pageSize.value))
        let records = try rows.map { row in
            DatabaseRecord(
                fields: [
                    DatabaseObjectField(
                        name: "name",
                        value: .string(try requiredString("relation_name", in: row))),
                    DatabaseObjectField(
                        name: "kind",
                        value: .string(try requiredString("relation_kind", in: row))),
                    DatabaseObjectField(
                        name: "estimatedRows",
                        value: .signedInteger(try requiredInt64("estimated_rows", in: row))),
                    DatabaseObjectField(
                        name: "columnCount",
                        value: .signedInteger(try requiredInt64("column_count", in: row))),
                ])
        }
        return try page(
            records: records,
            fields: relationFields,
            hasMore: result.rows.count > request.pageSize.value,
            cursor: cursor,
            nextKey: nil,
            kind: .relations,
            sessionID: sessionID,
            digest: digest,
            target: request.target,
            warnings: [offsetWarning(target: request.target)],
            bytesReceived: result.bytesReceived,
            startedAt: startedAt)
    }
}

extension PostgreSQLDatabaseReadSupport {
    private static func browse(
        _ request: DatabaseAdapterPageRequest,
        expectedKind: DatabaseObjectKind,
        connectionID: DatabaseConnectionID,
        sessionID: DatabaseAdapterSessionID,
        digest: String,
        client: any PostgreSQLDatabaseClient,
        startedAt: Date
    ) async throws -> DatabaseAdapterPage {
        guard let object = request.target.object,
            object.nativeIdentifier == nil,
            object.path.count == 2
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
        let schema = object.path[0]
        let name = object.path[1]
        try validateIdentifier(schema)
        try validateIdentifier(name)
        let relation = try await relation(
            schema: schema,
            name: name,
            expectedKind: expectedKind,
            client: client)
        let selected = try selectedColumns(
            relation.columns,
            projection: request.projection)
        let keysetAvailable =
            request.sorts.isEmpty
            && relation.keyColumn.map(keysetType) == true
        let mode: DatabasePagingMode = keysetAvailable ? .keyset : .offset
        let cursor = try continuation(
            request.continuation,
            expectedMode: mode,
            kind: .browse,
            sessionID: sessionID,
            digest: digest)
        let sourceAlias = "_edith_relation"
        let filter = try filterSQL(
            request.filter,
            available: relation.columns,
            sourceAlias: sourceAlias,
            firstParameter: 1,
            failure: PostgreSQLDatabaseAdapterSupport.invalidRead)
        var predicates: [String] = []
        if !filter.sql.isEmpty {
            predicates.append(filter.sql)
        }
        var parameters = filter.parameters
        if mode == .keyset, let keyColumn = relation.keyColumn, let key = cursor.key {
            parameters.append(key)
            predicates.append(
                "\(qualified(sourceAlias, keyColumn.name)) > $\(parameters.count)")
        }
        var selections = selected.map { column in
            "\(qualified(sourceAlias, column.source.name)) AS \(quote(column.outputName))"
        }
        if let keyColumn = relation.keyColumn {
            selections.append(
                "\(qualified(sourceAlias, keyColumn.name)) AS \(quote("__edith_postgresql_key"))")
        }
        let order: [String]
        if mode == .keyset, let keyColumn = relation.keyColumn {
            order = ["\(qualified(sourceAlias, keyColumn.name)) ASC"]
        } else if !request.sorts.isEmpty {
            var requested = try orderSQL(
                request.sorts,
                available: relation.columns,
                sourceAlias: sourceAlias,
                failure: PostgreSQLDatabaseAdapterSupport.invalidRead)
            if let keyColumn = relation.keyColumn,
                !request.sorts.contains(where: { $0.field.segments == [keyColumn.name] })
            {
                requested.append("\(qualified(sourceAlias, keyColumn.name)) ASC")
            }
            order = requested
        } else if let keyColumn = relation.keyColumn {
            order = ["\(qualified(sourceAlias, keyColumn.name)) ASC"]
        } else {
            order = ["\(quote(sourceAlias)).ctid ASC"]
        }
        let limit = request.pageSize.value + 1
        var sql = "SELECT \(selections.joined(separator: ", ")) FROM "
        sql += " \(quote(relation.schema)).\(quote(relation.name)) AS \(quote(sourceAlias))"
        if !predicates.isEmpty {
            sql += " WHERE \(predicates.joined(separator: " AND "))"
        }
        sql += " ORDER BY \(order.joined(separator: ", ")) LIMIT \(limit)"
        if mode == .offset {
            sql += " OFFSET \(cursor.position)"
        }
        let result = try await client.executeRead(
            PostgreSQLDatabaseReadPlan(
                sql: sql,
                parameters: parameters,
                maximumRows: limit))
        let visibleRows = Array(result.rows.prefix(request.pageSize.value))
        let preferredTypes = Dictionary(
            uniqueKeysWithValues: selected.map { ($0.outputName, $0.source.typeName) })
        var records: [DatabaseRecord] = []
        records.reserveCapacity(visibleRows.count)
        var lastKey: DatabaseValue?
        for row in visibleRows {
            let identity: DatabaseRecordIdentity?
            if let keyColumn = relation.keyColumn, let keyKind = relation.keyKind {
                let key = try requiredValue(
                    "__edith_postgresql_key",
                    in: row,
                    preferredType: keyColumn.typeName)
                guard key != .null, key != .missing else {
                    throw PostgreSQLDatabaseAdapterSupport.decodingFailed
                }
                lastKey = key
                identity = DatabaseRecordIdentity(
                    kind: keyKind,
                    components: [
                        DatabaseIdentityComponent(name: keyColumn.name, value: key)
                    ])
            } else {
                identity = nil
            }
            records.append(
                try record(
                    row,
                    fields: selected.map(\.outputName),
                    preferredTypes: preferredTypes,
                    identity: identity))
        }
        let fields = selected.map { selected in
            DatabaseFieldDescriptor(
                path: DatabaseFieldPath(selected.outputName),
                displayName: selected.outputName,
                typeName: selected.source.typeName,
                isNullable: selected.source.isNullable,
                isSortable: sortable(selected.source),
                isFilterable: filterable(selected.source))
        }
        let hasMore = result.rows.count > request.pageSize.value
        let warnings = mode == .offset ? [offsetWarning(target: request.target)] : []
        return try page(
            records: records,
            fields: fields,
            hasMore: hasMore,
            cursor: cursor,
            nextKey: mode == .keyset ? lastKey : nil,
            kind: .browse,
            sessionID: sessionID,
            digest: digest,
            target: request.target,
            warnings: warnings,
            bytesReceived: result.bytesReceived,
            startedAt: startedAt)
    }

    private static func relation(
        schema: String,
        name: String,
        expectedKind: DatabaseObjectKind,
        client: any PostgreSQLDatabaseClient
    ) async throws -> PostgreSQLDatabaseReadRelation {
        let sql = """
            SELECT
                a.attname::text AS column_name,
                pg_catalog.format_type(a.atttypid, a.atttypmod)::text AS type_name,
                a.atttypid::int8 AS type_oid,
                NOT a.attnotnull AS is_nullable,
                a.attnum::int8 AS ordinal,
                CASE c.relkind
                    WHEN 'r' THEN 'table'
                    WHEN 'p' THEN 'table'
                    WHEN 'f' THEN 'table'
                    WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'materializedView'
                END::text AS relation_kind,
                COALESCE(a.attnum = key.key_attnum, false) AS is_key,
                COALESCE(key.is_primary, false) AS key_is_primary
            FROM pg_catalog.pg_class AS c
            JOIN pg_catalog.pg_namespace AS n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_attribute AS a ON a.attrelid = c.oid
            LEFT JOIN LATERAL (
                SELECT
                    min(member.attnum)::int2 AS key_attnum,
                    index.indisprimary AS is_primary
                FROM pg_catalog.pg_index AS index
                CROSS JOIN LATERAL unnest(index.indkey) AS member(attnum)
                JOIN pg_catalog.pg_attribute AS key_attribute
                    ON key_attribute.attrelid = index.indrelid
                    AND key_attribute.attnum = member.attnum
                WHERE index.indrelid = c.oid
                    AND index.indisunique
                    AND index.indisvalid
                    AND index.indpred IS NULL
                    AND index.indexprs IS NULL
                GROUP BY index.indexrelid, index.indisprimary
                HAVING count(*) = 1 AND bool_and(key_attribute.attnotnull)
                ORDER BY index.indisprimary DESC, index.indexrelid
                LIMIT 1
            ) AS key ON true
            WHERE n.nspname = $1
                AND c.relname = $2
                AND c.relkind IN ('r', 'p', 'f', 'v', 'm')
                AND a.attnum > 0
                AND NOT a.attisdropped
            ORDER BY a.attnum
            LIMIT \(PostgreSQLDatabaseReadBounds.maximumMetadataRows)
            """
        let result = try await client.executeRead(
            PostgreSQLDatabaseReadPlan(
                sql: sql,
                parameters: [.string(schema), .string(name)],
                maximumRows: PostgreSQLDatabaseReadBounds.maximumMetadataRows))
        guard !result.rows.isEmpty,
            result.rows.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
        var columns: [PostgreSQLDatabaseReadColumn] = []
        columns.reserveCapacity(result.rows.count)
        var relationKind: DatabaseObjectKind?
        var keyName: String?
        var keyIsPrimary = false
        for row in result.rows {
            let name = try requiredString("column_name", in: row)
            let typeName = try requiredString("type_name", in: row)
            let typeOID = try requiredInt64("type_oid", in: row)
            let ordinal = try requiredInt64("ordinal", in: row)
            let kind = try objectKind(try requiredString("relation_kind", in: row))
            guard let oid = UInt32(exactly: typeOID),
                let ordinalValue = Int(exactly: ordinal),
                relationKind == nil || relationKind == kind
            else {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            relationKind = kind
            let column = PostgreSQLDatabaseReadColumn(
                name: name,
                typeName: typeName,
                typeOID: oid,
                isNullable: try requiredBool("is_nullable", in: row),
                ordinal: ordinalValue)
            columns.append(column)
            if try requiredBool("is_key", in: row) {
                guard keyName == nil else {
                    throw PostgreSQLDatabaseAdapterSupport.decodingFailed
                }
                keyName = name
                keyIsPrimary = try requiredBool("key_is_primary", in: row)
            }
        }
        guard relationKind == expectedKind,
            Set(columns.map(\.name)).count == columns.count
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
        let keyColumn = keyName.flatMap { selectedName in
            columns.first { $0.name == selectedName }
        }
        return PostgreSQLDatabaseReadRelation(
            schema: schema,
            name: name,
            kind: expectedKind,
            columns: columns,
            keyColumn: keyColumn,
            keyKind: keyColumn == nil
                ? nil
                : (keyIsPrimary ? .primaryKey : .uniqueKey))
    }
}

enum PostgreSQLDatabaseReadValueSupport {
    static func value(
        _ cell: PostgresCell,
        preferredTypeName: String? = nil
    ) throws -> DatabaseValue {
        guard cell.bytes != nil else { return .null }
        do {
            switch cell.dataType {
            case .bool:
                return .boolean(try cell.decode(Bool.self))
            case .int2:
                return .signedInteger(Int64(try cell.decode(Int16.self)))
            case .int4:
                return .signedInteger(Int64(try cell.decode(Int32.self)))
            case .int8:
                return .signedInteger(try cell.decode(Int64.self))
            case .oid:
                let data = try rawData(cell)
                guard cell.format == .binary, data.count == 4 else {
                    throw PostgreSQLDatabaseDriverFailure.decoding
                }
                return .unsignedInteger(UInt64(readUInt32(data, at: 0)))
            case .float4:
                return .floatingPoint(Double(try cell.decode(Float.self)))
            case .float8:
                return .floatingPoint(try cell.decode(Double.self))
            case .numeric:
                return try numeric(cell)
            case .text, .varchar, .bpchar, .name:
                let text = try cell.decode(String.self)
                guard validBoundString(text) else {
                    throw PostgreSQLDatabaseDriverFailure.resultTooLarge
                }
                return .string(text)
            case .json, .jsonb:
                let text = try cell.decode(String.self)
                guard validBoundString(text) else {
                    throw PostgreSQLDatabaseDriverFailure.resultTooLarge
                }
                return .productSpecific(
                    DatabaseProductValue(
                        product: .postgresql,
                        typeName: preferredTypeName ?? cell.dataType.description,
                        textRepresentation: text))
            case .uuid:
                return .uuid(try cell.decode(UUID.self))
            case .bytea:
                return .binary(
                    .complete(
                        data: try rawData(cell),
                        mediaType: "application/octet-stream",
                        digest: nil))
            case .date:
                return try date(cell)
            case .timestamp:
                return try timestamp(cell, includesTimeZone: false)
            case .timestamptz:
                return try timestamp(cell, includesTimeZone: true)
            case .time, .timetz:
                return try time(cell)
            case .boolArray:
                return try array(try cell.decode([Bool].self), transform: DatabaseValue.boolean)
            case .int2Array:
                return try array(try cell.decode([Int16].self)) {
                    .signedInteger(Int64($0))
                }
            case .int4Array:
                return try array(try cell.decode([Int32].self)) {
                    .signedInteger(Int64($0))
                }
            case .int8Array:
                return try array(
                    try cell.decode([Int64].self), transform: DatabaseValue.signedInteger)
            case .float4Array:
                return try array(try cell.decode([Float].self)) {
                    .floatingPoint(Double($0))
                }
            case .float8Array:
                return try array(
                    try cell.decode([Double].self), transform: DatabaseValue.floatingPoint)
            case .textArray, .varcharArray, .bpcharArray, .nameArray:
                return try array(try cell.decode([String].self)) { value in
                    guard validBoundString(value) else {
                        throw PostgreSQLDatabaseDriverFailure.resultTooLarge
                    }
                    return .string(value)
                }
            case .uuidArray:
                return try array(try cell.decode([UUID].self), transform: DatabaseValue.uuid)
            case .dateArray:
                return try array(try cell.decode([Date].self)) {
                    .date(DatabaseDateValue(text: dateText($0), calendarIdentifier: "gregorian"))
                }
            case .timestampArray:
                return try array(try cell.decode([Date].self)) {
                    .timestamp(
                        DatabaseTimestampValue(
                            text: timestampText($0, includesTimeZone: false),
                            precision: 6))
                }
            case .timestamptzArray:
                return try array(try cell.decode([Date].self)) {
                    .timestamp(
                        DatabaseTimestampValue(
                            text: timestampText($0, includesTimeZone: true),
                            timeZoneIdentifier: "UTC",
                            timeZoneOffsetMinutes: 0,
                            precision: 6))
                }
            default:
                return try productSpecific(cell, preferredTypeName: preferredTypeName)
            }
        } catch let failure as PostgreSQLDatabaseDriverFailure {
            throw failure
        } catch {
            throw PostgreSQLDatabaseDriverFailure.decoding
        }
    }

    static func validDecimal(_ value: String) -> Bool {
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            !value.contains("\0")
        else {
            return false
        }
        return value.range(
            of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#,
            options: .regularExpression) != nil
    }

    static func validBoundString(_ value: String) -> Bool {
        value.utf8.count <= PostgreSQLDatabaseReadBounds.maximumCellBytes
            && !value.contains("\0")
    }

    static func validTemporalText(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256 && !value.contains("\0")
            && !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
    }

    private static func numeric(_ cell: PostgresCell) throws -> DatabaseValue {
        if cell.format == .text {
            let text = try cell.decode(String.self)
            guard text.utf8.count <= 1_024 else {
                throw PostgreSQLDatabaseDriverFailure.resultTooLarge
            }
            return .decimal(DatabaseDecimalValue(rawValue: text))
        }
        let data = try rawData(cell)
        guard data.count >= 8, data.count.isMultiple(of: 2) else {
            throw PostgreSQLDatabaseDriverFailure.decoding
        }
        let ndigits = Int(readUInt16(data, at: 0))
        let weight = Int(Int16(bitPattern: readUInt16(data, at: 2)))
        let sign = readUInt16(data, at: 4)
        let scale = Int(readUInt16(data, at: 6))
        guard ndigits <= 256,
            scale <= 1_000,
            data.count == 8 + ndigits * 2
        else {
            throw PostgreSQLDatabaseDriverFailure.resultTooLarge
        }
        if sign == 0xC000 {
            return .decimal(DatabaseDecimalValue(rawValue: "NaN"))
        }
        if sign == 0xD000 {
            return .decimal(DatabaseDecimalValue(rawValue: "Infinity"))
        }
        if sign == 0xF000 {
            return .decimal(DatabaseDecimalValue(rawValue: "-Infinity"))
        }
        guard sign == 0 || sign == 0x4000 else {
            throw PostgreSQLDatabaseDriverFailure.decoding
        }
        var digits: [Int] = []
        digits.reserveCapacity(ndigits)
        for index in 0..<ndigits {
            let digit = Int(readUInt16(data, at: 8 + index * 2))
            guard digit <= 9_999 else {
                throw PostgreSQLDatabaseDriverFailure.decoding
            }
            digits.append(digit)
        }
        func digit(group: Int) -> Int {
            let index = weight - group
            guard digits.indices.contains(index) else { return 0 }
            return digits[index]
        }
        var integer = "0"
        if weight >= 0 {
            integer = String(digit(group: weight))
            if weight > 0 {
                for group in stride(from: weight - 1, through: 0, by: -1) {
                    integer += String(format: "%04d", digit(group: group))
                }
            }
        }
        var fraction = ""
        if scale > 0 {
            let groups = (scale + 3) / 4
            for group in 1...groups {
                fraction += String(format: "%04d", digit(group: -group))
            }
            fraction = String(fraction.prefix(scale))
        }
        let negative = sign == 0x4000 && (digits.contains(where: { $0 != 0 }))
        var text = negative ? "-\(integer)" : integer
        if scale > 0 {
            text += ".\(fraction)"
        }
        return .decimal(DatabaseDecimalValue(rawValue: text))
    }

    private static func date(_ cell: PostgresCell) throws -> DatabaseValue {
        if let data = try? rawData(cell), cell.format == .binary, data.count == 4 {
            let raw = Int32(bitPattern: readUInt32(data, at: 0))
            if raw == Int32.max || raw == Int32.min {
                return .productSpecific(
                    DatabaseProductValue(
                        product: .postgresql,
                        typeName: "date",
                        textRepresentation: raw == Int32.max ? "infinity" : "-infinity"))
            }
        }
        let value = try cell.decode(Date.self)
        return .date(
            DatabaseDateValue(
                text: dateText(value),
                calendarIdentifier: "gregorian"))
    }

    private static func timestamp(
        _ cell: PostgresCell,
        includesTimeZone: Bool
    ) throws -> DatabaseValue {
        if let data = try? rawData(cell), cell.format == .binary, data.count == 8 {
            let raw = Int64(bitPattern: readUInt64(data, at: 0))
            if raw == Int64.max || raw == Int64.min {
                return .productSpecific(
                    DatabaseProductValue(
                        product: .postgresql,
                        typeName: includesTimeZone ? "timestamp with time zone" : "timestamp",
                        textRepresentation: raw == Int64.max ? "infinity" : "-infinity"))
            }
        }
        let value = try cell.decode(Date.self)
        return .timestamp(
            DatabaseTimestampValue(
                text: timestampText(value, includesTimeZone: includesTimeZone),
                timeZoneIdentifier: includesTimeZone ? "UTC" : nil,
                timeZoneOffsetMinutes: includesTimeZone ? 0 : nil,
                precision: 6))
    }

    private static func time(_ cell: PostgresCell) throws -> DatabaseValue {
        guard cell.format == .binary else {
            let text = try cell.decode(String.self)
            guard validTemporalText(text) else {
                throw PostgreSQLDatabaseDriverFailure.decoding
            }
            return .time(DatabaseTimeValue(text: text))
        }
        let data = try rawData(cell)
        let expectedBytes = cell.dataType == .timetz ? 12 : 8
        guard data.count == expectedBytes else {
            throw PostgreSQLDatabaseDriverFailure.decoding
        }
        let microseconds = Int64(bitPattern: readUInt64(data, at: 0))
        let maximum: Int64 = 86_400_000_000
        guard microseconds >= 0, microseconds <= maximum else {
            throw PostgreSQLDatabaseDriverFailure.decoding
        }
        let hours = microseconds / 3_600_000_000
        let minutes = (microseconds / 60_000_000) % 60
        let seconds = (microseconds / 1_000_000) % 60
        let fraction = microseconds % 1_000_000
        let text = String(
            format: "%02lld:%02lld:%02lld.%06lld",
            hours,
            minutes,
            seconds,
            fraction)
        let offset: Int?
        if cell.dataType == .timetz {
            let secondsWest = Int32(bitPattern: readUInt32(data, at: 8))
            guard secondsWest % 60 == 0,
                abs(Int64(secondsWest)) <= 15 * 60 * 60
            else {
                throw PostgreSQLDatabaseDriverFailure.decoding
            }
            offset = -Int(secondsWest / 60)
        } else {
            offset = nil
        }
        return .time(
            DatabaseTimeValue(
                text: text,
                timeZoneOffsetMinutes: offset,
                precision: 6))
    }

    private static func productSpecific(
        _ cell: PostgresCell,
        preferredTypeName: String?
    ) throws -> DatabaseValue {
        let data = try rawData(cell)
        let typeName = preferredTypeName ?? cell.dataType.description
        guard typeName.utf8.count <= PostgreSQLDatabaseReadBounds.maximumIdentifierBytes else {
            throw PostgreSQLDatabaseDriverFailure.resultTooLarge
        }
        if let text = String(data: data, encoding: .utf8), validBoundString(text) {
            return .productSpecific(
                DatabaseProductValue(
                    product: .postgresql,
                    typeName: typeName,
                    textRepresentation: text))
        }
        return .productSpecific(
            DatabaseProductValue(
                product: .postgresql,
                typeName: typeName,
                binaryRepresentation: data))
    }

    private static func array<Element>(
        _ values: [Element],
        transform: (Element) throws -> DatabaseValue
    ) throws -> DatabaseValue {
        guard values.count <= 4_096 else {
            throw PostgreSQLDatabaseDriverFailure.resultTooLarge
        }
        var output: [DatabaseValue] = []
        output.reserveCapacity(values.count)
        for value in values {
            output.append(try transform(value))
        }
        return .array(output)
    }

    private static func rawData(_ cell: PostgresCell) throws -> Data {
        guard let bytes = cell.bytes,
            bytes.readableBytes <= PostgreSQLDatabaseReadBounds.maximumCellBytes
        else {
            throw PostgreSQLDatabaseDriverFailure.resultTooLarge
        }
        return Data(bytes.readableBytesView)
    }

    private static func dateText(_ date: Date) -> String {
        String(timestampText(date, includesTimeZone: true).prefix(10))
    }

    private static func timestampText(
        _ date: Date,
        includesTimeZone: Bool
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        let value = formatter.string(from: date)
        if includesTimeZone {
            return value
        }
        return String(value.dropLast()).replacingOccurrences(of: "T", with: " ")
    }

    private static func readUInt16(_ data: Data, at index: Int) -> UInt16 {
        UInt16(data[index]) << 8 | UInt16(data[index + 1])
    }

    private static func readUInt32(_ data: Data, at index: Int) -> UInt32 {
        var value: UInt32 = 0
        for byte in data[index..<(index + 4)] {
            value = value << 8 | UInt32(byte)
        }
        return value
    }

    private static func readUInt64(_ data: Data, at index: Int) -> UInt64 {
        var value: UInt64 = 0
        for byte in data[index..<(index + 8)] {
            value = value << 8 | UInt64(byte)
        }
        return value
    }
}

extension PostgreSQLDatabaseReadSupport {
    private static let schemaFields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("name"),
            displayName: "name",
            typeName: "name",
            isNullable: false,
            isSortable: true,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("canUse"),
            displayName: "canUse",
            typeName: "boolean",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("canCreate"),
            displayName: "canCreate",
            typeName: "boolean",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
    ]

    private static let relationFields = [
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("name"),
            displayName: "name",
            typeName: "name",
            isNullable: false,
            isSortable: true,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("kind"),
            displayName: "kind",
            typeName: "text",
            isNullable: false,
            isSortable: true,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("estimatedRows"),
            displayName: "estimatedRows",
            typeName: "bigint",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
        DatabaseFieldDescriptor(
            path: DatabaseFieldPath("columnCount"),
            displayName: "columnCount",
            typeName: "bigint",
            isNullable: false,
            isSortable: false,
            isFilterable: false),
    ]

    private static func queryFields(
        _ row: PostgreSQLDatabaseReadRow?
    ) throws -> [DatabaseFieldDescriptor] {
        guard let row else { return [] }
        var names = Set<String>()
        var fields: [DatabaseFieldDescriptor] = []
        fields.reserveCapacity(row.cells.count)
        for cell in row.cells {
            do {
                try validateIdentifier(cell.columnName)
            } catch {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            guard cell.columnName != "__edith_postgresql_key",
                names.insert(cell.columnName).inserted
            else {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            fields.append(
                DatabaseFieldDescriptor(
                    path: DatabaseFieldPath(cell.columnName),
                    displayName: cell.columnName,
                    typeName: cell.dataType.description,
                    isNullable: true,
                    isSortable: true,
                    isFilterable: true))
        }
        return fields
    }

    private static func record(
        _ row: PostgreSQLDatabaseReadRow,
        fields: [DatabaseFieldDescriptor],
        preferredTypes: [String: String]
    ) throws -> DatabaseRecord {
        try record(
            row,
            fields: fields.map { $0.path.segments[0] },
            preferredTypes: preferredTypes)
    }

    private static func record(
        _ row: PostgreSQLDatabaseReadRow,
        fields: [String],
        preferredTypes: [String: String],
        identity: DatabaseRecordIdentity? = nil
    ) throws -> DatabaseRecord {
        var values: [String: DatabaseValue] = [:]
        values.reserveCapacity(row.cells.count)
        for cell in row.cells where cell.columnName != "__edith_postgresql_key" {
            guard values[cell.columnName] == nil else {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            values[cell.columnName] = try PostgreSQLDatabaseReadValueSupport.value(
                cell,
                preferredTypeName: preferredTypes[cell.columnName])
        }
        var output: [DatabaseObjectField] = []
        output.reserveCapacity(fields.count)
        for field in fields {
            guard let value = values[field] else {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            output.append(DatabaseObjectField(name: field, value: value))
        }
        return DatabaseRecord(identity: identity, fields: output)
    }

    private static func requiredValue(
        _ name: String,
        in row: PostgreSQLDatabaseReadRow,
        preferredType: String? = nil
    ) throws -> DatabaseValue {
        guard let cell = row.cells.first(where: { $0.columnName == name }) else {
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
        return try PostgreSQLDatabaseReadValueSupport.value(
            cell,
            preferredTypeName: preferredType)
    }

    private static func requiredString(
        _ name: String,
        in row: PostgreSQLDatabaseReadRow
    ) throws -> String {
        guard case let .string(value) = try requiredValue(name, in: row) else {
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
        return value
    }

    private static func requiredBool(
        _ name: String,
        in row: PostgreSQLDatabaseReadRow
    ) throws -> Bool {
        guard case let .boolean(value) = try requiredValue(name, in: row) else {
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
        return value
    }

    private static func requiredInt64(
        _ name: String,
        in row: PostgreSQLDatabaseReadRow
    ) throws -> Int64 {
        guard case let .signedInteger(value) = try requiredValue(name, in: row) else {
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
        return value
    }

    private static func objectKind(_ value: String) throws -> DatabaseObjectKind {
        switch value {
        case "table":
            return .table
        case "view":
            return .view
        case "materializedView":
            return .materializedView
        default:
            throw PostgreSQLDatabaseAdapterSupport.decodingFailed
        }
    }

    private static func keysetType(_ column: PostgreSQLDatabaseReadColumn) -> Bool {
        [20, 21, 23, 26, 1082, 1114, 1184, 2950].contains(column.typeOID)
    }

    private static func keysetValue(_ value: DatabaseValue) -> Bool {
        switch value {
        case .signedInteger, .unsignedInteger, .date, .timestamp, .uuid:
            return true
        default:
            return false
        }
    }

    private static func sortable(_ column: PostgreSQLDatabaseReadColumn) -> Bool {
        ![
            114, 142, 199, 1000, 1001, 1005, 1007, 1009, 1015, 1016, 1021, 1022, 1182,
            1185, 1231, 2951, 3802, 3807,
        ].contains(column.typeOID)
    }

    private static func filterable(_ column: PostgreSQLDatabaseReadColumn) -> Bool {
        sortable(column)
    }
}

extension PostgreSQLDatabaseReadSupport {
    private static func selectedColumns(
        _ available: [PostgreSQLDatabaseReadColumn],
        projection: DatabaseProjection?
    ) throws -> [PostgreSQLDatabaseReadSelectedColumn] {
        guard let projection else {
            return available.map {
                PostgreSQLDatabaseReadSelectedColumn(
                    source: $0,
                    outputName: $0.name)
            }
        }
        var selected: [PostgreSQLDatabaseReadSelectedColumn]
        switch projection.mode {
        case .include:
            guard !projection.fields.isEmpty else {
                throw PostgreSQLDatabaseAdapterSupport.invalidRead
            }
            selected = []
            selected.reserveCapacity(projection.fields.count)
            var sourceNames = Set<String>()
            var outputNames = Set<String>()
            for projected in projection.fields {
                let source = try resolve(
                    projected.path,
                    available: available,
                    failure: PostgreSQLDatabaseAdapterSupport.invalidRead)
                let outputName = projected.alias ?? source.name
                try validateIdentifier(outputName)
                guard outputName != "__edith_postgresql_key",
                    sourceNames.insert(source.name).inserted,
                    outputNames.insert(outputName).inserted
                else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidRead
                }
                selected.append(
                    PostgreSQLDatabaseReadSelectedColumn(
                        source: source,
                        outputName: outputName))
            }
        case .exclude:
            guard projection.fields.allSatisfy({ $0.alias == nil }) else {
                throw PostgreSQLDatabaseAdapterSupport.invalidRead
            }
            var excluded = Set<String>()
            for projected in projection.fields {
                let source = try resolve(
                    projected.path,
                    available: available,
                    failure: PostgreSQLDatabaseAdapterSupport.invalidRead)
                guard excluded.insert(source.name).inserted else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidRead
                }
            }
            selected = available.filter { !excluded.contains($0.name) }.map {
                PostgreSQLDatabaseReadSelectedColumn(
                    source: $0,
                    outputName: $0.name)
            }
        }
        guard !selected.isEmpty,
            selected.count <= DatabaseAdapterBounds.maximumPageFields
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
        return selected
    }

    private static func querySelection(
        _ projection: DatabaseProjection?
    ) throws -> String {
        guard let projection else { return "*" }
        guard projection.mode == .include,
            !projection.fields.isEmpty
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        var outputs = Set<String>()
        var selections: [String] = []
        selections.reserveCapacity(projection.fields.count)
        for projected in projection.fields {
            let field = try fieldName(
                projected.path,
                failure: PostgreSQLDatabaseAdapterSupport.invalidQuery)
            let output = projected.alias ?? field
            do {
                try validateIdentifier(output)
            } catch {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
            guard output != "__edith_postgresql_key",
                outputs.insert(output).inserted
            else {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
            selections.append(
                "\(qualified("_edith_query", field)) AS \(quote(output))")
        }
        return selections.joined(separator: ", ")
    }

    private static func filterSQL(
        _ filter: DatabaseFilter?,
        available: [PostgreSQLDatabaseReadColumn]?,
        sourceAlias: String,
        firstParameter: Int,
        failure: DatabaseAdapterFailure
    ) throws -> PostgreSQLDatabaseReadSQLFragment {
        guard let filter else {
            return PostgreSQLDatabaseReadSQLFragment(sql: "", parameters: [])
        }
        var nextParameter = firstParameter
        var predicateCount = 0
        return try filterSQL(
            filter,
            available: available,
            sourceAlias: sourceAlias,
            depth: 0,
            predicateCount: &predicateCount,
            nextParameter: &nextParameter,
            failure: failure)
    }

    private static func filterSQL(
        _ filter: DatabaseFilter,
        available: [PostgreSQLDatabaseReadColumn]?,
        sourceAlias: String,
        depth: Int,
        predicateCount: inout Int,
        nextParameter: inout Int,
        failure: DatabaseAdapterFailure
    ) throws -> PostgreSQLDatabaseReadSQLFragment {
        guard depth <= 16, predicateCount <= 100 else { throw failure }
        switch filter {
        case let .predicate(predicate):
            predicateCount += 1
            guard predicateCount <= 100 else { throw failure }
            let name: String
            if let available {
                name = try resolve(
                    predicate.field,
                    available: available,
                    failure: failure
                ).name
            } else {
                name = try fieldName(predicate.field, failure: failure)
            }
            let field = qualified(sourceAlias, name)
            let insensitive = predicate.caseSensitivity == .insensitive
            let sensitive = predicate.caseSensitivity != .insensitive
            switch predicate.operation {
            case .isNull:
                guard predicate.values.isEmpty, sensitive else { throw failure }
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) IS NULL",
                    parameters: [])
            case .isNotNull:
                guard predicate.values.isEmpty, sensitive else { throw failure }
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) IS NOT NULL",
                    parameters: [])
            case .equal, .notEqual, .greaterThan, .greaterThanOrEqual,
                .lessThan, .lessThanOrEqual:
                guard predicate.values.count == 1, sensitive else { throw failure }
                let operators: [DatabaseFilterOperator: String] = [
                    .equal: "=",
                    .notEqual: "<>",
                    .greaterThan: ">",
                    .greaterThanOrEqual: ">=",
                    .lessThan: "<",
                    .lessThanOrEqual: "<=",
                ]
                let marker = "$\(nextParameter)"
                nextParameter += 1
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) \(operators[predicate.operation]!) \(marker)",
                    parameters: predicate.values)
            case .between:
                guard predicate.values.count == 2, sensitive else { throw failure }
                let first = nextParameter
                nextParameter += 2
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) BETWEEN $\(first) AND $\(first + 1)",
                    parameters: predicate.values)
            case .in, .notIn:
                guard !predicate.values.isEmpty,
                    predicate.values.count <= 100,
                    sensitive
                else {
                    throw failure
                }
                let markers = predicate.values.indices.map { index in
                    "$\(nextParameter + index)"
                }
                nextParameter += predicate.values.count
                let operation = predicate.operation == .in ? "IN" : "NOT IN"
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) \(operation) (\(markers.joined(separator: ", ")))",
                    parameters: predicate.values)
            case .contains, .startsWith, .endsWith:
                guard predicate.values.count == 1,
                    case let .string(value) = predicate.values[0]
                else {
                    throw failure
                }
                let escaped =
                    value
                    .replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                let pattern: String
                switch predicate.operation {
                case .contains:
                    pattern = "%\(escaped)%"
                case .startsWith:
                    pattern = "\(escaped)%"
                case .endsWith:
                    pattern = "%\(escaped)"
                default:
                    throw failure
                }
                let operation = insensitive ? "ILIKE" : "LIKE"
                let marker = "$\(nextParameter)"
                nextParameter += 1
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: "\(field) \(operation) \(marker) ESCAPE '\\'",
                    parameters: [.string(pattern)])
            case .isMissing, .isNotMissing, .regularExpression, .fullText:
                throw failure
            }
        case let .all(children), let .any(children):
            guard children.count <= 100 else { throw failure }
            if children.isEmpty {
                return PostgreSQLDatabaseReadSQLFragment(
                    sql: filter.isAll ? "TRUE" : "FALSE",
                    parameters: [])
            }
            var sql: [String] = []
            var parameters: [DatabaseValue] = []
            for child in children {
                let fragment = try filterSQL(
                    child,
                    available: available,
                    sourceAlias: sourceAlias,
                    depth: depth + 1,
                    predicateCount: &predicateCount,
                    nextParameter: &nextParameter,
                    failure: failure)
                sql.append("(\(fragment.sql))")
                parameters.append(contentsOf: fragment.parameters)
            }
            return PostgreSQLDatabaseReadSQLFragment(
                sql: sql.joined(separator: filter.isAll ? " AND " : " OR "),
                parameters: parameters)
        case let .not(child):
            let fragment = try filterSQL(
                child,
                available: available,
                sourceAlias: sourceAlias,
                depth: depth + 1,
                predicateCount: &predicateCount,
                nextParameter: &nextParameter,
                failure: failure)
            return PostgreSQLDatabaseReadSQLFragment(
                sql: "NOT (\(fragment.sql))",
                parameters: fragment.parameters)
        }
    }

    private static func orderSQL(
        _ sorts: [DatabaseSort],
        available: [PostgreSQLDatabaseReadColumn]?,
        sourceAlias: String,
        failure: DatabaseAdapterFailure
    ) throws -> [String] {
        var names = Set<String>()
        var output: [String] = []
        output.reserveCapacity(sorts.count)
        for sort in sorts {
            let column: PostgreSQLDatabaseReadColumn?
            let name: String
            if let available {
                let resolved = try resolve(sort.field, available: available, failure: failure)
                guard sortable(resolved) else { throw failure }
                column = resolved
                name = resolved.name
            } else {
                column = nil
                name = try fieldName(sort.field, failure: failure)
            }
            _ = column
            guard names.insert(name).inserted else { throw failure }
            var sql = qualified(sourceAlias, name)
            sql += sort.direction == .ascending ? " ASC" : " DESC"
            switch sort.nullPlacement {
            case .productDefault:
                break
            case .first:
                sql += " NULLS FIRST"
            case .last:
                sql += " NULLS LAST"
            }
            output.append(sql)
        }
        return output
    }

    private static func resolve(
        _ path: DatabaseFieldPath,
        available: [PostgreSQLDatabaseReadColumn],
        failure: DatabaseAdapterFailure
    ) throws -> PostgreSQLDatabaseReadColumn {
        let name = try fieldName(path, failure: failure)
        guard let column = available.first(where: { $0.name == name }) else {
            throw failure
        }
        return column
    }

    private static func fieldName(
        _ path: DatabaseFieldPath,
        failure: DatabaseAdapterFailure
    ) throws -> String {
        guard path.segments.count == 1, let name = path.segments.first else {
            throw failure
        }
        do {
            try validateIdentifier(name)
        } catch {
            throw failure
        }
        return name
    }
}

private extension DatabaseFilter {
    var isAll: Bool {
        if case .all = self { return true }
        return false
    }
}

extension PostgreSQLDatabaseReadSupport {
    private static func validateReadOnlySQL(
        _ command: String,
        parameterCount: Int
    ) throws {
        let bytes = Array(command.utf8)
        guard !bytes.isEmpty,
            bytes.count <= PostgreSQLDatabaseReadBounds.maximumCommandBytes
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        var words: [String] = []
        var placeholders = Set<Int>()
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0 || byte == 59 {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
            if byte == 45, index + 1 < bytes.count, bytes[index + 1] == 45 {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
            if byte == 47, index + 1 < bytes.count, bytes[index + 1] == 42 {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
            if byte == 39 {
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 92 {
                        throw PostgreSQLDatabaseAdapterSupport.invalidQuery
                    }
                    if bytes[index] == 39 {
                        if index + 1 < bytes.count, bytes[index + 1] == 39 {
                            index += 2
                            continue
                        }
                        closed = true
                        index += 1
                        break
                    }
                    index += 1
                }
                guard closed else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidQuery
                }
                continue
            }
            if byte == 34 {
                index += 1
                var closed = false
                while index < bytes.count {
                    if bytes[index] == 34 {
                        if index + 1 < bytes.count, bytes[index + 1] == 34 {
                            index += 2
                            continue
                        }
                        closed = true
                        index += 1
                        break
                    }
                    index += 1
                }
                guard closed else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidQuery
                }
                continue
            }
            if byte == 36 {
                var end = index + 1
                while end < bytes.count, (48...57).contains(bytes[end]) {
                    end += 1
                }
                guard end > index + 1,
                    let placeholder = Int(
                        String(decoding: bytes[(index + 1)..<end], as: UTF8.self)),
                    placeholder > 0,
                    placeholder <= PostgreSQLDatabaseReadBounds.maximumParameters
                else {
                    throw PostgreSQLDatabaseAdapterSupport.invalidQuery
                }
                placeholders.insert(placeholder)
                index = end
                continue
            }
            if asciiWordStart(byte) {
                var end = index + 1
                while end < bytes.count, asciiWordContinuation(bytes[end]) {
                    end += 1
                }
                words.append(
                    String(decoding: bytes[index..<end], as: UTF8.self).lowercased())
                index = end
                continue
            }
            index += 1
        }
        guard let first = words.first,
            first == "select" || first == "with",
            first != "with" || words.contains("select")
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        let forbidden: Set<String> = [
            "alter", "analyze", "begin", "call", "checkpoint", "cluster", "commit",
            "copy", "create", "deallocate", "delete", "discard", "do", "drop",
            "execute", "grant", "insert", "listen", "lock", "merge", "notify",
            "prepare", "reassign", "refresh", "reindex", "reset", "revoke", "rollback",
            "set", "setval", "truncate", "unlisten", "update", "vacuum",
        ]
        guard words.allSatisfy({ !forbidden.contains($0) }),
            !words.contains("into"),
            !words.contains("returning")
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        for position in words.indices where words[position] == "for" {
            let remaining = words.index(after: position)..<words.endIndex
            if words[remaining].prefix(3).contains(where: {
                $0 == "update" || $0 == "share"
            }) {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
        }
        let expected = parameterCount == 0 ? Set<Int>() : Set(1...parameterCount)
        guard placeholders == expected else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
    }

    private static func asciiWordStart(_ byte: UInt8) -> Bool {
        byte == 95 || (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func asciiWordContinuation(_ byte: UInt8) -> Bool {
        asciiWordStart(byte) || (48...57).contains(byte)
    }
}

extension PostgreSQLDatabaseReadSupport {
    private static func page(
        records: [DatabaseRecord],
        fields: [DatabaseFieldDescriptor],
        hasMore: Bool,
        cursor: PostgreSQLDatabaseReadCursor,
        nextKey: DatabaseValue?,
        kind: PostgreSQLDatabaseReadContinuationKind,
        sessionID: DatabaseAdapterSessionID,
        digest: String,
        target: DatabaseTargetIdentifier,
        warnings: [DatabaseWarning],
        bytesReceived: UInt64,
        startedAt: Date
    ) throws -> DatabaseAdapterPage {
        let endingPosition = cursor.position + UInt64(records.count)
        guard endingPosition <= PostgreSQLDatabaseReadBounds.maximumContinuationPosition else {
            throw PostgreSQLDatabaseAdapterSupport.resultTooLarge
        }
        let nextContinuation: DatabaseAdapterContinuation?
        if hasMore {
            guard !records.isEmpty,
                cursor.mode != .keyset || nextKey != nil
            else {
                throw PostgreSQLDatabaseAdapterSupport.decodingFailed
            }
            let expiresAt = Date().addingTimeInterval(
                PostgreSQLDatabaseReadBounds.continuationLifetime)
            let payload = PostgreSQLDatabaseReadContinuationPayload(
                version: 1,
                sessionID: sessionID.rawValue,
                kind: kind,
                mode: cursor.mode,
                requestDigest: digest,
                position: endingPosition,
                key: nextKey,
                expiresAt: expiresAt)
            let encoded: Data
            do {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                encoded = try encoder.encode(payload)
            } catch {
                throw PostgreSQLDatabaseAdapterSupport.invalidContinuation
            }
            nextContinuation = try DatabaseAdapterContinuation(
                mode: cursor.mode,
                payload: encoded,
                expiresAt: expiresAt)
        } else {
            nextContinuation = nil
        }
        let elapsed = max(0, Date().timeIntervalSince(startedAt))
        let elapsedMilliseconds = UInt64(
            min(elapsed * 1_000, Double(UInt64.max)))
        let accuracy: DatabaseCountAccuracy =
            cursor.position == 0 && !hasMore ? .exact : .lowerBound
        return try DatabaseAdapterPage(
            records: records,
            fields: fields,
            nextContinuation: nextContinuation,
            metadata: DatabasePageMetadata(
                completeness: DatabaseResultCompleteness(
                    state: hasMore ? .partial : .complete,
                    reason: hasMore ? "More PostgreSQL rows are available." : nil),
                count: DatabaseCountMetadata(
                    value: endingPosition,
                    accuracy: accuracy),
                timing: DatabaseQueryTiming(
                    durationMilliseconds: elapsedMilliseconds),
                bytesReceived: bytesReceived,
                warnings: warnings))
    }

    private static func continuation(
        _ continuation: DatabaseAdapterContinuation?,
        expectedMode: DatabasePagingMode,
        kind: PostgreSQLDatabaseReadContinuationKind,
        sessionID: DatabaseAdapterSessionID,
        digest: String
    ) throws -> PostgreSQLDatabaseReadCursor {
        guard let continuation else {
            return PostgreSQLDatabaseReadCursor(
                mode: expectedMode,
                position: 0,
                key: nil)
        }
        guard continuation.mode == expectedMode,
            let envelopeExpiry = continuation.expiresAt,
            envelopeExpiry.timeIntervalSinceReferenceDate.isFinite,
            envelopeExpiry > Date()
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidContinuation
        }
        let payload: PostgreSQLDatabaseReadContinuationPayload
        do {
            payload = try JSONDecoder().decode(
                PostgreSQLDatabaseReadContinuationPayload.self,
                from: continuation.payload)
        } catch {
            throw PostgreSQLDatabaseAdapterSupport.invalidContinuation
        }
        guard payload.version == 1,
            payload.sessionID == sessionID.rawValue,
            payload.kind == kind,
            payload.mode == expectedMode,
            payload.requestDigest == digest,
            payload.position > 0,
            payload.position <= PostgreSQLDatabaseReadBounds.maximumContinuationPosition,
            payload.expiresAt == envelopeExpiry,
            payload.expiresAt > Date(),
            (expectedMode == .keyset) == (payload.key != nil)
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidContinuation
        }
        if let key = payload.key {
            guard keysetValue(key) else {
                throw PostgreSQLDatabaseAdapterSupport.invalidContinuation
            }
        }
        return PostgreSQLDatabaseReadCursor(
            mode: expectedMode,
            position: payload.position,
            key: payload.key)
    }

    private static func fingerprint(
        request: DatabaseAdapterPageRequest,
        command: String?,
        parameters: [DatabaseQueryParameter]?
    ) throws -> String {
        let input = PostgreSQLDatabaseReadFingerprint(
            target: request.target,
            pageSize: request.pageSize.value,
            projection: request.projection,
            filter: request.filter,
            sorts: request.sorts,
            consistency: request.consistency,
            command: command,
            parameters: parameters)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(input)
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } catch {
            throw command == nil
                ? PostgreSQLDatabaseAdapterSupport.invalidRead
                : PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
    }

    private static func validateCommon(
        _ request: DatabaseAdapterPageRequest,
        connectionID: DatabaseConnectionID
    ) throws {
        guard request.target.connectionID == connectionID,
            request.target.record == nil,
            request.pageSize.value <= PostgreSQLDatabaseReadBounds.maximumPageRecords,
            [.productDefault, .bestEffort, .eventual].contains(request.consistency)
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
    }

    private static func validateQueryTarget(
        _ target: DatabaseTargetIdentifier,
        connectionID: DatabaseConnectionID
    ) throws {
        guard target.connectionID == connectionID, target.record == nil else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        guard let object = target.object else { return }
        guard object.nativeIdentifier == nil,
            [.server, .catalog, .database, .schema, .table, .view, .materializedView]
                .contains(object.kind),
            object.path.count <= 2
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidQuery
        }
        for segment in object.path {
            do {
                try validateIdentifier(segment)
            } catch {
                throw PostgreSQLDatabaseAdapterSupport.invalidQuery
            }
        }
    }

    private static func requireDiscoveryShape(
        _ request: DatabaseAdapterPageRequest
    ) throws {
        guard request.projection == nil,
            request.filter == nil,
            request.sorts.isEmpty
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
    }

    private static func validateIdentifier(_ value: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= PostgreSQLDatabaseReadBounds.maximumIdentifierBytes,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidRead
        }
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func qualified(_ alias: String, _ column: String) -> String {
        "\(quote(alias)).\(quote(column))"
    }

    private static func offsetWarning(
        target: DatabaseTargetIdentifier
    ) -> DatabaseWarning {
        DatabaseWarning(
            code: "postgresql.paging.offset",
            message: "Offset paging can shift when rows change between page requests.",
            severity: .caution,
            target: target)
    }
}
