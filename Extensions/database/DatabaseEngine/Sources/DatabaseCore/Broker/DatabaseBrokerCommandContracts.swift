import Foundation

public enum DatabaseBrokerCommandKind: String, CaseIterable, Codable, Hashable, Sendable {
    case connect = "database.connection.connect"
    case disconnect = "database.connection.disconnect"
    case connectionTest = "database.connection.test"
    case connectionList = "database.connection.list"
    case connectionGet = "database.connection.get"
    case connectionSave = "database.connection.save"
    case connectionEdit = "database.connection.edit"
    case connectionDuplicate = "database.connection.duplicate"
    case connectionRename = "database.connection.rename"
    case connectionDelete = "database.connection.delete"
    case capabilities = "database.capabilities"
    case browse = "database.browse"
    case query = "database.query"
    case mutationPreview = "database.mutation.preview"
    case mutationApply = "database.mutation.apply"
    case mutationStatus = "database.mutation.status"
    case mutationCancel = "database.mutation.cancel"
    case mutationOutcomeGet = "database.mutation.outcome.get"
    case savedQueryList = "database.saved-query.list"
    case savedQueryGet = "database.saved-query.get"
    case savedQuerySave = "database.saved-query.save"
    case savedQueryDuplicate = "database.saved-query.duplicate"
    case savedQueryRename = "database.saved-query.rename"
    case savedQueryDelete = "database.saved-query.delete"
    case operationGet = "database.operation.get"
    case operationList = "database.operation.list"
    case operationCancel = "database.operation.cancel"
}

public enum DatabaseBrokerCommandContractError: Error, Equatable, Sendable {
    case unsupportedSchemaVersion(Int)
    case unsupportedRequestVersion(command: DatabaseBrokerCommandKind, version: Int)
    case unknownCommand(String)
    case unexpectedEnvelopeKind(
        expected: DatabaseBrokerEnvelopeKind,
        actual: DatabaseBrokerEnvelopeKind)
    case commandMismatch(
        expected: DatabaseBrokerCommandKind,
        actual: DatabaseBrokerCommandKind)
    case requestIDMismatch(expected: UUID, actual: UUID)
    case operationIDMismatch(
        expected: DatabaseOperationID?,
        actual: DatabaseOperationID?)
    case missingRequest(UUID)
}

public enum DatabaseBrokerCommandRequest: Hashable, Sendable {
    public static let schemaVersion = 1

    case connect(DatabaseConnectRequest)
    case disconnect(DatabaseDisconnectRequest)
    case connectionTest(DatabaseConnectionTestRequest)
    case connectionList(DatabaseConnectionListRequest)
    case connectionGet(DatabaseConnectionGetRequest)
    case connectionSave(DatabaseConnectionSaveRequest)
    case connectionEdit(DatabaseConnectionEditRequest)
    case connectionDuplicate(DatabaseConnectionDuplicateRequest)
    case connectionRename(DatabaseConnectionRenameRequest)
    case connectionDelete(DatabaseConnectionDeleteRequest)
    case capabilities(DatabaseCapabilitiesRequest)
    case browse(DatabaseBrowseRequest)
    case query(DatabaseQueryRequest)
    case mutationPreview(DatabaseMutationPreviewRequest)
    case mutationApply(DatabaseMutationApplyRequest)
    case mutationStatus(DatabaseMutationStatusRequest)
    case mutationCancel(DatabaseMutationCancelRequest)
    case mutationOutcomeGet(DatabaseMutationOutcomeGetRequest)
    case savedQueryList(DatabaseSavedQueryListRequest)
    case savedQueryGet(DatabaseSavedQueryGetRequest)
    case savedQuerySave(DatabaseSavedQuerySaveRequest)
    case savedQueryDuplicate(DatabaseSavedQueryDuplicateRequest)
    case savedQueryRename(DatabaseSavedQueryRenameRequest)
    case savedQueryDelete(DatabaseSavedQueryDeleteRequest)
    case operationGet(DatabaseOperationGetRequest)
    case operationList(DatabaseOperationListRequest)
    case operationCancel(DatabaseOperationCancelRequest)

    public var kind: DatabaseBrokerCommandKind {
        switch self {
        case .connect:
            .connect
        case .disconnect:
            .disconnect
        case .connectionTest:
            .connectionTest
        case .connectionList:
            .connectionList
        case .connectionGet:
            .connectionGet
        case .connectionSave:
            .connectionSave
        case .connectionEdit:
            .connectionEdit
        case .connectionDuplicate:
            .connectionDuplicate
        case .connectionRename:
            .connectionRename
        case .connectionDelete:
            .connectionDelete
        case .capabilities:
            .capabilities
        case .browse:
            .browse
        case .query:
            .query
        case .mutationPreview:
            .mutationPreview
        case .mutationApply:
            .mutationApply
        case .mutationStatus:
            .mutationStatus
        case .mutationCancel:
            .mutationCancel
        case .mutationOutcomeGet:
            .mutationOutcomeGet
        case .savedQueryList:
            .savedQueryList
        case .savedQueryGet:
            .savedQueryGet
        case .savedQuerySave:
            .savedQuerySave
        case .savedQueryDuplicate:
            .savedQueryDuplicate
        case .savedQueryRename:
            .savedQueryRename
        case .savedQueryDelete:
            .savedQueryDelete
        case .operationGet:
            .operationGet
        case .operationList:
            .operationList
        case .operationCancel:
            .operationCancel
        }
    }

    public var operationID: DatabaseOperationID? {
        switch self {
        case .connect(let request):
            request.operation.operationID
        case .disconnect(let request):
            request.operation.operationID
        case .connectionTest(let request):
            request.operation.operationID
        case .connectionList, .connectionGet, .connectionSave, .connectionEdit,
            .connectionDuplicate, .connectionRename, .connectionDelete:
            nil
        case .capabilities(let request):
            request.operation.operationID
        case .browse(let request):
            request.operation.operationID
        case .query(let request):
            request.operation.operationID
        case .mutationPreview(let request):
            request.operation.operationID
        case .mutationApply(let request):
            request.operation.operationID
        case .mutationStatus(let request):
            request.operation.operationID
        case .mutationCancel(let request):
            request.operation.operationID
        case .mutationOutcomeGet(let request):
            request.operationID
        case .savedQueryList, .savedQueryGet, .savedQuerySave, .savedQueryDuplicate,
            .savedQueryRename, .savedQueryDelete:
            nil
        case .operationGet(let request):
            request.operationID
        case .operationList:
            nil
        case .operationCancel(let request):
            request.operationID
        }
    }

    public var connectRequest: DatabaseConnectRequest? {
        guard case .connect(let request) = self else { return nil }
        return request
    }

    public var disconnectRequest: DatabaseDisconnectRequest? {
        guard case .disconnect(let request) = self else { return nil }
        return request
    }

    public var connectionTestRequest: DatabaseConnectionTestRequest? {
        guard case .connectionTest(let request) = self else { return nil }
        return request
    }

    public var connectionListRequest: DatabaseConnectionListRequest? {
        guard case .connectionList(let request) = self else { return nil }
        return request
    }

    public var connectionGetRequest: DatabaseConnectionGetRequest? {
        guard case .connectionGet(let request) = self else { return nil }
        return request
    }

    public var connectionSaveRequest: DatabaseConnectionSaveRequest? {
        guard case .connectionSave(let request) = self else { return nil }
        return request
    }

    public var connectionEditRequest: DatabaseConnectionEditRequest? {
        guard case .connectionEdit(let request) = self else { return nil }
        return request
    }

    public var connectionDuplicateRequest: DatabaseConnectionDuplicateRequest? {
        guard case .connectionDuplicate(let request) = self else { return nil }
        return request
    }

    public var connectionRenameRequest: DatabaseConnectionRenameRequest? {
        guard case .connectionRename(let request) = self else { return nil }
        return request
    }

    public var connectionDeleteRequest: DatabaseConnectionDeleteRequest? {
        guard case .connectionDelete(let request) = self else { return nil }
        return request
    }

    public var capabilitiesRequest: DatabaseCapabilitiesRequest? {
        guard case .capabilities(let request) = self else { return nil }
        return request
    }

    public var browseRequest: DatabaseBrowseRequest? {
        guard case .browse(let request) = self else { return nil }
        return request
    }

    public var queryRequest: DatabaseQueryRequest? {
        guard case .query(let request) = self else { return nil }
        return request
    }

    public var mutationPreviewRequest: DatabaseMutationPreviewRequest? {
        guard case .mutationPreview(let request) = self else { return nil }
        return request
    }

    public var mutationApplyRequest: DatabaseMutationApplyRequest? {
        guard case .mutationApply(let request) = self else { return nil }
        return request
    }

    public var mutationStatusRequest: DatabaseMutationStatusRequest? {
        guard case .mutationStatus(let request) = self else { return nil }
        return request
    }

    public var mutationCancelRequest: DatabaseMutationCancelRequest? {
        guard case .mutationCancel(let request) = self else { return nil }
        return request
    }

    public var mutationOutcomeGetRequest: DatabaseMutationOutcomeGetRequest? {
        guard case .mutationOutcomeGet(let request) = self else { return nil }
        return request
    }

    public var savedQueryListRequest: DatabaseSavedQueryListRequest? {
        guard case .savedQueryList(let request) = self else { return nil }
        return request
    }

    public var savedQueryGetRequest: DatabaseSavedQueryGetRequest? {
        guard case .savedQueryGet(let request) = self else { return nil }
        return request
    }

    public var savedQuerySaveRequest: DatabaseSavedQuerySaveRequest? {
        guard case .savedQuerySave(let request) = self else { return nil }
        return request
    }

    public var savedQueryDuplicateRequest: DatabaseSavedQueryDuplicateRequest? {
        guard case .savedQueryDuplicate(let request) = self else { return nil }
        return request
    }

    public var savedQueryRenameRequest: DatabaseSavedQueryRenameRequest? {
        guard case .savedQueryRename(let request) = self else { return nil }
        return request
    }

    public var savedQueryDeleteRequest: DatabaseSavedQueryDeleteRequest? {
        guard case .savedQueryDelete(let request) = self else { return nil }
        return request
    }

    public var operationGetRequest: DatabaseOperationGetRequest? {
        guard case .operationGet(let request) = self else { return nil }
        return request
    }

    public var operationListRequest: DatabaseOperationListRequest? {
        guard case .operationList(let request) = self else { return nil }
        return request
    }

    public var operationCancelRequest: DatabaseOperationCancelRequest? {
        guard case .operationCancel(let request) = self else { return nil }
        return request
    }

    public func envelope(
        requestID: UUID,
        sequence: UInt64
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            operationID: operationID,
            sequence: sequence,
            kind: .request,
            payload: self)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connect)
        return .connect(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseDisconnectResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.disconnect)
        return .disconnect(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionTestResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionTest)
        return .connectionTest(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionListResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionList)
        return .connectionList(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionGetResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionGet)
        return .connectionGet(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionSaveResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionSave)
        return .connectionSave(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionEditResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionEdit)
        return .connectionEdit(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionDuplicateResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionDuplicate)
        return .connectionDuplicate(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionRenameResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionRename)
        return .connectionRename(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseConnectionDeleteResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.connectionDelete)
        return .connectionDelete(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseCapabilitiesResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.capabilities)
        return .capabilities(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseBrowseResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.browse)
        return .browse(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseQueryResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.query)
        return .query(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseMutationPreviewResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.mutationPreview)
        return .mutationPreview(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseMutationApplyResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.mutationApply)
        return .mutationApply(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseMutationStatusResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.mutationStatus)
        return .mutationStatus(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseMutationCancelResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.mutationCancel)
        return .mutationCancel(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseMutationOutcomeGetResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.mutationOutcomeGet)
        return .mutationOutcomeGet(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQueryListResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQueryList)
        return .savedQueryList(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQueryGetResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQueryGet)
        return .savedQueryGet(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQuerySaveResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQuerySave)
        return .savedQuerySave(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQueryDuplicateResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQueryDuplicate)
        return .savedQueryDuplicate(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQueryRenameResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQueryRename)
        return .savedQueryRename(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseSavedQueryDeleteResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.savedQueryDelete)
        return .savedQueryDelete(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseOperationGetResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.operationGet)
        return .operationGet(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseOperationListResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.operationList)
        return .operationList(result)
    }

    public func response(
        _ result: DatabaseCommandResult<DatabaseOperationCancelResult>
    ) throws -> DatabaseBrokerCommandResponse {
        try require(.operationCancel)
        return .operationCancel(result)
    }

    fileprivate func validate() throws {
        let version: Int
        let supportedVersion: Int
        switch self {
        case .connect(let request):
            version = request.version
            supportedVersion = DatabaseConnectRequest.schemaVersion
        case .disconnect(let request):
            version = request.version
            supportedVersion = DatabaseDisconnectRequest.schemaVersion
        case .connectionTest(let request):
            version = request.version
            supportedVersion = DatabaseConnectionTestRequest.schemaVersion
        case .connectionList(let request):
            version = request.version
            supportedVersion = DatabaseConnectionListRequest.schemaVersion
        case .connectionGet(let request):
            version = request.version
            supportedVersion = DatabaseConnectionGetRequest.schemaVersion
        case .connectionSave(let request):
            version = request.version
            supportedVersion = DatabaseConnectionSaveRequest.schemaVersion
        case .connectionEdit(let request):
            version = request.version
            supportedVersion = DatabaseConnectionEditRequest.schemaVersion
        case .connectionDuplicate(let request):
            version = request.version
            supportedVersion = DatabaseConnectionDuplicateRequest.schemaVersion
        case .connectionRename(let request):
            version = request.version
            supportedVersion = DatabaseConnectionRenameRequest.schemaVersion
        case .connectionDelete(let request):
            version = request.version
            supportedVersion = DatabaseConnectionDeleteRequest.schemaVersion
        case .capabilities(let request):
            version = request.version
            supportedVersion = DatabaseCapabilitiesRequest.schemaVersion
        case .browse(let request):
            version = request.version
            supportedVersion = DatabaseBrowseRequest.schemaVersion
        case .query(let request):
            version = request.version
            supportedVersion = DatabaseQueryRequest.schemaVersion
        case .mutationPreview(let request):
            version = request.version
            supportedVersion = DatabaseMutationPreviewRequest.schemaVersion
        case .mutationApply(let request):
            version = request.version
            supportedVersion = DatabaseMutationApplyRequest.schemaVersion
        case .mutationStatus(let request):
            version = request.version
            supportedVersion = DatabaseMutationStatusRequest.schemaVersion
        case .mutationCancel(let request):
            version = request.version
            supportedVersion = DatabaseMutationCancelRequest.schemaVersion
        case .mutationOutcomeGet(let request):
            version = request.version
            supportedVersion = DatabaseMutationOutcomeGetRequest.schemaVersion
        case .savedQueryList(let request):
            version = request.version
            supportedVersion = DatabaseSavedQueryListRequest.schemaVersion
        case .savedQueryGet(let request):
            version = request.version
            supportedVersion = DatabaseSavedQueryGetRequest.schemaVersion
        case .savedQuerySave(let request):
            version = request.version
            supportedVersion = DatabaseSavedQuerySaveRequest.schemaVersion
        case .savedQueryDuplicate(let request):
            version = request.version
            supportedVersion = DatabaseSavedQueryDuplicateRequest.schemaVersion
        case .savedQueryRename(let request):
            version = request.version
            supportedVersion = DatabaseSavedQueryRenameRequest.schemaVersion
        case .savedQueryDelete(let request):
            version = request.version
            supportedVersion = DatabaseSavedQueryDeleteRequest.schemaVersion
        case .operationGet(let request):
            version = request.version
            supportedVersion = DatabaseOperationGetRequest.schemaVersion
        case .operationList(let request):
            version = request.version
            supportedVersion = DatabaseOperationListRequest.schemaVersion
        case .operationCancel(let request):
            version = request.version
            supportedVersion = DatabaseOperationCancelRequest.schemaVersion
        }
        guard version == supportedVersion else {
            throw DatabaseBrokerCommandContractError.unsupportedRequestVersion(
                command: kind,
                version: version)
        }
    }

    private func require(_ responseKind: DatabaseBrokerCommandKind) throws {
        guard kind == responseKind else {
            throw DatabaseBrokerCommandContractError.commandMismatch(
                expected: kind,
                actual: responseKind)
        }
    }
}

extension DatabaseBrokerCommandRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case command
        case request
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DatabaseBrokerCommandContractError.unsupportedSchemaVersion(version)
        }
        let commandValue = try container.decode(String.self, forKey: .command)
        guard let command = DatabaseBrokerCommandKind(rawValue: commandValue) else {
            throw DatabaseBrokerCommandContractError.unknownCommand(commandValue)
        }
        switch command {
        case .connect:
            self = .connect(
                try container.decode(DatabaseConnectRequest.self, forKey: .request))
        case .disconnect:
            self = .disconnect(
                try container.decode(DatabaseDisconnectRequest.self, forKey: .request))
        case .connectionTest:
            self = .connectionTest(
                try container.decode(DatabaseConnectionTestRequest.self, forKey: .request))
        case .connectionList:
            self = .connectionList(
                try container.decode(DatabaseConnectionListRequest.self, forKey: .request))
        case .connectionGet:
            self = .connectionGet(
                try container.decode(DatabaseConnectionGetRequest.self, forKey: .request))
        case .connectionSave:
            self = .connectionSave(
                try container.decode(DatabaseConnectionSaveRequest.self, forKey: .request))
        case .connectionEdit:
            self = .connectionEdit(
                try container.decode(DatabaseConnectionEditRequest.self, forKey: .request))
        case .connectionDuplicate:
            self = .connectionDuplicate(
                try container.decode(
                    DatabaseConnectionDuplicateRequest.self,
                    forKey: .request))
        case .connectionRename:
            self = .connectionRename(
                try container.decode(DatabaseConnectionRenameRequest.self, forKey: .request))
        case .connectionDelete:
            self = .connectionDelete(
                try container.decode(DatabaseConnectionDeleteRequest.self, forKey: .request))
        case .capabilities:
            self = .capabilities(
                try container.decode(DatabaseCapabilitiesRequest.self, forKey: .request))
        case .browse:
            self = .browse(
                try container.decode(DatabaseBrowseRequest.self, forKey: .request))
        case .query:
            self = .query(
                try container.decode(DatabaseQueryRequest.self, forKey: .request))
        case .mutationPreview:
            self = .mutationPreview(
                try container.decode(DatabaseMutationPreviewRequest.self, forKey: .request))
        case .mutationApply:
            self = .mutationApply(
                try container.decode(DatabaseMutationApplyRequest.self, forKey: .request))
        case .mutationStatus:
            self = .mutationStatus(
                try container.decode(DatabaseMutationStatusRequest.self, forKey: .request))
        case .mutationCancel:
            self = .mutationCancel(
                try container.decode(DatabaseMutationCancelRequest.self, forKey: .request))
        case .mutationOutcomeGet:
            self = .mutationOutcomeGet(
                try container.decode(DatabaseMutationOutcomeGetRequest.self, forKey: .request))
        case .savedQueryList:
            self = .savedQueryList(
                try container.decode(DatabaseSavedQueryListRequest.self, forKey: .request))
        case .savedQueryGet:
            self = .savedQueryGet(
                try container.decode(DatabaseSavedQueryGetRequest.self, forKey: .request))
        case .savedQuerySave:
            self = .savedQuerySave(
                try container.decode(DatabaseSavedQuerySaveRequest.self, forKey: .request))
        case .savedQueryDuplicate:
            self = .savedQueryDuplicate(
                try container.decode(DatabaseSavedQueryDuplicateRequest.self, forKey: .request))
        case .savedQueryRename:
            self = .savedQueryRename(
                try container.decode(DatabaseSavedQueryRenameRequest.self, forKey: .request))
        case .savedQueryDelete:
            self = .savedQueryDelete(
                try container.decode(DatabaseSavedQueryDeleteRequest.self, forKey: .request))
        case .operationGet:
            self = .operationGet(
                try container.decode(DatabaseOperationGetRequest.self, forKey: .request))
        case .operationList:
            self = .operationList(
                try container.decode(DatabaseOperationListRequest.self, forKey: .request))
        case .operationCancel:
            self = .operationCancel(
                try container.decode(DatabaseOperationCancelRequest.self, forKey: .request))
        }
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        try validate()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(kind.rawValue, forKey: .command)
        switch self {
        case .connect(let request):
            try container.encode(request, forKey: .request)
        case .disconnect(let request):
            try container.encode(request, forKey: .request)
        case .connectionTest(let request):
            try container.encode(request, forKey: .request)
        case .connectionList(let request):
            try container.encode(request, forKey: .request)
        case .connectionGet(let request):
            try container.encode(request, forKey: .request)
        case .connectionSave(let request):
            try container.encode(request, forKey: .request)
        case .connectionEdit(let request):
            try container.encode(request, forKey: .request)
        case .connectionDuplicate(let request):
            try container.encode(request, forKey: .request)
        case .connectionRename(let request):
            try container.encode(request, forKey: .request)
        case .connectionDelete(let request):
            try container.encode(request, forKey: .request)
        case .capabilities(let request):
            try container.encode(request, forKey: .request)
        case .browse(let request):
            try container.encode(request, forKey: .request)
        case .query(let request):
            try container.encode(request, forKey: .request)
        case .mutationPreview(let request):
            try container.encode(request, forKey: .request)
        case .mutationApply(let request):
            try container.encode(request, forKey: .request)
        case .mutationStatus(let request):
            try container.encode(request, forKey: .request)
        case .mutationCancel(let request):
            try container.encode(request, forKey: .request)
        case .mutationOutcomeGet(let request):
            try container.encode(request, forKey: .request)
        case .savedQueryList(let request):
            try container.encode(request, forKey: .request)
        case .savedQueryGet(let request):
            try container.encode(request, forKey: .request)
        case .savedQuerySave(let request):
            try container.encode(request, forKey: .request)
        case .savedQueryDuplicate(let request):
            try container.encode(request, forKey: .request)
        case .savedQueryRename(let request):
            try container.encode(request, forKey: .request)
        case .savedQueryDelete(let request):
            try container.encode(request, forKey: .request)
        case .operationGet(let request):
            try container.encode(request, forKey: .request)
        case .operationList(let request):
            try container.encode(request, forKey: .request)
        case .operationCancel(let request):
            try container.encode(request, forKey: .request)
        }
    }
}

public enum DatabaseBrokerCommandResponse: Hashable, Sendable {
    public static let schemaVersion = 1

    case connect(DatabaseCommandResult<DatabaseConnectResult>)
    case disconnect(DatabaseCommandResult<DatabaseDisconnectResult>)
    case connectionTest(DatabaseCommandResult<DatabaseConnectionTestResult>)
    case connectionList(DatabaseCommandResult<DatabaseConnectionListResult>)
    case connectionGet(DatabaseCommandResult<DatabaseConnectionGetResult>)
    case connectionSave(DatabaseCommandResult<DatabaseConnectionSaveResult>)
    case connectionEdit(DatabaseCommandResult<DatabaseConnectionEditResult>)
    case connectionDuplicate(DatabaseCommandResult<DatabaseConnectionDuplicateResult>)
    case connectionRename(DatabaseCommandResult<DatabaseConnectionRenameResult>)
    case connectionDelete(DatabaseCommandResult<DatabaseConnectionDeleteResult>)
    case capabilities(DatabaseCommandResult<DatabaseCapabilitiesResult>)
    case browse(DatabaseCommandResult<DatabaseBrowseResult>)
    case query(DatabaseCommandResult<DatabaseQueryResult>)
    case mutationPreview(DatabaseCommandResult<DatabaseMutationPreviewResult>)
    case mutationApply(DatabaseCommandResult<DatabaseMutationApplyResult>)
    case mutationStatus(DatabaseCommandResult<DatabaseMutationStatusResult>)
    case mutationCancel(DatabaseCommandResult<DatabaseMutationCancelResult>)
    case mutationOutcomeGet(DatabaseCommandResult<DatabaseMutationOutcomeGetResult>)
    case savedQueryList(DatabaseCommandResult<DatabaseSavedQueryListResult>)
    case savedQueryGet(DatabaseCommandResult<DatabaseSavedQueryGetResult>)
    case savedQuerySave(DatabaseCommandResult<DatabaseSavedQuerySaveResult>)
    case savedQueryDuplicate(DatabaseCommandResult<DatabaseSavedQueryDuplicateResult>)
    case savedQueryRename(DatabaseCommandResult<DatabaseSavedQueryRenameResult>)
    case savedQueryDelete(DatabaseCommandResult<DatabaseSavedQueryDeleteResult>)
    case operationGet(DatabaseCommandResult<DatabaseOperationGetResult>)
    case operationList(DatabaseCommandResult<DatabaseOperationListResult>)
    case operationCancel(DatabaseCommandResult<DatabaseOperationCancelResult>)

    public var kind: DatabaseBrokerCommandKind {
        switch self {
        case .connect:
            .connect
        case .disconnect:
            .disconnect
        case .connectionTest:
            .connectionTest
        case .connectionList:
            .connectionList
        case .connectionGet:
            .connectionGet
        case .connectionSave:
            .connectionSave
        case .connectionEdit:
            .connectionEdit
        case .connectionDuplicate:
            .connectionDuplicate
        case .connectionRename:
            .connectionRename
        case .connectionDelete:
            .connectionDelete
        case .capabilities:
            .capabilities
        case .browse:
            .browse
        case .query:
            .query
        case .mutationPreview:
            .mutationPreview
        case .mutationApply:
            .mutationApply
        case .mutationStatus:
            .mutationStatus
        case .mutationCancel:
            .mutationCancel
        case .mutationOutcomeGet:
            .mutationOutcomeGet
        case .savedQueryList:
            .savedQueryList
        case .savedQueryGet:
            .savedQueryGet
        case .savedQuerySave:
            .savedQuerySave
        case .savedQueryDuplicate:
            .savedQueryDuplicate
        case .savedQueryRename:
            .savedQueryRename
        case .savedQueryDelete:
            .savedQueryDelete
        case .operationGet:
            .operationGet
        case .operationList:
            .operationList
        case .operationCancel:
            .operationCancel
        }
    }

    public var connectResult: DatabaseCommandResult<DatabaseConnectResult>? {
        guard case .connect(let result) = self else { return nil }
        return result
    }

    public var disconnectResult: DatabaseCommandResult<DatabaseDisconnectResult>? {
        guard case .disconnect(let result) = self else { return nil }
        return result
    }

    public var connectionTestResult: DatabaseCommandResult<DatabaseConnectionTestResult>? {
        guard case .connectionTest(let result) = self else { return nil }
        return result
    }

    public var connectionListResult: DatabaseCommandResult<DatabaseConnectionListResult>? {
        guard case .connectionList(let result) = self else { return nil }
        return result
    }

    public var connectionGetResult: DatabaseCommandResult<DatabaseConnectionGetResult>? {
        guard case .connectionGet(let result) = self else { return nil }
        return result
    }

    public var connectionSaveResult: DatabaseCommandResult<DatabaseConnectionSaveResult>? {
        guard case .connectionSave(let result) = self else { return nil }
        return result
    }

    public var connectionEditResult: DatabaseCommandResult<DatabaseConnectionEditResult>? {
        guard case .connectionEdit(let result) = self else { return nil }
        return result
    }

    public var connectionDuplicateResult: DatabaseCommandResult<DatabaseConnectionDuplicateResult>?
    {
        guard case .connectionDuplicate(let result) = self else { return nil }
        return result
    }

    public var connectionRenameResult: DatabaseCommandResult<DatabaseConnectionRenameResult>? {
        guard case .connectionRename(let result) = self else { return nil }
        return result
    }

    public var connectionDeleteResult: DatabaseCommandResult<DatabaseConnectionDeleteResult>? {
        guard case .connectionDelete(let result) = self else { return nil }
        return result
    }

    public var capabilitiesResult: DatabaseCommandResult<DatabaseCapabilitiesResult>? {
        guard case .capabilities(let result) = self else { return nil }
        return result
    }

    public var browseResult: DatabaseCommandResult<DatabaseBrowseResult>? {
        guard case .browse(let result) = self else { return nil }
        return result
    }

    public var queryResult: DatabaseCommandResult<DatabaseQueryResult>? {
        guard case .query(let result) = self else { return nil }
        return result
    }

    public var mutationPreviewResult: DatabaseCommandResult<DatabaseMutationPreviewResult>? {
        guard case .mutationPreview(let result) = self else { return nil }
        return result
    }

    public var mutationApplyResult: DatabaseCommandResult<DatabaseMutationApplyResult>? {
        guard case .mutationApply(let result) = self else { return nil }
        return result
    }

    public var mutationStatusResult: DatabaseCommandResult<DatabaseMutationStatusResult>? {
        guard case .mutationStatus(let result) = self else { return nil }
        return result
    }

    public var mutationCancelResult: DatabaseCommandResult<DatabaseMutationCancelResult>? {
        guard case .mutationCancel(let result) = self else { return nil }
        return result
    }

    public var mutationOutcomeGetResult: DatabaseCommandResult<DatabaseMutationOutcomeGetResult>? {
        guard case .mutationOutcomeGet(let result) = self else { return nil }
        return result
    }

    public var savedQueryListResult: DatabaseCommandResult<DatabaseSavedQueryListResult>? {
        guard case .savedQueryList(let result) = self else { return nil }
        return result
    }

    public var savedQueryGetResult: DatabaseCommandResult<DatabaseSavedQueryGetResult>? {
        guard case .savedQueryGet(let result) = self else { return nil }
        return result
    }

    public var savedQuerySaveResult: DatabaseCommandResult<DatabaseSavedQuerySaveResult>? {
        guard case .savedQuerySave(let result) = self else { return nil }
        return result
    }

    public var savedQueryDuplicateResult: DatabaseCommandResult<DatabaseSavedQueryDuplicateResult>?
    {
        guard case .savedQueryDuplicate(let result) = self else { return nil }
        return result
    }

    public var savedQueryRenameResult: DatabaseCommandResult<DatabaseSavedQueryRenameResult>? {
        guard case .savedQueryRename(let result) = self else { return nil }
        return result
    }

    public var savedQueryDeleteResult: DatabaseCommandResult<DatabaseSavedQueryDeleteResult>? {
        guard case .savedQueryDelete(let result) = self else { return nil }
        return result
    }

    public var operationGetResult: DatabaseCommandResult<DatabaseOperationGetResult>? {
        guard case .operationGet(let result) = self else { return nil }
        return result
    }

    public var operationListResult: DatabaseCommandResult<DatabaseOperationListResult>? {
        guard case .operationList(let result) = self else { return nil }
        return result
    }

    public var operationCancelResult: DatabaseCommandResult<DatabaseOperationCancelResult>? {
        guard case .operationCancel(let result) = self else { return nil }
        return result
    }

    public func envelope(
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>,
        sequence: UInt64
    ) throws -> DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse> {
        try DatabaseBrokerCommandEnvelopeValidator.validate(request)
        guard kind == request.payload.kind else {
            throw DatabaseBrokerCommandContractError.commandMismatch(
                expected: request.payload.kind,
                actual: kind)
        }
        let envelope = DatabaseBrokerEnvelope(
            requestID: request.requestID,
            operationID: request.operationID,
            sequence: sequence,
            kind: .response,
            payload: self)
        try DatabaseBrokerCommandEnvelopeValidator.validate(
            envelope,
            matching: request)
        return envelope
    }
}

extension DatabaseBrokerCommandResponse: Codable {
    private enum CodingKeys: String, CodingKey {
        case version
        case command
        case result
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.schemaVersion else {
            throw DatabaseBrokerCommandContractError.unsupportedSchemaVersion(version)
        }
        let commandValue = try container.decode(String.self, forKey: .command)
        guard let command = DatabaseBrokerCommandKind(rawValue: commandValue) else {
            throw DatabaseBrokerCommandContractError.unknownCommand(commandValue)
        }
        switch command {
        case .connect:
            self = .connect(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectResult>.self,
                    forKey: .result))
        case .disconnect:
            self = .disconnect(
                try container.decode(
                    DatabaseCommandResult<DatabaseDisconnectResult>.self,
                    forKey: .result))
        case .connectionTest:
            self = .connectionTest(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionTestResult>.self,
                    forKey: .result))
        case .connectionList:
            self = .connectionList(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionListResult>.self,
                    forKey: .result))
        case .connectionGet:
            self = .connectionGet(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionGetResult>.self,
                    forKey: .result))
        case .connectionSave:
            self = .connectionSave(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionSaveResult>.self,
                    forKey: .result))
        case .connectionEdit:
            self = .connectionEdit(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionEditResult>.self,
                    forKey: .result))
        case .connectionDuplicate:
            self = .connectionDuplicate(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionDuplicateResult>.self,
                    forKey: .result))
        case .connectionRename:
            self = .connectionRename(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionRenameResult>.self,
                    forKey: .result))
        case .connectionDelete:
            self = .connectionDelete(
                try container.decode(
                    DatabaseCommandResult<DatabaseConnectionDeleteResult>.self,
                    forKey: .result))
        case .capabilities:
            self = .capabilities(
                try container.decode(
                    DatabaseCommandResult<DatabaseCapabilitiesResult>.self,
                    forKey: .result))
        case .browse:
            self = .browse(
                try container.decode(
                    DatabaseCommandResult<DatabaseBrowseResult>.self,
                    forKey: .result))
        case .query:
            self = .query(
                try container.decode(
                    DatabaseCommandResult<DatabaseQueryResult>.self,
                    forKey: .result))
        case .mutationPreview:
            self = .mutationPreview(
                try container.decode(
                    DatabaseCommandResult<DatabaseMutationPreviewResult>.self,
                    forKey: .result))
        case .mutationApply:
            self = .mutationApply(
                try container.decode(
                    DatabaseCommandResult<DatabaseMutationApplyResult>.self,
                    forKey: .result))
        case .mutationStatus:
            self = .mutationStatus(
                try container.decode(
                    DatabaseCommandResult<DatabaseMutationStatusResult>.self,
                    forKey: .result))
        case .mutationCancel:
            self = .mutationCancel(
                try container.decode(
                    DatabaseCommandResult<DatabaseMutationCancelResult>.self,
                    forKey: .result))
        case .mutationOutcomeGet:
            self = .mutationOutcomeGet(
                try container.decode(
                    DatabaseCommandResult<DatabaseMutationOutcomeGetResult>.self,
                    forKey: .result))
        case .savedQueryList:
            self = .savedQueryList(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQueryListResult>.self,
                    forKey: .result))
        case .savedQueryGet:
            self = .savedQueryGet(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQueryGetResult>.self,
                    forKey: .result))
        case .savedQuerySave:
            self = .savedQuerySave(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQuerySaveResult>.self,
                    forKey: .result))
        case .savedQueryDuplicate:
            self = .savedQueryDuplicate(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQueryDuplicateResult>.self,
                    forKey: .result))
        case .savedQueryRename:
            self = .savedQueryRename(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQueryRenameResult>.self,
                    forKey: .result))
        case .savedQueryDelete:
            self = .savedQueryDelete(
                try container.decode(
                    DatabaseCommandResult<DatabaseSavedQueryDeleteResult>.self,
                    forKey: .result))
        case .operationGet:
            self = .operationGet(
                try container.decode(
                    DatabaseCommandResult<DatabaseOperationGetResult>.self,
                    forKey: .result))
        case .operationList:
            self = .operationList(
                try container.decode(
                    DatabaseCommandResult<DatabaseOperationListResult>.self,
                    forKey: .result))
        case .operationCancel:
            self = .operationCancel(
                try container.decode(
                    DatabaseCommandResult<DatabaseOperationCancelResult>.self,
                    forKey: .result))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.schemaVersion, forKey: .version)
        try container.encode(kind.rawValue, forKey: .command)
        switch self {
        case .connect(let result):
            try container.encode(result, forKey: .result)
        case .disconnect(let result):
            try container.encode(result, forKey: .result)
        case .connectionTest(let result):
            try container.encode(result, forKey: .result)
        case .connectionList(let result):
            try container.encode(result, forKey: .result)
        case .connectionGet(let result):
            try container.encode(result, forKey: .result)
        case .connectionSave(let result):
            try container.encode(result, forKey: .result)
        case .connectionEdit(let result):
            try container.encode(result, forKey: .result)
        case .connectionDuplicate(let result):
            try container.encode(result, forKey: .result)
        case .connectionRename(let result):
            try container.encode(result, forKey: .result)
        case .connectionDelete(let result):
            try container.encode(result, forKey: .result)
        case .capabilities(let result):
            try container.encode(result, forKey: .result)
        case .browse(let result):
            try container.encode(result, forKey: .result)
        case .query(let result):
            try container.encode(result, forKey: .result)
        case .mutationPreview(let result):
            try container.encode(result, forKey: .result)
        case .mutationApply(let result):
            try container.encode(result, forKey: .result)
        case .mutationStatus(let result):
            try container.encode(result, forKey: .result)
        case .mutationCancel(let result):
            try container.encode(result, forKey: .result)
        case .mutationOutcomeGet(let result):
            try container.encode(result, forKey: .result)
        case .savedQueryList(let result):
            try container.encode(result, forKey: .result)
        case .savedQueryGet(let result):
            try container.encode(result, forKey: .result)
        case .savedQuerySave(let result):
            try container.encode(result, forKey: .result)
        case .savedQueryDuplicate(let result):
            try container.encode(result, forKey: .result)
        case .savedQueryRename(let result):
            try container.encode(result, forKey: .result)
        case .savedQueryDelete(let result):
            try container.encode(result, forKey: .result)
        case .operationGet(let result):
            try container.encode(result, forKey: .result)
        case .operationList(let result):
            try container.encode(result, forKey: .result)
        case .operationCancel(let result):
            try container.encode(result, forKey: .result)
        }
    }
}

public enum DatabaseBrokerCommandEnvelopeValidator {
    public static func validate(
        _ envelope: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>
    ) throws {
        guard envelope.kind == .request else {
            throw DatabaseBrokerCommandContractError.unexpectedEnvelopeKind(
                expected: .request,
                actual: envelope.kind)
        }
        try envelope.payload.validate()
        guard envelope.operationID == envelope.payload.operationID else {
            throw DatabaseBrokerCommandContractError.operationIDMismatch(
                expected: envelope.payload.operationID,
                actual: envelope.operationID)
        }
    }

    public static func validate(
        _ response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>
    ) throws {
        try validate(request)
        guard response.kind == .response else {
            throw DatabaseBrokerCommandContractError.unexpectedEnvelopeKind(
                expected: .response,
                actual: response.kind)
        }
        guard response.payload.kind == request.payload.kind else {
            throw DatabaseBrokerCommandContractError.commandMismatch(
                expected: request.payload.kind,
                actual: response.payload.kind)
        }
        guard response.requestID == request.requestID else {
            throw DatabaseBrokerCommandContractError.requestIDMismatch(
                expected: request.requestID,
                actual: response.requestID)
        }
        guard response.operationID == request.operationID else {
            throw DatabaseBrokerCommandContractError.operationIDMismatch(
                expected: request.operationID,
                actual: response.operationID)
        }
    }
}

public enum DatabaseBrokerCommandFrameCodec {
    public static func encode(
        _ request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>
    ) throws -> Data {
        try DatabaseBrokerCommandEnvelopeValidator.validate(request)
        return try encodeDeterministically(request, stream: .requests)
    }

    public static func encode(
        _ response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>,
        matching request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>
    ) throws -> Data {
        try DatabaseBrokerCommandEnvelopeValidator.validate(
            response,
            matching: request)
        return try encodeDeterministically(response, stream: .responses)
    }

    private static func encodeDeterministically<Payload: Codable & Sendable>(
        _ envelope: DatabaseBrokerEnvelope<Payload>,
        stream: DatabaseBrokerFrameStream
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload: Data
        do {
            payload = try encoder.encode(envelope)
        } catch {
            throw DatabaseBrokerProtocolError.encodingFailed
        }
        guard payload.count <= stream.maximumFrameBytes else {
            throw DatabaseBrokerProtocolError.frameTooLarge
        }
        let frame = frame(payload)
        var validator = DatabaseBrokerIncrementalDecoder<Payload>(stream: stream)
        _ = try validator.append(frame)
        try validator.finish()
        return frame
    }

    private static func frame(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        var frame = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        Swift.withUnsafeBytes(of: &length) { bytes in
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        return frame
    }
}

public struct DatabaseBrokerCommandRequestDecoder: Sendable {
    private var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerCommandRequest>(
        stream: .requests)

    public init() {}

    public var bufferedByteCount: Int {
        decoder.bufferedByteCount
    }

    public var maximumObservedBufferedByteCount: Int {
        decoder.maximumObservedBufferedByteCount
    }

    public mutating func append(
        _ chunk: Data
    ) throws -> [DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>] {
        let envelopes = try decoder.append(chunk)
        for envelope in envelopes {
            try DatabaseBrokerCommandEnvelopeValidator.validate(envelope)
        }
        return envelopes
    }

    public mutating func finish() throws {
        try decoder.finish()
    }

    public mutating func reset() {
        decoder.reset()
    }
}

public struct DatabaseBrokerCommandResponseDecoder: Sendable {
    private var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerCommandResponse>(
        stream: .responses)

    public init() {}

    public var bufferedByteCount: Int {
        decoder.bufferedByteCount
    }

    public var maximumObservedBufferedByteCount: Int {
        decoder.maximumObservedBufferedByteCount
    }

    public mutating func append(
        _ chunk: Data,
        matching requests: [UUID: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>]
    ) throws -> [DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>] {
        let envelopes = try decoder.append(chunk)
        for envelope in envelopes {
            guard let request = requests[envelope.requestID] else {
                throw DatabaseBrokerCommandContractError.missingRequest(
                    envelope.requestID)
            }
            try DatabaseBrokerCommandEnvelopeValidator.validate(
                envelope,
                matching: request)
        }
        return envelopes
    }

    public mutating func finish() throws {
        try decoder.finish()
    }

    public mutating func reset() {
        decoder.reset()
    }
}
