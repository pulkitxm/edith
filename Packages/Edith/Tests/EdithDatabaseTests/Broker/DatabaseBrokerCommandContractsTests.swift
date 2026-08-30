import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerCommandContractFixtures {
    static let requestID = UUID(uuidString: "D16E8863-A10B-485B-9B56-51D04C4B77F3")!
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "91CC07D1-3700-493E-9DA2-340502824275")!)
    static let otherOperationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "E850A6BE-4EE4-44A9-9F65-412CA67DC4F7")!)
    static let savedQueryID = DatabaseSavedQueryID(
        rawValue: UUID(uuidString: "A4E65471-F5C7-42DD-8114-9E58D8049DFE")!)
    static let secretReference = DatabaseSecretReference(
        identifier: UUID(uuidString: "DEABF1B2-F9F1-47E0-98D7-B3B900375436")!,
        purpose: .password)

    static let metadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))
    static let error = DatabaseErrorEnvelope(
        category: .unsupported,
        message: "fixture failure")
    static let managementKinds: Set<DatabaseBrokerCommandKind> = [
        .connectionList,
        .connectionGet,
        .connectionSave,
        .connectionEdit,
        .connectionDuplicate,
        .connectionRename,
        .connectionDelete,
        .savedQueryList,
        .savedQueryGet,
        .savedQuerySave,
        .savedQueryDuplicate,
        .savedQueryRename,
        .savedQueryDelete,
    ]

    static var operation: DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: operationID,
            deadline: Date(timeIntervalSince1970: 1_900_000_000))
    }

    static var savedQuery: DatabaseSavedQuery {
        DatabaseSavedQuery(
            id: savedQueryID,
            connectionID: DatabaseConnectionFixtures.connectionID,
            name: "Recent invoices",
            language: .sql,
            text: "SELECT * FROM invoices ORDER BY created_at DESC",
            tags: ["billing", "recent"],
            isFavorite: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_100))
    }

    static var mutation: DatabaseDestructiveRequest {
        DatabaseDestructiveRequest(
            target: DatabaseOperationFixtures.target,
            payload: .relational(
                product: .postgresql,
                statement: "UPDATE invoices SET state = $1 WHERE id = $2",
                parameters: [
                    DatabaseMutationParameter(
                        name: "state",
                        value: .string("paid")),
                    DatabaseMutationParameter(
                        name: "id",
                        value: .signedInteger(42)),
                ]))
    }

    static func requests() throws -> [DatabaseBrokerCommandRequest] {
        [
            .connect(
                DatabaseConnectRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    operation: operation)),
            .disconnect(
                DatabaseDisconnectRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    operation: operation)),
            .connectionTest(
                DatabaseConnectionTestRequest(
                    connection: try DatabaseConnectionFixtures.connectionDefinition(),
                    operation: operation)),
            .connectionList(
                DatabaseConnectionListRequest(
                    search: DatabaseConnectionSearch(
                        text: "orders",
                        products: [.postgresql],
                        favoritesOnly: true))),
            .connectionGet(
                DatabaseConnectionGetRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID)),
            .connectionSave(
                DatabaseConnectionSaveRequest(
                    connection: try DatabaseConnectionFixtures.connectionDefinition())),
            .connectionEdit(
                DatabaseConnectionEditRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    connection: try DatabaseConnectionFixtures.connectionDefinition())),
            .connectionDuplicate(
                DatabaseConnectionDuplicateRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    displayName: "Orders copy")),
            .connectionRename(
                DatabaseConnectionRenameRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    displayName: "Orders primary")),
            .connectionDelete(
                DatabaseConnectionDeleteRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID)),
            .capabilities(
                DatabaseCapabilitiesRequest(
                    connectionID: DatabaseConnectionFixtures.connectionID,
                    resolution: .refresh,
                    operation: operation)),
            .browse(
                DatabaseBrowseRequest(
                    target: DatabaseOperationFixtures.target,
                    page: DatabasePageRequest(
                        pageSize: try DatabasePageSize(50),
                        consistency: .snapshot),
                    operation: operation)),
            .query(
                DatabaseQueryRequest(
                    target: DatabaseOperationFixtures.target,
                    language: .sql,
                    command: "SELECT * FROM invoices WHERE id = $1",
                    parameters: [
                        DatabaseQueryParameter(
                            name: "id",
                            value: .signedInteger(42))
                    ],
                    operation: operation)),
            .mutationPreview(
                DatabaseMutationPreviewRequest(
                    mutation: mutation,
                    operation: operation)),
            .mutationApply(
                DatabaseMutationApplyRequest(
                    mutation: mutation,
                    token: DatabaseConfirmationToken(rawValue: "payload.signature"),
                    confirmationText: "Orders invoices",
                    operation: operation)),
            .savedQueryList(
                DatabaseSavedQueryListRequest(
                    search: DatabaseSavedQuerySearch(
                        connectionID: DatabaseConnectionFixtures.connectionID,
                        languages: [.sql],
                        favoritesOnly: true))),
            .savedQueryGet(
                DatabaseSavedQueryGetRequest(queryID: savedQueryID)),
            .savedQuerySave(
                DatabaseSavedQuerySaveRequest(query: savedQuery)),
            .savedQueryDuplicate(
                DatabaseSavedQueryDuplicateRequest(
                    queryID: savedQueryID,
                    name: "Recent invoices copy")),
            .savedQueryRename(
                DatabaseSavedQueryRenameRequest(
                    queryID: savedQueryID,
                    name: "Latest invoices")),
            .savedQueryDelete(
                DatabaseSavedQueryDeleteRequest(queryID: savedQueryID)),
            .operationGet(
                DatabaseOperationGetRequest(operationID: operationID)),
            .operationList(
                DatabaseOperationListRequest(
                    search: DatabaseOperationHistorySearch(
                        connectionID: DatabaseConnectionFixtures.connectionID,
                        states: [.running],
                        kinds: [.databaseQuery],
                        before: Date(timeIntervalSince1970: 1_900_000_100),
                        limit: 25))),
            .operationCancel(
                DatabaseOperationCancelRequest(operationID: operationID)),
        ]
    }

    static func response(
        for request: DatabaseBrokerCommandRequest
    ) throws -> DatabaseBrokerCommandResponse {
        switch request {
        case .connect:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseConnectResult>)
        case .disconnect:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseDisconnectResult>)
        case .connectionTest:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseConnectionTestResult>)
        case .connectionList:
            try request.response(
                .success(
                    DatabaseConnectionListResult(
                        connections: [try DatabaseConnectionFixtures.connectionDefinition()]),
                    metadata: metadata))
        case .connectionGet:
            try request.response(
                .success(
                    DatabaseConnectionGetResult(
                        connection: try DatabaseConnectionFixtures.connectionDefinition()),
                    metadata: metadata))
        case .connectionSave:
            try request.response(
                .success(
                    DatabaseConnectionSaveResult(
                        connection: try DatabaseConnectionFixtures.connectionDefinition()),
                    metadata: metadata))
        case .connectionEdit:
            try request.response(
                .success(
                    DatabaseConnectionEditResult(
                        connection: try DatabaseConnectionFixtures.connectionDefinition()),
                    metadata: metadata))
        case .connectionDuplicate:
            try request.response(
                .success(
                    DatabaseConnectionDuplicateResult(
                        sourceConnectionID: DatabaseConnectionFixtures.connectionID,
                        connection: try DatabaseConnectionFixtures.connectionDefinition(),
                        sharesCredentials: true,
                        sharedCredentialReferences: [secretReference]),
                    metadata: metadata))
        case .connectionRename:
            try request.response(
                .success(
                    DatabaseConnectionRenameResult(
                        connection: try DatabaseConnectionFixtures.connectionDefinition()),
                    metadata: metadata))
        case .connectionDelete:
            try request.response(
                .success(
                    DatabaseConnectionDeleteResult(
                        connectionID: DatabaseConnectionFixtures.connectionID,
                        deleted: true,
                        disconnected: true),
                    metadata: metadata))
        case .capabilities:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseCapabilitiesResult>)
        case .browse:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseBrowseResult>)
        case .query:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseQueryResult>)
        case .mutationPreview:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseMutationPreviewResult>)
        case .mutationApply:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseMutationApplyResult>)
        case .savedQueryList:
            try request.response(
                .success(
                    DatabaseSavedQueryListResult(queries: [savedQuery]),
                    metadata: metadata))
        case .savedQueryGet:
            try request.response(
                .success(
                    DatabaseSavedQueryGetResult(query: savedQuery),
                    metadata: metadata))
        case .savedQuerySave:
            try request.response(
                .success(
                    DatabaseSavedQuerySaveResult(query: savedQuery, created: true),
                    metadata: metadata))
        case .savedQueryDuplicate:
            try request.response(
                .success(
                    DatabaseSavedQueryDuplicateResult(
                        sourceQueryID: savedQueryID,
                        query: savedQuery),
                    metadata: metadata))
        case .savedQueryRename:
            try request.response(
                .success(
                    DatabaseSavedQueryRenameResult(query: savedQuery),
                    metadata: metadata))
        case .savedQueryDelete:
            try request.response(
                .success(
                    DatabaseSavedQueryDeleteResult(
                        queryID: savedQueryID,
                        deleted: true),
                    metadata: metadata))
        case .operationGet:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseOperationGetResult>)
        case .operationList:
            try request.response(
                failure() as DatabaseCommandResult<DatabaseOperationListResult>)
        case .operationCancel(let cancelRequest):
            try request.response(
                .success(
                    DatabaseOperationCancelResult(
                        operationID: cancelRequest.operationID,
                        disposition: .accepted,
                        cancellationSupport: .serverSide),
                    metadata: metadata))
        }
    }

    static func exchanges() throws -> [(
        request: DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>,
        response: DatabaseBrokerEnvelope<DatabaseBrokerCommandResponse>
    )] {
        try requests().enumerated().map { index, request in
            let requestEnvelope = request.envelope(
                requestID: requestIdentifier(index),
                sequence: UInt64(index * 2))
            return (
                requestEnvelope,
                try response(for: request).envelope(
                    matching: requestEnvelope,
                    sequence: UInt64(index * 2 + 1))
            )
        }
    }

    static func requestIdentifier(_ index: Int) -> UUID {
        let suffix = String(format: "%012d", index + 1)
        return UUID(uuidString: "00000000-0000-4000-8000-\(suffix)")!
    }

    static func failure<Payload: Sendable>() -> DatabaseCommandResult<Payload> {
        .failure(error, metadata: metadata)
    }

    static func frame(
        _ payload: Data,
        declaredLength: Int? = nil
    ) -> Data {
        var length = UInt32(declaredLength ?? payload.count).bigEndian
        var frame = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        Swift.withUnsafeBytes(of: &length) { bytes in
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        return frame
    }

    static func payload(from frame: Data) -> Data {
        Data(frame.dropFirst(MemoryLayout<UInt32>.size))
    }

    static func padded(_ payload: Data, byteCount: Int) -> Data {
        var padded = payload
        padded.append(
            Data(
                repeating: UInt8(ascii: " "),
                count: byteCount - payload.count))
        return padded
    }

    static func replacing(
        _ value: String,
        with replacement: String,
        in framedData: Data
    ) -> Data {
        let payload = payload(from: framedData)
        let text = String(decoding: payload, as: UTF8.self)
        return frame(Data(text.replacingOccurrences(of: value, with: replacement).utf8))
    }

    static func addingTopLevelField(
        name: String,
        value: String,
        to framedData: Data
    ) -> Data {
        var text = String(decoding: payload(from: framedData), as: UTF8.self)
        text.removeLast()
        text += ",\"\(name)\":\(value)}"
        return frame(Data(text.utf8))
    }

    static func protocolError(
        _ operation: () throws -> Void
    ) -> DatabaseBrokerProtocolError? {
        do {
            try operation()
            return nil
        } catch let error as DatabaseBrokerProtocolError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }

    static func contractError(
        _ operation: () throws -> Void
    ) -> DatabaseBrokerCommandContractError? {
        do {
            try operation()
            return nil
        } catch let error as DatabaseBrokerCommandContractError {
            return error
        } catch {
            Issue.record("unexpected error type: \(error)")
            return nil
        }
    }
}

@Suite(.serialized)
struct DatabaseBrokerCommandContractsTests {
    @Test func everyRequestRoundTripsWithItsStableDiscriminator() throws {
        let requests = try DatabaseBrokerCommandContractFixtures.requests()

        for (index, request) in requests.enumerated() {
            let envelope = request.envelope(
                requestID: DatabaseBrokerCommandContractFixtures.requestIdentifier(index),
                sequence: UInt64(index))
            let frame = try DatabaseBrokerCommandFrameCodec.encode(envelope)
            var decoder = DatabaseBrokerCommandRequestDecoder()

            let decoded = try decoder.append(frame)

            #expect(decoded == [envelope])
            #expect(decoded.first?.payload.kind == request.kind)
            #expect(decoded.first?.operationID == request.operationID)
            try decoder.finish()
        }
        #expect(requests.map(\.kind) == DatabaseBrokerCommandKind.allCases)
    }

    @Test func managementDiscriminatorsAreStableAndCarryNoOperationIdentity() throws {
        let requests = try DatabaseBrokerCommandContractFixtures.requests().filter {
            DatabaseBrokerCommandContractFixtures.managementKinds.contains($0.kind)
        }

        #expect(
            requests.map { $0.kind.rawValue }
                == [
                    "database.connection.list",
                    "database.connection.get",
                    "database.connection.save",
                    "database.connection.edit",
                    "database.connection.duplicate",
                    "database.connection.rename",
                    "database.connection.delete",
                    "database.saved-query.list",
                    "database.saved-query.get",
                    "database.saved-query.save",
                    "database.saved-query.duplicate",
                    "database.saved-query.rename",
                    "database.saved-query.delete",
                ])
        for (index, request) in requests.enumerated() {
            let envelope = request.envelope(
                requestID: DatabaseBrokerCommandContractFixtures.requestIdentifier(index),
                sequence: UInt64(index))
            #expect(request.operationID == nil)
            #expect(envelope.operationID == nil)
            try DatabaseBrokerCommandEnvelopeValidator.validate(envelope)
        }
    }

    @Test func everyResponseRoundTripsAgainstItsMatchingRequest() throws {
        let exchanges = try DatabaseBrokerCommandContractFixtures.exchanges()
        let requests = Dictionary(
            uniqueKeysWithValues: exchanges.map { ($0.request.requestID, $0.request) })

        for exchange in exchanges {
            let frame = try DatabaseBrokerCommandFrameCodec.encode(
                exchange.response,
                matching: exchange.request)
            var decoder = DatabaseBrokerCommandResponseDecoder()

            let decoded = try decoder.append(frame, matching: requests)

            #expect(decoded == [exchange.response])
            #expect(decoded.first?.payload.kind == exchange.request.payload.kind)
            try decoder.finish()
        }
    }

    @Test func typedAccessorsExposeOnlyTheMatchingPayload() throws {
        let requests = try DatabaseBrokerCommandContractFixtures.requests()
        let responses = try requests.map(DatabaseBrokerCommandContractFixtures.response)

        #expect(requests[0].connectRequest != nil)
        #expect(requests[0].disconnectRequest == nil)
        #expect(requests[1].disconnectRequest != nil)
        #expect(requests[2].connectionTestRequest != nil)
        #expect(requests[3].connectionListRequest != nil)
        #expect(requests[4].connectionGetRequest != nil)
        #expect(requests[5].connectionSaveRequest != nil)
        #expect(requests[6].connectionEditRequest != nil)
        #expect(requests[7].connectionDuplicateRequest != nil)
        #expect(requests[8].connectionRenameRequest != nil)
        #expect(requests[9].connectionDeleteRequest != nil)
        #expect(requests[10].capabilitiesRequest != nil)
        #expect(requests[11].browseRequest != nil)
        #expect(requests[12].queryRequest != nil)
        #expect(requests[13].mutationPreviewRequest != nil)
        #expect(requests[14].mutationApplyRequest != nil)
        #expect(requests[15].savedQueryListRequest != nil)
        #expect(requests[16].savedQueryGetRequest != nil)
        #expect(requests[17].savedQuerySaveRequest != nil)
        #expect(requests[18].savedQueryDuplicateRequest != nil)
        #expect(requests[19].savedQueryRenameRequest != nil)
        #expect(requests[20].savedQueryDeleteRequest != nil)
        #expect(requests[21].operationGetRequest != nil)
        #expect(requests[22].operationListRequest != nil)
        #expect(requests[23].operationCancelRequest != nil)
        #expect(responses[0].connectResult != nil)
        #expect(responses[0].disconnectResult == nil)
        #expect(responses[1].disconnectResult != nil)
        #expect(responses[2].connectionTestResult != nil)
        #expect(responses[3].connectionListResult != nil)
        #expect(responses[4].connectionGetResult != nil)
        #expect(responses[5].connectionSaveResult != nil)
        #expect(responses[6].connectionEditResult != nil)
        #expect(responses[7].connectionDuplicateResult != nil)
        #expect(responses[8].connectionRenameResult != nil)
        #expect(responses[9].connectionDeleteResult != nil)
        #expect(responses[10].capabilitiesResult != nil)
        #expect(responses[11].browseResult != nil)
        #expect(responses[12].queryResult != nil)
        #expect(responses[13].mutationPreviewResult != nil)
        #expect(responses[14].mutationApplyResult != nil)
        #expect(responses[15].savedQueryListResult != nil)
        #expect(responses[16].savedQueryGetResult != nil)
        #expect(responses[17].savedQuerySaveResult != nil)
        #expect(responses[18].savedQueryDuplicateResult != nil)
        #expect(responses[19].savedQueryRenameResult != nil)
        #expect(responses[20].savedQueryDeleteResult != nil)
        #expect(responses[21].operationGetResult != nil)
        #expect(responses[22].operationListResult != nil)
        #expect(responses[23].operationCancelResult != nil)
    }

    @Test func responseFactoriesAndEnvelopesRejectCommandMismatches() throws {
        let request = try #require(
            DatabaseBrokerCommandContractFixtures.requests().first)
        let disconnectResult =
            DatabaseBrokerCommandContractFixtures.failure()
            as DatabaseCommandResult<DatabaseDisconnectResult>

        let factoryError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try request.response(disconnectResult)
        }

        #expect(
            factoryError
                == .commandMismatch(
                    expected: .connect,
                    actual: .disconnect))

        let requestEnvelope = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 0)
        let mismatchedResponse = DatabaseBrokerEnvelope(
            requestID: requestEnvelope.requestID,
            operationID: requestEnvelope.operationID,
            sequence: 1,
            kind: .response,
            payload: DatabaseBrokerCommandResponse.disconnect(disconnectResult))

        let envelopeError = DatabaseBrokerCommandContractFixtures.contractError {
            try DatabaseBrokerCommandEnvelopeValidator.validate(
                mismatchedResponse,
                matching: requestEnvelope)
        }

        #expect(
            envelopeError
                == .commandMismatch(
                    expected: .connect,
                    actual: .disconnect))

        let managementRequest = try #require(
            DatabaseBrokerCommandContractFixtures.requests().first {
                $0.kind == .connectionList
            })
        let savedQueryResult =
            DatabaseBrokerCommandContractFixtures.failure()
            as DatabaseCommandResult<DatabaseSavedQueryListResult>
        let managementError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try managementRequest.response(savedQueryResult)
        }

        #expect(
            managementError
                == .commandMismatch(
                    expected: .connectionList,
                    actual: .savedQueryList))
    }

    @Test func boundedResponseDecoderRejectsMismatchedAndUnknownRequests() throws {
        let requests = try DatabaseBrokerCommandContractFixtures.requests()
        let connect = requests[0].envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 0)
        let disconnectResult =
            DatabaseBrokerCommandContractFixtures.failure()
            as DatabaseCommandResult<DatabaseDisconnectResult>
        let mismatched = DatabaseBrokerEnvelope(
            requestID: connect.requestID,
            operationID: connect.operationID,
            sequence: 1,
            kind: .response,
            payload: DatabaseBrokerCommandResponse.disconnect(disconnectResult))
        let mismatchedFrame = try DatabaseBrokerFrameCodec.encode(
            mismatched,
            stream: .responses)
        var mismatchDecoder = DatabaseBrokerCommandResponseDecoder()

        let mismatchError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try mismatchDecoder.append(
                mismatchedFrame,
                matching: [connect.requestID: connect])
        }

        #expect(
            mismatchError
                == .commandMismatch(
                    expected: .connect,
                    actual: .disconnect))

        let response = try DatabaseBrokerCommandContractFixtures.response(for: requests[0])
            .envelope(matching: connect, sequence: 1)
        let responseFrame = try DatabaseBrokerCommandFrameCodec.encode(
            response,
            matching: connect)
        var missingDecoder = DatabaseBrokerCommandResponseDecoder()

        let missingError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try missingDecoder.append(responseFrame, matching: [:])
        }

        #expect(missingError == .missingRequest(connect.requestID))
    }

    @Test func envelopeKindsAreStrictlyRequestAndResponse() throws {
        let exchange = try #require(
            DatabaseBrokerCommandContractFixtures.exchanges().first)
        let wrongRequest = DatabaseBrokerEnvelope(
            requestID: exchange.request.requestID,
            operationID: exchange.request.operationID,
            sequence: exchange.request.sequence,
            kind: .response,
            payload: exchange.request.payload)

        let requestError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try DatabaseBrokerCommandFrameCodec.encode(wrongRequest)
        }

        #expect(
            requestError
                == .unexpectedEnvelopeKind(
                    expected: .request,
                    actual: .response))

        let wrongResponse = DatabaseBrokerEnvelope(
            requestID: exchange.response.requestID,
            operationID: exchange.response.operationID,
            sequence: exchange.response.sequence,
            kind: .event,
            payload: exchange.response.payload)
        let eventFrame = try DatabaseBrokerFrameCodec.encode(
            wrongResponse,
            stream: .responses)
        var responseDecoder = DatabaseBrokerCommandResponseDecoder()

        let responseError = DatabaseBrokerCommandContractFixtures.contractError {
            _ = try responseDecoder.append(
                eventFrame,
                matching: [exchange.request.requestID: exchange.request])
        }

        #expect(
            responseError
                == .unexpectedEnvelopeKind(
                    expected: .response,
                    actual: .event))

        let wrongStreamFrame = try DatabaseBrokerFrameCodec.encode(
            wrongRequest,
            stream: .responses)
        var requestDecoder = DatabaseBrokerCommandRequestDecoder()
        let streamError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try requestDecoder.append(wrongStreamFrame)
        }
        #expect(streamError == .unexpectedEnvelopeKind)
    }

    @Test func rejectsUnknownMalformedAndUnsupportedDiscriminators() throws {
        let operationID = DatabaseBrokerCommandContractFixtures.operationID.rawValue.uuidString
        let unknown = Data(
            """
            {"version":1,"command":"database.future.command","request":{"version":1,"operationID":{"rawValue":"\(operationID)"}}}
            """.utf8)
        let malformed = Data(
            """
            {"version":1,"command":7,"request":{"version":1,"operationID":{"rawValue":"\(operationID)"}}}
            """.utf8)
        let unsupported = Data(
            """
            {"version":2,"command":"database.operation.get","request":{"version":1,"operationID":{"rawValue":"\(operationID)"}}}
            """.utf8)
        let unsupportedRequest = Data(
            """
            {"version":1,"command":"database.operation.get","request":{"version":2,"operationID":{"rawValue":"\(operationID)"}}}
            """.utf8)
        let unsupportedManagementRequest = Data(
            """
            {"version":1,"command":"database.connection.list","request":{"version":2,"search":{"environments":[],"favoritesOnly":false,"limit":100,"offset":0,"order":"recentlyUsed","products":[],"tags":[]}}}
            """.utf8)

        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self,
                    from: unknown)
            } == .unknownCommand("database.future.command"))
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                DatabaseBrokerCommandRequest.self,
                from: malformed)
        }
        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self,
                    from: unsupported)
            } == .unsupportedSchemaVersion(2))
        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self,
                    from: unsupportedRequest)
            }
                == .unsupportedRequestVersion(
                    command: .operationGet,
                    version: 2))
        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandRequest.self,
                    from: unsupportedManagementRequest)
            }
                == .unsupportedRequestVersion(
                    command: .connectionList,
                    version: 2))

        let unknownResponse = Data(
            """
            {"version":1,"command":"database.future.command","result":{}}
            """.utf8)
        let unsupportedResponse = Data(
            """
            {"version":2,"command":"database.operation.get","result":{}}
            """.utf8)
        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandResponse.self,
                    from: unknownResponse)
            } == .unknownCommand("database.future.command"))
        #expect(
            DatabaseBrokerCommandContractFixtures.contractError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerCommandResponse.self,
                    from: unsupportedResponse)
            } == .unsupportedSchemaVersion(2))
    }

    @Test func framedUnknownCommandsFailClosedThroughBoundedDecoding() throws {
        let request = DatabaseBrokerCommandRequest.operationGet(
            DatabaseOperationGetRequest(
                operationID: DatabaseBrokerCommandContractFixtures.operationID))
        let envelope = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 0)
        let frame = try DatabaseBrokerCommandFrameCodec.encode(envelope)
        let unknownFrame = DatabaseBrokerCommandContractFixtures.replacing(
            DatabaseBrokerCommandKind.operationGet.rawValue,
            with: "database.operation.future",
            in: frame)
        var decoder = DatabaseBrokerCommandRequestDecoder()

        let error = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try decoder.append(unknownFrame)
        }

        #expect(error == .malformedJSON)
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test func identitiesAndSequenceSurviveTheCompleteExchange() throws {
        let request = DatabaseBrokerCommandRequest.operationCancel(
            DatabaseOperationCancelRequest(
                operationID: DatabaseBrokerCommandContractFixtures.operationID))
        let requestEnvelope = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: UInt64.max - 1)
        let requestFrame = try DatabaseBrokerCommandFrameCodec.encode(requestEnvelope)
        var requestDecoder = DatabaseBrokerCommandRequestDecoder()
        let decodedRequest = try #require(requestDecoder.append(requestFrame).first)
        let result = DatabaseOperationCancelResult(
            operationID: DatabaseBrokerCommandContractFixtures.operationID,
            disposition: .accepted,
            cancellationSupport: .serverSide)
        let response = try decodedRequest.payload.response(
            .success(
                result,
                metadata: DatabaseBrokerCommandContractFixtures.metadata))
        let responseEnvelope = try response.envelope(
            matching: decodedRequest,
            sequence: UInt64.max)
        let responseFrame = try DatabaseBrokerCommandFrameCodec.encode(
            responseEnvelope,
            matching: decodedRequest)
        var responseDecoder = DatabaseBrokerCommandResponseDecoder()
        let decodedResponse = try #require(
            responseDecoder.append(
                responseFrame,
                matching: [decodedRequest.requestID: decodedRequest]
            ).first)

        #expect(decodedRequest.requestID == DatabaseBrokerCommandContractFixtures.requestID)
        #expect(decodedRequest.operationID == DatabaseBrokerCommandContractFixtures.operationID)
        #expect(decodedRequest.sequence == UInt64.max - 1)
        #expect(decodedResponse.requestID == decodedRequest.requestID)
        #expect(decodedResponse.operationID == decodedRequest.operationID)
        #expect(decodedResponse.sequence == UInt64.max)
        #expect(
            decodedResponse.payload.operationCancelResult?.payload?.operationID
                == result.operationID)
    }

    @Test func rejectsEnvelopeIdentitySubstitution() throws {
        let request = DatabaseBrokerCommandRequest.operationGet(
            DatabaseOperationGetRequest(
                operationID: DatabaseBrokerCommandContractFixtures.operationID))
        let invalidRequest = DatabaseBrokerEnvelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            operationID: DatabaseBrokerCommandContractFixtures.otherOperationID,
            sequence: 0,
            kind: .request,
            payload: request)

        let requestError = DatabaseBrokerCommandContractFixtures.contractError {
            try DatabaseBrokerCommandEnvelopeValidator.validate(invalidRequest)
        }

        #expect(
            requestError
                == .operationIDMismatch(
                    expected: DatabaseBrokerCommandContractFixtures.operationID,
                    actual: DatabaseBrokerCommandContractFixtures.otherOperationID))

        let validRequest = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 0)
        let responsePayload = try DatabaseBrokerCommandContractFixtures.response(for: request)
        let substitutedResponse = DatabaseBrokerEnvelope(
            requestID: UUID(uuidString: "AA394A9D-1E31-4A63-9C0B-36C81FE98412")!,
            operationID: validRequest.operationID,
            sequence: 1,
            kind: .response,
            payload: responsePayload)

        let responseError = DatabaseBrokerCommandContractFixtures.contractError {
            try DatabaseBrokerCommandEnvelopeValidator.validate(
                substitutedResponse,
                matching: validRequest)
        }

        #expect(
            responseError
                == .requestIDMismatch(
                    expected: validRequest.requestID,
                    actual: substitutedResponse.requestID))
    }

    @Test func decodesByteChunksAndCoalescedExchangesInOrder() throws {
        let exchanges = try DatabaseBrokerCommandContractFixtures.exchanges()
        var requestFrames = Data()
        var responseFrames = Data()
        for exchange in exchanges {
            requestFrames.append(
                try DatabaseBrokerCommandFrameCodec.encode(exchange.request))
            responseFrames.append(
                try DatabaseBrokerCommandFrameCodec.encode(
                    exchange.response,
                    matching: exchange.request))
        }
        var requestDecoder = DatabaseBrokerCommandRequestDecoder()
        var decodedRequests: [DatabaseBrokerEnvelope<DatabaseBrokerCommandRequest>] = []
        for byte in requestFrames {
            decodedRequests.append(
                contentsOf: try requestDecoder.append(Data([byte])))
        }
        let expectedRequests = exchanges.map(\.request)
        #expect(decodedRequests == expectedRequests)
        #expect(requestDecoder.bufferedByteCount == 0)

        let requestMap = Dictionary(
            uniqueKeysWithValues: expectedRequests.map { ($0.requestID, $0) })
        var responseDecoder = DatabaseBrokerCommandResponseDecoder()
        let decodedResponses = try responseDecoder.append(
            responseFrames,
            matching: requestMap)

        #expect(decodedResponses == exchanges.map(\.response))
        #expect(responseDecoder.bufferedByteCount == 0)
        #expect(responseDecoder.maximumObservedBufferedByteCount < responseFrames.count)
    }

    @Test func exactFrameLimitsAreAcceptedAndNextByteIsRejected() throws {
        let exchange = try #require(
            DatabaseBrokerCommandContractFixtures.exchanges().first)
        let requestFrame = try DatabaseBrokerCommandFrameCodec.encode(exchange.request)
        let exactRequestPayload = DatabaseBrokerCommandContractFixtures.padded(
            DatabaseBrokerCommandContractFixtures.payload(from: requestFrame),
            byteCount: DatabaseBrokerProtocol.requestMaximumFrameBytes)
        var requestDecoder = DatabaseBrokerCommandRequestDecoder()
        let decodedRequests = try requestDecoder.append(
            DatabaseBrokerCommandContractFixtures.frame(exactRequestPayload))

        #expect(decodedRequests == [exchange.request])
        #expect(
            requestDecoder.maximumObservedBufferedByteCount
                == DatabaseBrokerProtocol.requestMaximumFrameBytes)

        var oversizedRequestDecoder = DatabaseBrokerCommandRequestDecoder()
        let requestError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try oversizedRequestDecoder.append(
                DatabaseBrokerCommandContractFixtures.frame(
                    Data(),
                    declaredLength: DatabaseBrokerProtocol.requestMaximumFrameBytes + 1))
        }
        #expect(requestError == .frameTooLarge)

        let responseFrame = try DatabaseBrokerCommandFrameCodec.encode(
            exchange.response,
            matching: exchange.request)
        let exactResponsePayload = DatabaseBrokerCommandContractFixtures.padded(
            DatabaseBrokerCommandContractFixtures.payload(from: responseFrame),
            byteCount: DatabaseBrokerProtocol.responseMaximumFrameBytes)
        var responseDecoder = DatabaseBrokerCommandResponseDecoder()
        let decodedResponses = try responseDecoder.append(
            DatabaseBrokerCommandContractFixtures.frame(exactResponsePayload),
            matching: [exchange.request.requestID: exchange.request])

        #expect(decodedResponses == [exchange.response])
        #expect(
            responseDecoder.maximumObservedBufferedByteCount
                == DatabaseBrokerProtocol.responseMaximumFrameBytes)

        var oversizedResponseDecoder = DatabaseBrokerCommandResponseDecoder()
        let responseError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try oversizedResponseDecoder.append(
                DatabaseBrokerCommandContractFixtures.frame(
                    Data(),
                    declaredLength: DatabaseBrokerProtocol.responseMaximumFrameBytes + 1),
                matching: [exchange.request.requestID: exchange.request])
        }
        #expect(responseError == .frameTooLarge)
    }

    @Test func commandPayloadsRemainInsideJSONDepthNodeAndStringBudgets() throws {
        let request = DatabaseBrokerCommandRequest.operationList(
            DatabaseOperationListRequest())
        let envelope = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 0)
        let frame = try DatabaseBrokerCommandFrameCodec.encode(envelope)
        let exactDepthValue =
            String(
                repeating: "[",
                count: DatabaseBrokerProtocol.maximumJSONDepth - 1)
            + "0"
            + String(
                repeating: "]",
                count: DatabaseBrokerProtocol.maximumJSONDepth - 1)
        let exactDepthFrame = DatabaseBrokerCommandContractFixtures.addingTopLevelField(
            name: "padding",
            value: exactDepthValue,
            to: frame)
        var exactDepthDecoder = DatabaseBrokerCommandRequestDecoder()
        #expect(try exactDepthDecoder.append(exactDepthFrame) == [envelope])

        let excessiveDepthValue = "[" + exactDepthValue + "]"
        let excessiveDepthFrame = DatabaseBrokerCommandContractFixtures.addingTopLevelField(
            name: "padding",
            value: excessiveDepthValue,
            to: frame)
        var excessiveDepthDecoder = DatabaseBrokerCommandRequestDecoder()
        let depthError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try excessiveDepthDecoder.append(excessiveDepthFrame)
        }
        #expect(depthError == .jsonDepthLimitExceeded)

        let excessiveNodes =
            "["
            + String(
                repeating: "0,",
                count: DatabaseBrokerProtocol.requestMaximumJSONNodes + 1)
            + "0]"
        let excessiveNodeFrame = DatabaseBrokerCommandContractFixtures.addingTopLevelField(
            name: "padding",
            value: excessiveNodes,
            to: frame)
        var nodeDecoder = DatabaseBrokerCommandRequestDecoder()
        let nodeError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try nodeDecoder.append(excessiveNodeFrame)
        }
        #expect(nodeError == .jsonNodeLimitExceeded)

        let exactString =
            "\""
            + String(
                repeating: "x",
                count: DatabaseBrokerProtocol.requestMaximumJSONStringBytes)
            + "\""
        let exactStringFrame = DatabaseBrokerCommandContractFixtures.addingTopLevelField(
            name: "padding",
            value: exactString,
            to: frame)
        var exactStringDecoder = DatabaseBrokerCommandRequestDecoder()
        #expect(try exactStringDecoder.append(exactStringFrame) == [envelope])

        let excessiveString =
            "\""
            + String(
                repeating: "x",
                count: DatabaseBrokerProtocol.requestMaximumJSONStringBytes + 1)
            + "\""
        let excessiveStringFrame = DatabaseBrokerCommandContractFixtures.addingTopLevelField(
            name: "padding",
            value: excessiveString,
            to: frame)
        var stringDecoder = DatabaseBrokerCommandRequestDecoder()
        let stringError = DatabaseBrokerCommandContractFixtures.protocolError {
            _ = try stringDecoder.append(excessiveStringFrame)
        }
        #expect(stringError == .jsonStringLimitExceeded)
    }

    @Test func encodingShapeAndBytesAreDeterministic() throws {
        let request = DatabaseBrokerCommandRequest.operationGet(
            DatabaseOperationGetRequest(
                operationID: DatabaseBrokerCommandContractFixtures.operationID))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(request)
        let operationID = DatabaseBrokerCommandContractFixtures.operationID.rawValue.uuidString

        #expect(
            String(decoding: encoded, as: UTF8.self)
                == "{\"command\":\"database.operation.get\",\"request\":{\"operationID\":{\"rawValue\":\"\(operationID)\"},\"version\":1},\"version\":1}"
        )

        let envelope = request.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 7)
        let first = try DatabaseBrokerCommandFrameCodec.encode(envelope)
        for _ in 0..<32 {
            #expect(try DatabaseBrokerCommandFrameCodec.encode(envelope) == first)
        }

        let managementRequest = DatabaseBrokerCommandRequest.connectionGet(
            DatabaseConnectionGetRequest(
                connectionID: DatabaseConnectionFixtures.connectionID))
        let managementEncoded = try encoder.encode(managementRequest)
        let connectionID = DatabaseConnectionFixtures.connectionID.rawValue.uuidString

        #expect(
            String(decoding: managementEncoded, as: UTF8.self)
                == "{\"command\":\"database.connection.get\",\"request\":{\"connectionID\":{\"rawValue\":\"\(connectionID)\"},\"version\":1},\"version\":1}"
        )
        let managementEnvelope = managementRequest.envelope(
            requestID: DatabaseBrokerCommandContractFixtures.requestID,
            sequence: 8)
        let managementFrame = try DatabaseBrokerCommandFrameCodec.encode(managementEnvelope)
        for _ in 0..<32 {
            #expect(
                try DatabaseBrokerCommandFrameCodec.encode(managementEnvelope)
                    == managementFrame)
        }
    }

    @Test func connectionCommandsCarryReferencesWithoutRawSecrets() throws {
        let requests = try DatabaseBrokerCommandContractFixtures.requests().filter {
            $0.kind == .connectionTest
                || $0.kind.rawValue.hasPrefix("database.connection.")
        }
        let responses = try requests.map(DatabaseBrokerCommandContractFixtures.response)
        let encodedRequests = try requests.map { try JSONEncoder().encode($0) }
        let encodedResponses = try responses.map { try JSONEncoder().encode($0) }
        let text = String(
            decoding: (encodedRequests + encodedResponses).flatMap { $0 },
            as: UTF8.self)

        #expect(text.contains("secretReferences"))
        #expect(text.contains("clientPrivateKey"))
        #expect(
            text.contains(
                DatabaseBrokerCommandContractFixtures.secretReference.identifier.uuidString))
        #expect(!text.contains("rawSecret"))
        #expect(!text.contains("passwordValue"))
        #expect(!text.contains("privateKeyValue"))
        #expect(!text.contains("super-secret"))
    }
}
