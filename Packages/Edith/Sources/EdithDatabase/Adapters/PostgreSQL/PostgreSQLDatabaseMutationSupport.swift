import Foundation

enum PostgreSQLDatabaseMutationSupport {
    static func normalize(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        let mutation = try validatedMutation(request, connectionID: connectionID)
        return DatabaseDestructivePlan(
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

    static func executionPlan(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> PostgreSQLDatabaseMutationPlan {
        let normalized = try normalize(plan.request, connectionID: connectionID)
        guard normalized == plan else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        let mutation = try validatedMutation(plan.request, connectionID: connectionID)
        return try PostgreSQLDatabaseMutationPlan(
            sql: mutation.statement,
            parameters: mutation.parameters)
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> PostgreSQLDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            let object = request.target.object,
            object.kind == .table,
            object.path.count == 2,
            object.nativeIdentifier == nil,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            case let .relational(product, statement, parameters) = request.payload,
            product == .postgresql,
            !parameters.isEmpty || request.target.record != nil
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        for segment in object.path {
            try validateIdentifier(segment)
        }
        let names = parameters.map(\.name)
        guard names.count <= PostgreSQLDatabaseReadBounds.maximumParameters,
            Set(names).count == names.count
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        for name in names {
            try validateIdentifier(name)
        }
        let table = object.path.map(quote).joined(separator: ".")
        let validated: PostgreSQLDatabaseValidatedMutation
        if let identity = request.target.record {
            let identityValues = try validatedIdentity(identity)
            let identityNames = identityValues.map(\.name)
            guard Set(names).isDisjoint(with: identityNames) else {
                throw PostgreSQLDatabaseAdapterSupport.invalidMutation
            }
            let firstIdentityParameter = parameters.count + 1
            let predicate = identityValues.enumerated().map { index, component in
                "\(quote(component.name)) IS NOT DISTINCT FROM $\(firstIdentityParameter + index)"
            }.joined(separator: " AND ")
            if parameters.isEmpty {
                validated = PostgreSQLDatabaseValidatedMutation(
                    action: .delete,
                    scope: .singleRecord,
                    statement: "DELETE FROM \(table) WHERE \(predicate) RETURNING 1",
                    parameters: identityValues.map(\.value),
                    impactDescription: "Delete one identified row")
            } else {
                let assignments = parameters.enumerated().map { index, parameter in
                    "\(quote(parameter.name)) = $\(index + 1)"
                }.joined(separator: ", ")
                validated = PostgreSQLDatabaseValidatedMutation(
                    action: .update,
                    scope: .singleRecord,
                    statement:
                        "UPDATE \(table) SET \(assignments) WHERE \(predicate) RETURNING 1",
                    parameters: parameters.map(\.value) + identityValues.map(\.value),
                    impactDescription: "Update one identified row")
            }
        } else {
            let columns = names.map(quote).joined(separator: ", ")
            let placeholders = parameters.indices.map { "$\($0 + 1)" }.joined(separator: ", ")
            validated = PostgreSQLDatabaseValidatedMutation(
                action: .insert,
                scope: .entireObject,
                statement: "INSERT INTO \(table) (\(columns)) VALUES (\(placeholders)) RETURNING 1",
                parameters: parameters.map(\.value),
                impactDescription: "Insert one row")
        }
        guard statement == validated.statement else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        return validated
    }

    private static func validatedIdentity(
        _ identity: DatabaseRecordIdentity
    ) throws(DatabaseAdapterFailure) -> [DatabaseIdentityComponent] {
        guard identity.kind == .primaryKey || identity.kind == .uniqueKey,
            (1...16).contains(identity.components.count),
            identity.concurrencyTokens.isEmpty
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        let names = identity.components.map(\.name)
        guard Set(names).count == names.count else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        for component in identity.components {
            try validateIdentifier(component.name)
            guard component.value != .missing, component.value != .null else {
                throw PostgreSQLDatabaseAdapterSupport.invalidMutation
            }
        }
        return identity.components
    }

    private static func validateIdentifier(
        _ value: String
    ) throws(DatabaseAdapterFailure) {
        guard !value.isEmpty, value.utf8.count <= 63, !value.contains("\0") else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
    }

    private static func quote(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

private struct PostgreSQLDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let statement: String
    let parameters: [DatabaseValue]
    let impactDescription: String
}
