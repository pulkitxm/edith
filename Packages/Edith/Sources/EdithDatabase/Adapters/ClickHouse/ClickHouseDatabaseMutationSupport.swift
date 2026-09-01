import Foundation

public extension DatabaseRowMutationRequests {
    static func clickHouseInsert(
        target: DatabaseTargetIdentifier,
        values: [DatabaseObjectField]
    ) throws -> DatabaseDestructiveRequest {
        guard let object = target.object,
            object.kind == .table,
            object.path.count == 2,
            object.nativeIdentifier == nil,
            target.record == nil
        else {
            throw DatabaseRowMutationRequestError.invalidTarget
        }
        try object.path.forEach(clickHouseValidateIdentifier)
        guard !values.isEmpty, values.count <= 256 else {
            throw DatabaseRowMutationRequestError.missingValues
        }
        let names = values.map(\.name)
        guard Set(names).count == names.count else {
            throw DatabaseRowMutationRequestError.duplicateField
        }
        try names.forEach(clickHouseValidateIdentifier)
        let table = object.path.map(clickHouseQuote).joined(separator: ".")
        let columns = names.map(clickHouseQuote).joined(separator: ", ")
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        return DatabaseDestructiveRequest(
            target: target,
            payload: .relational(
                product: .clickHouse,
                statement: "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders))",
                parameters: values.map {
                    DatabaseMutationParameter(name: $0.name, value: $0.value)
                }))
    }
}

struct ClickHouseDatabaseInsertTarget: Equatable, Sendable {
    let database: String
    let table: String
}

struct ClickHouseDatabaseInsertPlan: Equatable, Sendable {
    let query: String
    let parameters: [ClickHouseDatabaseHTTPParameter]
}

enum ClickHouseDatabaseMutationSupport {
    static func target(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseInsertTarget {
        try validatedRequest(request, connectionID: connectionID).target
    }

    static func normalize(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        description: ClickHouseDatabaseTableDescription
    ) throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        let insertion = try validatedRequest(request, connectionID: connectionID)
        _ = try compile(insertion, description: description)
        return DatabaseDestructivePlan(
            request: request,
            action: .insert,
            scope: .entireObject,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: "Insert one row into a writable MergeTree table"),
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous,
            warnings: [
                DatabaseWarning(
                    code: "clickhouse.mutation.no_rollback",
                    message: "ClickHouse inserts cannot be rolled back after execution.",
                    severity: .caution,
                    target: request.target),
                DatabaseWarning(
                    code: "clickhouse.mutation.background_merges",
                    message: "MergeTree background merges can transform or collapse inserted rows.",
                    severity: .information,
                    target: request.target),
            ])
    }

    static func executionPlan(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID,
        description: ClickHouseDatabaseTableDescription
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseInsertPlan {
        let normalized = try normalize(
            plan.request,
            connectionID: connectionID,
            description: description)
        guard normalized == plan else {
            throw ClickHouseDatabaseAdapterSupport.invalidMutation
        }
        let insertion = try validatedRequest(plan.request, connectionID: connectionID)
        return try compile(insertion, description: description)
    }

    private static func validatedRequest(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseValidatedInsert {
        guard request.target.connectionID == connectionID,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            case let .relational(product, _, parameters) = request.payload,
            product == .clickHouse
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidMutation
        }
        let fields = parameters.map {
            DatabaseObjectField(name: $0.name, value: $0.value)
        }
        let canonical: DatabaseDestructiveRequest
        do {
            canonical = try DatabaseRowMutationRequests.clickHouseInsert(
                target: request.target,
                values: fields)
        } catch {
            throw ClickHouseDatabaseAdapterSupport.invalidMutation
        }
        guard canonical == request,
            let object = request.target.object
        else {
            throw ClickHouseDatabaseAdapterSupport.invalidMutation
        }
        return ClickHouseDatabaseValidatedInsert(
            target: ClickHouseDatabaseInsertTarget(
                database: object.path[0],
                table: object.path[1]),
            fields: fields)
    }

    private static func compile(
        _ insertion: ClickHouseDatabaseValidatedInsert,
        description: ClickHouseDatabaseTableDescription
    ) throws(DatabaseAdapterFailure) -> ClickHouseDatabaseInsertPlan {
        guard description.database == insertion.target.database,
            description.table == insertion.target.table,
            description.database.lowercased() != "system",
            description.engine.hasSuffix("MergeTree")
        else {
            throw ClickHouseDatabaseAdapterSupport.mutationTargetReadOnly
        }
        var parameters: [ClickHouseDatabaseHTTPParameter] = []
        var expressions: [String] = []
        var totalParameterBytes = 0
        for (index, field) in insertion.fields.enumerated() {
            guard let column = description.columns.first(where: { $0.name == field.name }),
                column.defaultKind == nil || column.defaultKind == "DEFAULT"
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidMutation
            }
            if field.value == .null {
                guard acceptsNull(column.type) else {
                    throw ClickHouseDatabaseAdapterSupport.invalidMutation
                }
                expressions.append("CAST(NULL, \(clickHouseStringLiteral(column.type)))")
                continue
            }
            guard let text = parameterText(field.value) else {
                throw ClickHouseDatabaseAdapterSupport.invalidMutation
            }
            let name = "_edith_insert_\(index)"
            totalParameterBytes += name.utf8.count + text.utf8.count
            guard totalParameterBytes <= ClickHouseDatabaseHTTPTransport.maximumParameterBytes
            else {
                throw ClickHouseDatabaseAdapterSupport.invalidMutation
            }
            parameters.append(ClickHouseDatabaseHTTPParameter(name: name, value: text))
            expressions.append(
                "CAST({\(name):String}, \(clickHouseStringLiteral(column.type)))")
        }
        let table = [description.database, description.table]
            .map(clickHouseQuote)
            .joined(separator: ".")
        let columns = insertion.fields.map { clickHouseQuote($0.name) }.joined(separator: ", ")
        let values = expressions.joined(separator: ", ")
        let query = "INSERT INTO \(table) (\(columns)) VALUES (\(values))"
        guard query.utf8.count <= ClickHouseDatabaseHTTPTransport.maximumQueryBytes else {
            throw ClickHouseDatabaseAdapterSupport.invalidMutation
        }
        return ClickHouseDatabaseInsertPlan(query: query, parameters: parameters)
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

    private static func acceptsNull(_ type: String) -> Bool {
        if wrappedType(type, wrapper: "Nullable") != nil {
            return true
        }
        guard let nested = wrappedType(type, wrapper: "LowCardinality") else {
            return false
        }
        return acceptsNull(nested)
    }

    private static func wrappedType(_ type: String, wrapper: String) -> String? {
        let prefix = "\(wrapper)("
        guard type.hasPrefix(prefix), type.hasSuffix(")") else { return nil }
        let start = type.index(type.startIndex, offsetBy: prefix.count)
        let end = type.index(before: type.endIndex)
        guard start < end else { return nil }
        return String(type[start..<end])
    }
}

private struct ClickHouseDatabaseValidatedInsert: Sendable {
    let target: ClickHouseDatabaseInsertTarget
    let fields: [DatabaseObjectField]
}

private func clickHouseValidateIdentifier(_ value: String) throws {
    guard !value.isEmpty,
        value.utf8.count <= ClickHouseDatabaseReadCompiler.maximumIdentifierBytes,
        !value.contains("\0"),
        !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw DatabaseRowMutationRequestError.invalidIdentifier
    }
}

private func clickHouseQuote(_ value: String) -> String {
    "`\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "`", with: "\\`"))`"
}

private func clickHouseStringLiteral(_ value: String) -> String {
    "'\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'"))'"
}
