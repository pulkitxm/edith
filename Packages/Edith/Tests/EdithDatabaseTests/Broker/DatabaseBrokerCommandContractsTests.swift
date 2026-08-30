import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerCommandContractFixtures {
    static let requestID = UUID(uuidString: "D16E8863-A10B-485B-9B56-51D04C4B77F3")!
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "91CC07D1-3700-493E-9DA2-340502824275")!)
    static let otherOperationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "E850A6BE-4EE4-44A9-9F65-412CA67DC4F7")!)

    static let metadata = DatabaseResultMetadata(
        completeness: DatabaseResultCompleteness(state: .complete))
    static let error = DatabaseErrorEnvelope(
        category: .unsupported,
        message: "fixture failure")

    static var operation: DatabaseOperationContext {
        DatabaseOperationContext(
            operationID: operationID,
            deadline: Date(timeIntervalSince1970: 1_900_000_000))
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
        #expect(requests[3].capabilitiesRequest != nil)
        #expect(requests[4].browseRequest != nil)
        #expect(requests[5].queryRequest != nil)
        #expect(requests[6].mutationPreviewRequest != nil)
        #expect(requests[7].mutationApplyRequest != nil)
        #expect(requests[8].operationGetRequest != nil)
        #expect(requests[9].operationListRequest != nil)
        #expect(requests[10].operationCancelRequest != nil)
        #expect(responses[0].connectResult != nil)
        #expect(responses[0].disconnectResult == nil)
        #expect(responses[1].disconnectResult != nil)
        #expect(responses[2].connectionTestResult != nil)
        #expect(responses[3].capabilitiesResult != nil)
        #expect(responses[4].browseResult != nil)
        #expect(responses[5].queryResult != nil)
        #expect(responses[6].mutationPreviewResult != nil)
        #expect(responses[7].mutationApplyResult != nil)
        #expect(responses[8].operationGetResult != nil)
        #expect(responses[9].operationListResult != nil)
        #expect(responses[10].operationCancelResult != nil)
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
    }

    @Test func connectionTestCarriesReferencesWithoutRawSecrets() throws {
        let request = try #require(
            DatabaseBrokerCommandContractFixtures.requests().first {
                $0.kind == .connectionTest
            })
        let encoded = try JSONEncoder().encode(request)
        let text = String(decoding: encoded, as: UTF8.self)

        #expect(text.contains("secretReferences"))
        #expect(text.contains("clientPrivateKey"))
        #expect(!text.contains("rawSecret"))
        #expect(!text.contains("passwordValue"))
        #expect(!text.contains("privateKeyValue"))
    }
}
