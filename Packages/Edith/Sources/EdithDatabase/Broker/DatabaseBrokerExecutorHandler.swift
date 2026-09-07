import Foundation

struct DatabaseBrokerExecutorHandler: DatabaseBrokerCommandHandler {
    let executor: DatabaseExecutor

    func connect(
        _ request: DatabaseConnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectResult> {
        await executor.connect(request)
    }

    func disconnect(
        _ request: DatabaseDisconnectRequest
    ) async throws -> DatabaseCommandResult<DatabaseDisconnectResult> {
        await executor.disconnect(request)
    }

    func connectionTest(
        _ request: DatabaseConnectionTestRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionTestResult> {
        await executor.testConnection(request)
    }

    func connectionList(
        _ request: DatabaseConnectionListRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionListResult> {
        await executor.connections(request)
    }

    func connectionGet(
        _ request: DatabaseConnectionGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionGetResult> {
        await executor.connection(request)
    }

    func connectionSave(
        _ request: DatabaseConnectionSaveRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionSaveResult> {
        await executor.saveConnection(request)
    }

    func connectionEdit(
        _ request: DatabaseConnectionEditRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionEditResult> {
        await executor.editConnection(request)
    }

    func connectionDuplicate(
        _ request: DatabaseConnectionDuplicateRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionDuplicateResult> {
        await executor.duplicateConnection(request)
    }

    func connectionRename(
        _ request: DatabaseConnectionRenameRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionRenameResult> {
        await executor.renameConnection(request)
    }

    func connectionDelete(
        _ request: DatabaseConnectionDeleteRequest
    ) async throws -> DatabaseCommandResult<DatabaseConnectionDeleteResult> {
        await executor.deleteConnection(request)
    }

    func capabilities(
        _ request: DatabaseCapabilitiesRequest
    ) async throws -> DatabaseCommandResult<DatabaseCapabilitiesResult> {
        await executor.capabilities(request)
    }

    func browse(
        _ request: DatabaseBrowseRequest
    ) async throws -> DatabaseCommandResult<DatabaseBrowseResult> {
        await executor.browse(request)
    }

    func query(
        _ request: DatabaseQueryRequest
    ) async throws -> DatabaseCommandResult<DatabaseQueryResult> {
        await executor.query(request)
    }

    func mutationPreview(
        _ request: DatabaseMutationPreviewRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationPreviewResult> {
        await executor.previewMutation(request)
    }

    func mutationApply(
        _ request: DatabaseMutationApplyRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationApplyResult> {
        await executor.applyMutation(request)
    }

    func mutationStatus(
        _ request: DatabaseMutationStatusRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationStatusResult> {
        await executor.mutationStatus(request)
    }

    func mutationCancel(
        _ request: DatabaseMutationCancelRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationCancelResult> {
        await executor.cancelMutation(request)
    }

    func mutationOutcomeGet(
        _ request: DatabaseMutationOutcomeGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseMutationOutcomeGetResult> {
        await executor.mutationOutcome(request)
    }

    func savedQueryList(
        _ request: DatabaseSavedQueryListRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryListResult> {
        await executor.savedQueries(request)
    }

    func savedQueryGet(
        _ request: DatabaseSavedQueryGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryGetResult> {
        await executor.savedQuery(request)
    }

    func savedQuerySave(
        _ request: DatabaseSavedQuerySaveRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQuerySaveResult> {
        await executor.saveSavedQuery(request)
    }

    func savedQueryDuplicate(
        _ request: DatabaseSavedQueryDuplicateRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryDuplicateResult> {
        await executor.duplicateSavedQuery(request)
    }

    func savedQueryRename(
        _ request: DatabaseSavedQueryRenameRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryRenameResult> {
        await executor.renameSavedQuery(request)
    }

    func savedQueryDelete(
        _ request: DatabaseSavedQueryDeleteRequest
    ) async throws -> DatabaseCommandResult<DatabaseSavedQueryDeleteResult> {
        await executor.deleteSavedQuery(request)
    }

    func operationGet(
        _ request: DatabaseOperationGetRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationGetResult> {
        await executor.operation(request)
    }

    func operationList(
        _ request: DatabaseOperationListRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationListResult> {
        await executor.operations(request)
    }

    func operationCancel(
        _ request: DatabaseOperationCancelRequest
    ) async throws -> DatabaseCommandResult<DatabaseOperationCancelResult> {
        await executor.cancel(request)
    }

    private static func unsupported<Payload: Sendable>(
        _ message: String,
        target: DatabaseTargetIdentifier?
    ) -> DatabaseCommandResult<Payload> {
        .failure(
            DatabaseErrorEnvelope(
                category: .unsupported,
                message: message,
                target: target),
            metadata: DatabaseResultMetadata(
                completeness: DatabaseResultCompleteness(state: .complete)))
    }
}
