import Foundation

enum ElasticsearchDatabaseMutationSupport {
    static let invalidMutation = failure(
        category: .invalidRequest,
        message: "The Elasticsearch document mutation is invalid.",
        code: "elasticsearch.mutation.invalid")
    static let mutationFailed = failure(
        category: .server,
        message: "The Elasticsearch document mutation could not be applied.",
        code: "elasticsearch.mutation.failed")

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
                    code: "elasticsearch.mutation.no_rollback",
                    message:
                        "This Elasticsearch document change cannot be rolled back after execution.",
                    severity: .caution,
                    target: request.target)
            ])
    }

    static func execution(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseMutationPlan {
        let normalized = try normalize(plan.request, connectionID: connectionID)
        guard normalized == plan else { throw invalidMutation }
        return try validatedMutation(plan.request, connectionID: connectionID).plan
    }

    static func result(
        _ result: ElasticsearchDatabaseMutationResult,
        plan: ElasticsearchDatabaseMutationPlan
    ) throws(DatabaseAdapterFailure) -> DatabaseAdapterMutationResult {
        let expected: String
        switch plan.operation {
        case .create: expected = "created"
        case .replace: expected = "updated"
        case .delete: expected = "deleted"
        }
        guard result.index == plan.index,
            result.identifier == plan.identifier,
            result.result == expected
        else {
            throw mutationFailed
        }
        return try DatabaseAdapterMutationResult(
            disposition: .completed,
            effect: .applied,
            affectedRecords: DatabaseCountMetadata(value: 1, accuracy: .exact))
    }

    private static func validatedMutation(
        _ request: DatabaseDestructiveRequest,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> ElasticsearchDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            case let .document(product, operation, parameters, body) = request.payload,
            product == .elasticsearch,
            parameters.isEmpty
        else {
            throw invalidMutation
        }
        do {
            let canonical: DatabaseDestructiveRequest
            let identity: DatabaseSearchDocumentIdentity
            let mutationOperation: ElasticsearchDatabaseMutationOperation
            let action: DatabaseDestructiveAction
            let scope: DatabaseMutationScope
            let description: String
            switch operation {
            case "create":
                canonical = try DatabaseDocumentMutationRequests.elasticsearchCreate(
                    target: request.target,
                    document: body)
                identity = try DatabaseDocumentMutationRequests.elasticsearchIdentity(
                    request.target,
                    requiresConcurrency: false)
                mutationOperation = .create(body: try encodedDocument(body))
                action = .insert
                scope = .singleRecord
                description = "Create one document"
            case "replace":
                canonical = try DatabaseDocumentMutationRequests.elasticsearchReplace(
                    target: request.target,
                    document: body)
                identity = try DatabaseDocumentMutationRequests.elasticsearchIdentity(
                    request.target,
                    requiresConcurrency: true)
                guard let sequenceNumber = identity.sequenceNumber,
                    let primaryTerm = identity.primaryTerm
                else {
                    throw invalidMutation
                }
                mutationOperation = .replace(
                    body: try encodedDocument(body),
                    sequenceNumber: sequenceNumber,
                    primaryTerm: primaryTerm)
                action = .update
                scope = .singleRecord
                description = "Replace one document"
            case "delete":
                guard body == .null else { throw invalidMutation }
                canonical = try DatabaseDocumentMutationRequests.elasticsearchDelete(
                    target: request.target)
                identity = try DatabaseDocumentMutationRequests.elasticsearchIdentity(
                    request.target,
                    requiresConcurrency: true)
                guard let sequenceNumber = identity.sequenceNumber,
                    let primaryTerm = identity.primaryTerm
                else {
                    throw invalidMutation
                }
                mutationOperation = .delete(
                    sequenceNumber: sequenceNumber,
                    primaryTerm: primaryTerm)
                action = .delete
                scope = .singleRecord
                description = "Delete one document"
            default:
                throw invalidMutation
            }
            guard canonical == request else { throw invalidMutation }
            return ElasticsearchDatabaseValidatedMutation(
                action: action,
                scope: scope,
                plan: ElasticsearchDatabaseMutationPlan(
                    index: identity.index,
                    identifier: identity.identifier,
                    operation: mutationOperation),
                impactDescription: description)
        } catch let failure as DatabaseAdapterFailure {
            throw failure
        } catch {
            throw invalidMutation
        }
    }

    private static func encodedDocument(
        _ value: DatabaseValue
    ) throws -> Data {
        try ElasticsearchDatabaseJSONCodec.encode(
            ElasticsearchDatabaseJSONValue(databaseValue: value))
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

private struct ElasticsearchDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let plan: ElasticsearchDatabaseMutationPlan
    let impactDescription: String
}
