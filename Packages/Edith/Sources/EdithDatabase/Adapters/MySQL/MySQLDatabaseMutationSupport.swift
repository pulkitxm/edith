import Foundation

enum MySQLDatabaseMutationSupport {
    static func normalize(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> DatabaseDestructivePlan {
        let mutation = try validatedMutation(
            request,
            connectionID: connectionID,
            product: product)
        return DatabaseDestructivePlan(
            request: request,
            action: mutation.action,
            scope: mutation.scope,
            impact: DatabaseMutationImpact(
                count: DatabaseCountMetadata(value: 1, accuracy: .exact),
                description: mutation.impactDescription),
            transactionBehavior: .productDependent,
            rollbackAvailability: .conditional,
            executionMode: .synchronous,
            warnings: [
                DatabaseWarning(
                    code: "mysql.mutation.storage_engine",
                    message: "Rollback support depends on the table storage engine.",
                    severity: .information,
                    target: request.target)
            ])
    }

    static func executionPlan(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> MySQLDatabaseMutationPlan {
        let normalized = try normalize(
            plan.request,
            connectionID: connectionID,
            product: product)
        guard normalized == plan else {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        let mutation = try validatedMutation(
            plan.request,
            connectionID: connectionID,
            product: product)
        return try MySQLDatabaseMutationPlan(
            sql: mutation.statement,
            parameters: mutation.parameters)
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID,
        product: DatabaseProduct
    ) throws(DatabaseAdapterFailure) -> MySQLDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            product == .mysql || product == .mariaDB,
            case let .relational(payloadProduct, _, parameters) = request.payload,
            payloadProduct == product
        else {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        let fields = parameters.map {
            DatabaseObjectField(name: $0.name, value: $0.value)
        }
        let canonical: DatabaseDestructiveRequest
        let validated: MySQLDatabaseValidatedMutation
        do {
            if let identity = request.target.record, parameters.isEmpty {
                canonical = try DatabaseRowMutationRequests.mySQLDelete(
                    target: request.target,
                    product: product)
                validated = MySQLDatabaseValidatedMutation(
                    action: .delete,
                    scope: .singleRecord,
                    statement: canonical.payload.command,
                    parameters: identity.components.map(\.value),
                    impactDescription: "Delete one identified row")
            } else if let identity = request.target.record {
                canonical = try DatabaseRowMutationRequests.mySQLUpdate(
                    target: request.target,
                    product: product,
                    values: fields)
                validated = MySQLDatabaseValidatedMutation(
                    action: .update,
                    scope: .singleRecord,
                    statement: canonical.payload.command,
                    parameters: parameters.map(\.value) + identity.components.map(\.value),
                    impactDescription: "Update one identified row")
            } else {
                canonical = try DatabaseRowMutationRequests.mySQLInsert(
                    target: request.target,
                    product: product,
                    values: fields)
                validated = MySQLDatabaseValidatedMutation(
                    action: .insert,
                    scope: .entireObject,
                    statement: canonical.payload.command,
                    parameters: parameters.map(\.value),
                    impactDescription: "Insert one row")
            }
        } catch {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        guard canonical == request else {
            throw MySQLDatabaseAdapterSupport.invalidMutation
        }
        return validated
    }
}

private struct MySQLDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let statement: String
    let parameters: [DatabaseValue]
    let impactDescription: String
}
