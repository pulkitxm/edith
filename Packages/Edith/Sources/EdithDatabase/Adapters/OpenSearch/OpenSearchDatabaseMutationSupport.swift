import Foundation

enum OpenSearchDatabaseMutationSupport {
    static let invalidMutation = failure(
        category: .invalidRequest,
        message: "The OpenSearch document mutation is invalid.",
        code: "opensearch.mutation.invalid")
    static let mutationFailed = failure(
        category: .server,
        message: "The OpenSearch document mutation could not be applied.",
        code: "opensearch.mutation.failed")

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
                    code: "opensearch.mutation.no_rollback",
                    message:
                        "This OpenSearch document change cannot be rolled back after execution.",
                    severity: .caution,
                    target: request.target)
            ])
    }

    static func execution(
        _ plan: DatabaseDestructivePlan,
        connectionID: DatabaseConnectionID
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseMutationPlan {
        let normalized = try normalize(plan.request, connectionID: connectionID)
        guard normalized == plan else { throw invalidMutation }
        return try validatedMutation(plan.request, connectionID: connectionID).plan
    }

    static func result(
        _ result: OpenSearchDatabaseMutationResult,
        plan: OpenSearchDatabaseMutationPlan
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
    ) throws(DatabaseAdapterFailure) -> OpenSearchDatabaseValidatedMutation {
        guard request.target.connectionID == connectionID,
            request.selectedRecords.isEmpty,
            request.predicate == nil,
            case let .search(product, operation, parameters, body) = request.payload,
            product == .openSearch,
            parameters.isEmpty
        else {
            throw invalidMutation
        }
        do {
            let canonical: DatabaseDestructiveRequest
            let identity: DatabaseSearchDocumentIdentity
            let mutationOperation: OpenSearchDatabaseMutationOperation
            let action: DatabaseDestructiveAction
            let scope: DatabaseMutationScope
            let description: String
            switch operation {
            case "create":
                canonical = try DatabaseDocumentMutationRequests.openSearchCreate(
                    target: request.target,
                    document: body)
                identity = try DatabaseDocumentMutationRequests.openSearchIdentity(
                    request.target,
                    requiresConcurrency: false)
                mutationOperation = .create(body: try encodedDocument(body))
                action = .insert
                scope = .singleRecord
                description = "Create one document"
            case "replace":
                canonical = try DatabaseDocumentMutationRequests.openSearchReplace(
                    target: request.target,
                    document: body)
                identity = try DatabaseDocumentMutationRequests.openSearchIdentity(
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
                canonical = try DatabaseDocumentMutationRequests.openSearchDelete(
                    target: request.target)
                identity = try DatabaseDocumentMutationRequests.openSearchIdentity(
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
            return OpenSearchDatabaseValidatedMutation(
                action: action,
                scope: scope,
                plan: OpenSearchDatabaseMutationPlan(
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
        try OpenSearchDatabaseJSONCodec.encode(
            OpenSearchDatabaseJSONValue(databaseValue: value))
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

private struct OpenSearchDatabaseValidatedMutation {
    let action: DatabaseDestructiveAction
    let scope: DatabaseMutationScope
    let plan: OpenSearchDatabaseMutationPlan
    let impactDescription: String
}
