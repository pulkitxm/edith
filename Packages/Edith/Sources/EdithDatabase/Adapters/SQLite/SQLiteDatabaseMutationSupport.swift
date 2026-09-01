import Foundation
import GRDB

public extension DatabaseRowMutationRequests {
    static func sqliteInsert(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: false)
        try validateSQLiteMutationFields(values, excluding: [])
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let columns = values.map { sqliteMutationQuote($0.name) }.joined(separator: ", ")
        let placeholders = values.map { _ in "?" }.joined(separator: ", ")
        let statement = "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    static func sqliteUpdate(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: true)
        let identity = try sqliteMutationIdentity(target)
        try validateSQLiteMutationFields(
            values,
            excluding: Set(identity.map { sqliteMutationFold($0.name) }))
        guard !values.isEmpty else { throw DatabaseRowMutationRequestError.missingValues }
        let assignments = values.map {
            "\(sqliteMutationQuote($0.name)) = ?"
        }.joined(separator: ", ")
        let predicate = identity.map {
            "\(sqliteMutationQuote($0.name)) IS ?"
        }.joined(separator: " AND ")
        let statement = "UPDATE \(table) SET \(assignments) WHERE \(predicate)"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }

    static func sqliteDelete(
        target: DatabaseTargetIdentifier
    ) throws -> DatabaseDestructiveRequest {
        let table = try sqliteMutationTable(target, requiresIdentity: true)
        let identity = try sqliteMutationIdentity(target)
        let predicate = identity.map {
            "\(sqliteMutationQuote($0.name)) IS ?"
        }.joined(separator: " AND ")
        let statement = "DELETE FROM \(table) WHERE \(predicate)"
        try validateSQLiteMutationStatement(statement)
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .sqlite,
                statement: statement,
                parameters: []))
    }

    private static func sqliteMutationTable(
        _ target: DatabaseTargetIdentifier,
        requiresIdentity: Bool
    ) throws -> String {
        guard let object = target.object,
            object.kind == .table,
            object.nativeIdentifier == nil,
            object.path.count == 1 || object.path.count == 2,
            (requiresIdentity ? target.record != nil : target.record == nil)
        else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        let schema = object.path.count == 1 ? "main" : object.path[0].lowercased()
        let table = object.path.last ?? ""
        guard schema == "main" || schema == "temp" else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        try validateSQLiteMutationIdentifier(table)
        return "\(sqliteMutationQuote(schema)).\(sqliteMutationQuote(table))"
    }

    private static func sqliteMutationIdentity(
        _ target: DatabaseTargetIdentifier
    ) throws -> [DatabaseIdentityComponent] {
        guard let identity = target.record,
            identity.kind == .primaryKey || identity.kind == .rowID,
            (1...16).contains(identity.components.count),
            identity.concurrencyTokens.isEmpty
        else {
            throw DatabaseRowMutationRequestError.unsupportedIdentity
        }
        if identity.kind == .rowID {
            guard identity.components.count == 1,
                ["rowid", "_rowid_", "oid"].contains(
                    sqliteMutationFold(identity.components[0].name)),
                case .signedInteger = identity.components[0].value
            else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
        var names = Set<String>()
        for component in identity.components {
            try validateSQLiteMutationIdentifier(component.name)
            guard names.insert(sqliteMutationFold(component.name)).inserted,
                component.value != .missing,
                component.value != .null
            else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
        return identity.components
    }

    private static func validateSQLiteMutationFields(
        _ fields: [DatabaseObjectField],
        excluding excludedNames: Set<String>
    ) throws {
        guard fields.count <= 256 else {
            throw DatabaseRowMutationRequestError.missingValues
        }
        var names = Set<String>()
        for field in fields {
            try validateSQLiteMutationIdentifier(field.name)
            let folded = sqliteMutationFold(field.name)
            guard names.insert(folded).inserted else {
                throw DatabaseRowMutationRequestError.duplicateField
            }
            guard !excludedNames.contains(folded) else {
                throw DatabaseRowMutationRequestError.unsupportedIdentity
            }
        }
    }

    private static func validateSQLiteMutationIdentifier(_ value: String) throws {
        guard !value.isEmpty,
            value.utf8.count <= 1_024,
            !value.contains("\0"),
            !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            throw DatabaseRowMutationRequestError.invalidIdentifier
        }
    }

    private static func validateSQLiteMutationStatement(_ statement: String) throws {
        guard statement.utf8.count <= 65_536 else {
            throw DatabaseRowMutationRequestError.invalidIdentifier
        }
    }

    private static func sqliteMutationQuote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func sqliteMutationFold(_ identifier: String) -> String {
        let scalars = identifier.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(scalar.value + 32) ?? scalar
                : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

struct SQLiteDatabaseMutationPlan: Sendable {
    let action: DatabaseDestructiveAction
    let target: DatabaseTargetIdentifier
    let sql: String
    let fieldNames: [String]
    let parameters: [DatabaseValue]

    init(
        action: DatabaseDestructiveAction,
        target: DatabaseTargetIdentifier,
        sql: String,
        fieldNames: [String],
        parameters: [DatabaseValue]
    ) throws(DatabaseAdapterFailure) {
        guard !sql.isEmpty,
            sql.utf8.count <= 65_536,
            fieldNames.count <= 256,
            parameters.count <= 272
        else {
            throw SQLiteDatabaseMutationSupport.invalidMutation
        }
        self.action = action
        self.target = target
        self.sql = sql
        self.fieldNames = fieldNames
        self.parameters = parameters
    }
}

struct SQLiteDatabaseMutationResult: Sendable {
    let affectedRows: Int
}

enum SQLiteDatabaseMutationSupport {
    static let invalidMutation = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .invalidRequest,
            message: "The SQLite row mutation request is invalid.",
            productCode: "sqlite.mutation.invalid"))

    static let mutationFailed = DatabaseAdapterFailure.reported(
        DatabaseErrorEnvelope(
            category: .server,
            message: "SQLite could not execute the requested row mutation.",
            productCode: "sqlite.mutation.failed"))

    static func normalize(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        database: Database
    ) throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        let mutation = try validatedMutation(request, connectionID: connectionID)
        do {
            try validateSchema(mutation, database: database)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidMutation
        }
        return destructivePlan(request: request, mutation: mutation)
    }

    static func executionPlan(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> SQLiteDatabaseMutationPlan {
        let mutation = try validatedMutation(plan.request, connectionID: connectionID)
        guard destructivePlan(request: plan.request, mutation: mutation) == plan else {
            throw invalidMutation
        }
        return try SQLiteDatabaseMutationPlan(
            action: mutation.action,
            target: plan.request.target,
            sql: mutation.statement,
            fieldNames: mutation.fieldNames,
            parameters: mutation.parameters)
    }

    static func execute(
        _ plan: SQLiteDatabaseMutationPlan,
        database: Database
    ) throws -> SQLiteDatabaseMutationResult {
        try validateSchema(plan, database: database)
        let arguments = try StatementArguments(
            plan.parameters.map {
                try databaseValue($0).storage.value
            })
        var affectedRows = 0
        try database.inTransaction(.immediate) {
            let statement = try database.makeStatement(sql: plan.sql)
            guard !statement.isReadonly, statement.columnNames.isEmpty else {
                throw invalidMutation
            }
            try statement.execute(arguments: arguments)
            affectedRows = database.changesCount
            return affectedRows == 1 ? .commit : .rollback
        }
        return SQLiteDatabaseMutationResult(affectedRows: affectedRows)
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> SQLiteDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            case let .relational(product, _, parameters) = request.payload,
            product == .sqlite
        else {
            throw invalidMutation
        }
        let fields = parameters.map {
            DatabaseObjectField(name: $0.name, value: $0.value)
        }
        let canonical: DatabaseDestructiveRequest
        let action: DatabaseDestructiveAction
        let scope: DatabaseMutationScope
        let impactDescription: String
        do {
            if let identity = request.target.record, parameters.isEmpty {
                canonical = try DatabaseRowMutationRequests.sqliteDelete(target: request.target)
                action = .delete
                scope = .singleRecord
                impactDescription = "Delete one identified SQLite row"
                return try validated(
                    request: request,
                    canonical: canonical,
                    action: action,
                    scope: scope,
                    fields: [],
                    parameters: identity.components.map(\.value),
                    impactDescription: impactDescription)
            }
            if let identity = request.target.record {
                canonical = try DatabaseRowMutationRequests.sqliteUpdate(
                    target: request.target,
                    values: fields)
                action = .update
                scope = .singleRecord
                impactDescription = "Update one identified SQLite row"
                return try validated(
                    request: request,
                    canonical: canonical,
                    action: action,
                    scope: scope,
                    fields: fields,
                    parameters: parameters.map(\.value) + identity.components.map(\.value),
                    impactDescription: impactDescription)
            }
            canonical = try DatabaseRowMutationRequests.sqliteInsert(
                target: request.target,
                values: fields)
            action = .insert
            scope = .entireObject
            impactDescription = "Insert one SQLite row"
            return try validated(
                request: request,
                canonical: canonical,
                action: action,
                scope: scope,
                fields: fields,
                parameters: parameters.map(\.value),
                impactDescription: impactDescription)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidMutation
        }
    }

    private static func validated(
        request: DatabaseDestructiveRequest,
        canonical: DatabaseDestructiveRequest,
        action: DatabaseDestructiveAction,
        scope: DatabaseMutationScope,
        fields: [DatabaseObjectField],
        parameters: [DatabaseValue],
        impactDescription: String
    ) throws(DatabaseAdapterFailure) -> SQLiteDatabaseValidatedMutation {
        guard canonical == request else { throw invalidMutation }
        _ = try parameters.map(databaseValue)
        return SQLiteDatabaseValidatedMutation(
            action: action,
            scope: scope,
            statement: canonical.payload.command,
            fieldNames: fields.map(\.name),
            parameters: parameters,
            impactDescription: impactDescription,
            target: request.target)
    }

    private static func destructivePlan(
        request: DatabaseDestructiveRequest,
        mutation: SQLiteDatabaseValidatedMutation
    ) -> DatabaseDestructivePlan {
        DatabaseDestructivePlan(
            request: request,
            action: mutation.action,
            scope: mutation.scope,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: mutation.impactDescription),
            transactionBehavior: .transactional,
            rollbackAvailability: .available,
            executionMode: .synchronous)
    }

    private static func validateSchema(
        _ mutation: SQLiteDatabaseValidatedMutation,
        database: Database
    ) throws {
        try validateSchema(
            action: mutation.action,
            target: mutation.target,
            fieldNames: mutation.fieldNames,
            database: database)
    }

    private static func validateSchema(
        _ plan: SQLiteDatabaseMutationPlan,
        database: Database
    ) throws {
        try validateSchema(
            action: plan.action,
            target: plan.target,
            fieldNames: plan.fieldNames,
            database: database)
    }

    private static func validateSchema(
        action: DatabaseDestructiveAction,
        target: DatabaseTargetIdentifier,
        fieldNames: [String],
        database: Database
    ) throws {
        let table = try tableMetadata(target, database: database)
        let available = Dictionary(
            uniqueKeysWithValues: table.columns.map { (fold($0.name), $0) })
        for fieldName in fieldNames {
            guard let column = available[fold(fieldName)], column.hidden == 0 else {
                throw invalidMutation
            }
        }
        guard action == .update || action == .delete else { return }
        guard let identity = target.record else { throw invalidMutation }
        let expected = try trustedIdentity(table, database: database)
        guard identity.kind == expected.kind,
            identity.components.count == expected.names.count,
            zip(identity.components, expected.names).allSatisfy({ component, name in
                fold(component.name) == fold(name)
            })
        else {
            throw invalidMutation
        }
    }

    private static func tableMetadata(
        _ target: DatabaseTargetIdentifier,
        database: Database
    ) throws -> SQLiteDatabaseMutationTable {
        guard let object = target.object,
            object.kind == .table,
            object.nativeIdentifier == nil,
            object.path.count == 1 || object.path.count == 2
        else {
            throw invalidMutation
        }
        let schema = object.path.count == 1 ? "main" : object.path[0].lowercased()
        let table = object.path.last ?? ""
        guard schema == "main" || schema == "temp",
            try Int.fetchOne(
                database,
                sql:
                    "SELECT 1 FROM \(quote(schema)).sqlite_schema WHERE type = ? AND name = ? LIMIT 1",
                arguments: ["table", table]) == 1
        else {
            throw invalidMutation
        }
        let cursor = try Row.fetchCursor(
            database,
            sql: """
                SELECT name, type, "notnull", pk, hidden
                FROM pragma_table_xinfo(?, ?)
                LIMIT 513
                """,
            arguments: [table, schema])
        var columns: [SQLiteDatabaseMutationColumn] = []
        var names = Set<String>()
        while let row = try cursor.next() {
            let name: String = row["name"]
            let typeName: String = row["type"]
            let isNotNull: Int = row["notnull"]
            let primaryKeyIndex: Int = row["pk"]
            let hidden: Int = row["hidden"]
            guard !name.isEmpty,
                name.utf8.count <= 1_024,
                names.insert(fold(name)).inserted,
                (0...3).contains(hidden)
            else {
                throw invalidMutation
            }
            columns.append(
                SQLiteDatabaseMutationColumn(
                    name: name,
                    typeName: typeName,
                    isNullable: isNotNull == 0,
                    primaryKeyIndex: primaryKeyIndex,
                    hidden: hidden))
        }
        guard !columns.isEmpty, columns.count <= 512 else {
            throw invalidMutation
        }
        return SQLiteDatabaseMutationTable(
            schema: schema,
            name: table,
            columns: columns)
    }

    private static func trustedIdentity(
        _ table: SQLiteDatabaseMutationTable,
        database: Database
    ) throws -> (kind: DatabaseRecordIdentityKind, names: [String]) {
        let primaryKey = table.columns
            .filter { $0.primaryKeyIndex > 0 && $0.hidden != 1 }
            .sorted { $0.primaryKeyIndex < $1.primaryKeyIndex }
        if primaryKey.count == 1, fold(primaryKey[0].typeName) == "integer" {
            let regularPrimaryKeyIndex = try Int.fetchOne(
                database,
                sql: """
                    SELECT 1
                    FROM pragma_index_list(?, ?)
                    WHERE origin = 'pk'
                    LIMIT 1
                    """,
                arguments: [table.name, table.schema])
            if regularPrimaryKeyIndex == nil {
                return (.primaryKey, [primaryKey[0].name])
            }
        }
        if !primaryKey.isEmpty, primaryKey.allSatisfy({ !$0.isNullable }) {
            return (.primaryKey, primaryKey.map(\.name))
        }
        let existing = Set(table.columns.map { fold($0.name) })
        guard
            let alias = ["rowid", "_rowid_", "oid"].first(where: {
                !existing.contains(fold($0))
            })
        else {
            throw invalidMutation
        }
        let probe =
            "SELECT \(quote(alias)) FROM \(quote(table.schema)).\(quote(table.name)) LIMIT 0"
        _ = try database.makeStatement(sql: probe)
        return (.rowID, [alias])
    }

    private static func databaseValue(
        _ value: DatabaseValue
    ) throws(DatabaseAdapterFailure) -> GRDB.DatabaseValue {
        switch value {
        case .missing, .array, .object, .productSpecific:
            throw invalidMutation
        case .null:
            return .null
        case let .boolean(value):
            return Int64(value ? 1 : 0).databaseValue
        case let .signedInteger(value):
            return value.databaseValue
        case let .unsignedInteger(value):
            guard value <= UInt64(Int64.max) else { throw invalidMutation }
            return Int64(value).databaseValue
        case let .decimal(value):
            guard validDecimal(value.rawValue), value.rawValue.utf8.count <= 128 else {
                throw invalidMutation
            }
            return value.rawValue.databaseValue
        case let .floatingPoint(value):
            guard value.isFinite else { throw invalidMutation }
            return value.databaseValue
        case let .string(value):
            guard value.utf8.count <= 4_194_304 else { throw invalidMutation }
            return value.databaseValue
        case let .binary(value):
            guard case let .complete(data, _, _) = value, data.count <= 4_194_304 else {
                throw invalidMutation
            }
            return data.databaseValue
        case let .date(value):
            guard validTextValue(value.text) else { throw invalidMutation }
            return value.text.databaseValue
        case let .time(value):
            guard validTextValue(value.text) else { throw invalidMutation }
            return value.text.databaseValue
        case let .timestamp(value):
            guard validTextValue(value.text) else { throw invalidMutation }
            return value.text.databaseValue
        case let .uuid(value):
            return value.uuidString.lowercased().databaseValue
        }
    }

    private static func validDecimal(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        return value.range(
            of: #"^-?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?$"#,
            options: .regularExpression) != nil
    }

    private static func validTextValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 1_024 && !value.contains("\0")
    }

    private static func quote(_ identifier: String) -> String {
        "\"\(identifier.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func fold(_ identifier: String) -> String {
        let scalars = identifier.unicodeScalars.map { scalar in
            (65...90).contains(scalar.value)
                ? UnicodeScalar(scalar.value + 32) ?? scalar
                : scalar
        }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct SQLiteDatabaseValidatedMutation: Sendable {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let statement: String
    let fieldNames: [String]
    let parameters: [DatabaseValue]
    let impactDescription: String
    let target: DatabaseTargetIdentifier
}

private struct SQLiteDatabaseMutationTable {
    let schema: String
    let name: String
    let columns: [SQLiteDatabaseMutationColumn]
}

private struct SQLiteDatabaseMutationColumn {
    let name: String
    let typeName: String
    let isNullable: Bool
    let primaryKeyIndex: Int
    let hidden: Int
}
