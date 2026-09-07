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
            case let .relational(product, _, parameters) = request.payload,
            product == .postgresql
        else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        let fields = parameters.map {
            DatabaseObjectField(name: $0.name, value: $0.value)
        }
        let canonical: DatabaseDestructiveRequest
        let validated: PostgreSQLDatabaseValidatedMutation
        do {
            if let identity = request.target.record, parameters.isEmpty {
                canonical = try DatabaseRowMutationRequests.postgreSQLDelete(
                    target: request.target)
                validated = PostgreSQLDatabaseValidatedMutation(
                    action: .delete,
                    scope: .singleRecord,
                    statement: canonical.payload.command,
                    parameters: identity.components.map(\.value),
                    impactDescription: "Delete one identified row")
            } else if let identity = request.target.record {
                canonical = try DatabaseRowMutationRequests.postgreSQLUpdate(
                    target: request.target,
                    values: fields)
                validated = PostgreSQLDatabaseValidatedMutation(
                    action: .update,
                    scope: .singleRecord,
                    statement: canonical.payload.command,
                    parameters: parameters.map(\.value) + identity.components.map(\.value),
                    impactDescription: "Update one identified row")
            } else {
                canonical = try DatabaseRowMutationRequests.postgreSQLInsert(
                    target: request.target,
                    values: fields)
                validated = PostgreSQLDatabaseValidatedMutation(
                    action: .insert,
                    scope: .entireObject,
                    statement: canonical.payload.command,
                    parameters: parameters.map(\.value),
                    impactDescription: "Insert one row")
            }
        } catch {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        guard canonical == request else {
            throw PostgreSQLDatabaseAdapterSupport.invalidMutation
        }
        return validated
    }
}

private struct PostgreSQLDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let statement: String
    let parameters: [DatabaseValue]
    let impactDescription: String
}
