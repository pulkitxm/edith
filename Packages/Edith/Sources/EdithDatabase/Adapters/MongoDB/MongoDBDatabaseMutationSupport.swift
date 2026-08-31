import Foundation
import MongoKitten

enum MongoDBDatabaseMutationSupport {
    static let invalidMutation = failure(
        category: .invalidRequest,
        message: "The MongoDB document mutation is invalid.",
        code: "mongodb.mutation.invalid")
    static let mutationFailed = failure(
        category: .server,
        message: "The MongoDB document mutation could not be applied.",
        code: "mongodb.mutation.failed")

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
            transactionBehavior: .nontransactional,
            rollbackAvailability: .unavailable,
            executionMode: .synchronous,
            warnings: [
                DatabaseWarning(
                    code: "mongodb.mutation.no_rollback",
                    message: "This MongoDB document change cannot be rolled back after execution.",
                    severity: .caution,
                    target: request.target)
            ])
    }

    static func execution(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID,
        maximumTimeMilliseconds: Int32
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseMutationPlan {
        let normalized = try normalize(plan.request, connectionID: connectionID)
        guard normalized == plan else { throw invalidMutation }
        let mutation = try validatedMutation(plan.request, connectionID: connectionID)
        return MongoDBDatabaseMutationPlan(
            database: mutation.database,
            collection: mutation.collection,
            operation: mutation.operation,
            maximumTimeMilliseconds: maximumTimeMilliseconds)
    }

    static func result(
        _ result: MongoDBDatabaseMutationResult,
        operation: MongoDBDatabaseMutationOperation
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        let affectedRecords: UInt64
        let applied: Bool
        switch operation {
        case .insert:
            affectedRecords = try bounded(result.insertedCount)
            applied = result.insertedCount == 1
        case .update:
            guard result.matchedCount == 0 || result.matchedCount == 1,
                result.modifiedCount == 0 || result.modifiedCount == 1,
                result.modifiedCount <= result.matchedCount
            else {
                throw mutationFailed
            }
            affectedRecords = UInt64(result.modifiedCount)
            applied = result.matchedCount == 1
        case .delete:
            affectedRecords = try bounded(result.deletedCount)
            applied = result.deletedCount == 1
        }
        if applied {
            return try DatabaseAdapterMutationResult(
                disposition: .completed,
                effect: .applied,
                affectedRecords: DatabaseCountMetadata(
                    value: affectedRecords,
                    accuracy: .exact))
        }
        return try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .notApplied,
            affectedRecords: DatabaseCountMetadata(value: 0, accuracy: .exact),
            error: DatabaseErrorEnvelope(
                category: .conflict,
                message: "The MongoDB document no longer matched the requested mutation.",
                productCode: "mongodb.mutation.document_not_found_or_exists"))
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> MongoDBDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            let object = request.target.object,
            object.path.count == 2,
            case let .document(product, operation, parameters, body) = request.payload,
            product == .mongoDB,
            parameters.isEmpty
        else {
            throw invalidMutation
        }
        do {
            let canonical: DatabaseDestructiveRequest
            let mutationOperation: MongoDBDatabaseMutationOperation
            let action: DatabaseDestructiveAction
            let scope: DatabaseMutationScope
            let description: String
            switch operation {
            case "insertOne":
                canonical = try DatabaseDocumentMutationRequests.mongoDBInsert(
                    target: request.target,
                    document: body)
                mutationOperation = .insert(try MongoDBDatabaseValueCodec.queryDocument(body))
                action = .insert
                scope = .entireObject
                description = "Insert one document"
            case "updateOne":
                guard case let .object(values) = body else {
                    throw DatabaseDocumentMutationRequestError.invalidDocument
                }
                canonical = try DatabaseDocumentMutationRequests.mongoDBUpdate(
                    target: request.target,
                    values: values)
                mutationOperation = .update(
                    filter: try identityFilter(request.target),
                    values: try MongoDBDatabaseValueCodec.queryDocument(body))
                action = .update
                scope = .singleRecord
                description = "Update one identified document"
            case "deleteOne":
                guard body == .null else {
                    throw DatabaseDocumentMutationRequestError.invalidDocument
                }
                canonical = try DatabaseDocumentMutationRequests.mongoDBDelete(
                    target: request.target)
                mutationOperation = .delete(filter: try identityFilter(request.target))
                action = .delete
                scope = .singleRecord
                description = "Delete one identified document"
            default:
                throw DatabaseDocumentMutationRequestError.invalidDocument
            }
            guard canonical == request else { throw invalidMutation }
            return MongoDBDatabaseValidatedMutation(
                action: action,
                scope: scope,
                database: object.path[0],
                collection: object.path[1],
                operation: mutationOperation,
                impactDescription: description)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidMutation
        }
    }

    private static func identityFilter(
        _ target: DatabaseTargetIdentifier
    ) throws -> Document {
        let value = try DatabaseDocumentMutationRequests.mongoDBIdentityValue(target)
        var filter = Document()
        filter["_id"] = try MongoDBDatabaseValueCodec.queryPrimitive(value)
        return filter
    }

    private static func bounded(_ value: Int) throws(DatabaseAdapterFailure) -> UInt64 {
        guard value == 0 || value == 1 else { throw mutationFailed }
        return UInt64(value)
    }

    private static func failure(
        category: DatabaseErrorCategory,
        message: String,
        code: String
    ) -> DatabaseAdapterFailure {
        .reported(
            DatabaseErrorEnvelope(
                category: category,
                message: message,
                productCode: code))
    }
}

private struct MongoDBDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let database: String
    let collection: String
    let operation: MongoDBDatabaseMutationOperation
    let impactDescription: String
}
