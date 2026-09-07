@testable import EdithDatabase
import Foundation
import Testing

private enum DatabaseBrokerHealthFixtures {
    static let requestID = UUID(uuidString: "76388466-B375-456B-B225-3BAC03648D55")!
    static let otherRequestID = UUID(uuidString: "9C215DC2-1952-4FD0-AFFF-B4D76B9F5311")!
    static let brokerInstanceID = UUID(uuidString: "936F1848-8E39-42B4-B1BE-DF9B6CC49720")!
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "CA3D4F5E-5841-4410-BF84-058AA78FBA91")!)

    static func request(
        requestID: UUID = requestID,
        operationID: DatabaseOperationID? = nil,
        sequence: UInt64 = 0,
        kind: DatabaseBrokerEnvelopeKind = .request
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            operationID: operationID,
            sequence: sequence,
            kind: kind,
            payload: DatabaseBrokerHealthRequest())
    }

    static func response(
        requestID: UUID = requestID,
        operationID: DatabaseOperationID? = nil,
        sequence: UInt64 = 0,
        kind: DatabaseBrokerEnvelopeKind = .response,
        isReady: Bool = true
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerHealthResponse> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            operationID: operationID,
            sequence: sequence,
            kind: kind,
            payload: DatabaseBrokerHealthResponse(
                brokerInstanceID: brokerInstanceID,
                isReady: isReady))
    }

    static func capturedValidationError(
        _ operation: () throws -> Void
    ) -> DatabaseBrokerHealthValidationError? {
        do {
            try operation()
            return nil
        } catch let error as DatabaseBrokerHealthValidationError {
            return error
        } catch {
            Issue.record("Unexpected error type")
            return nil
        }
    }

    static func capturedDecodingError(
        _ operation: () throws -> Void
    ) -> DecodingError? {
        do {
            try operation()
            return nil
        } catch let error as DecodingError {
            return error
        } catch {
            Issue.record("Unexpected error type")
            return nil
        }
    }
}

@Suite struct DatabaseBrokerHealthTests {
    @Test func roundTripsTaggedRequestThroughBoundedRequestFraming() throws {
        let request = DatabaseBrokerHealthFixtures.request()
        let frame = try DatabaseBrokerFrameCodec.encode(request, stream: .requests)
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerHealthRequest>(
            stream: .requests)
        var decoded: [DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest>] = []

        for byte in frame {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(decoded == [request])
        #expect(frame.count <= DatabaseBrokerProtocol.requestMaximumFrameBytes + 4)
        try decoder.finish()

        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(request.payload)) as? [String: Any])
        #expect(Set(object.keys) == ["type"])
        #expect(object["type"] as? String == "health")
    }

    @Test func roundTripsTaggedReadinessThroughBoundedResponseFraming() throws {
        for isReady in [false, true] {
            let response = DatabaseBrokerHealthFixtures.response(isReady: isReady)
            let frame = try DatabaseBrokerFrameCodec.encode(response, stream: .responses)
            var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerHealthResponse>(
                stream: .responses)

            let decoded = try decoder.append(frame)

            #expect(decoded == [response])
            #expect(decoded.first?.payload.isReady == isReady)
            #expect(frame.count <= DatabaseBrokerProtocol.responseMaximumFrameBytes + 4)
            try decoder.finish()
        }
    }

    @Test func createsRandomBrokerInstanceIdentifiersByDefault() {
        let first = DatabaseBrokerHealthResponse(isReady: true)
        let second = DatabaseBrokerHealthResponse(isReady: true)

        #expect(first.brokerInstanceID != second.brokerInstanceID)
    }

    @Test func responseWireShapeContainsOnlyHealthReadinessFields() throws {
        let response = DatabaseBrokerHealthResponse(
            brokerInstanceID: DatabaseBrokerHealthFixtures.brokerInstanceID,
            isReady: true)
        let data = try JSONEncoder().encode(response)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(Set(object.keys) == ["type", "brokerInstanceID", "ready"])
        #expect(object["type"] as? String == "health")
        #expect(object["brokerInstanceID"] as? String == "936F1848-8E39-42B4-B1BE-DF9B6CC49720")
        #expect(object["ready"] as? Bool == true)
    }

    @Test func rejectsWrongTagsMissingFieldsAndAdditionalFields() {
        let invalidPayloads = [
            #"{"type":"status"}"#,
            #"{}"#,
            #"{"type":"health","secret":"value"}"#,
            #"{"type":"health","brokerInstanceID":"936F1848-8E39-42B4-B1BE-DF9B6CC49720","ready":true,"runtimeOwner":"owner"}"#,
            #"{"type":"health","brokerInstanceID":"936F1848-8E39-42B4-B1BE-DF9B6CC49720","ready":true,"codeHash":"hash"}"#,
        ]

        for payload in invalidPayloads {
            let requestError = DatabaseBrokerHealthFixtures.capturedDecodingError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerHealthRequest.self,
                    from: Data(payload.utf8))
            }
            let responseError = DatabaseBrokerHealthFixtures.capturedDecodingError {
                _ = try JSONDecoder().decode(
                    DatabaseBrokerHealthResponse.self,
                    from: Data(payload.utf8))
            }

            #expect(requestError != nil)
            #expect(responseError != nil)
        }
    }

    @Test func validatesCanonicalRequestEnvelope() throws {
        try DatabaseBrokerHealthRequestValidator.validate(
            DatabaseBrokerHealthFixtures.request())
    }

    @Test func rejectsInvalidRequestEnvelopeMetadata() {
        let cases:
            [(
                DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest>,
                DatabaseBrokerHealthValidationError
            )] = [
                (
                    DatabaseBrokerHealthFixtures.request(kind: .response),
                    .unexpectedRequestEnvelopeKind
                ),
                (
                    DatabaseBrokerHealthFixtures.request(
                        operationID: DatabaseBrokerHealthFixtures.operationID),
                    .operationIDNotAllowed
                ),
                (
                    DatabaseBrokerHealthFixtures.request(sequence: 1),
                    .invalidSequence
                ),
            ]

        for (request, expected) in cases {
            let error = DatabaseBrokerHealthFixtures.capturedValidationError {
                try DatabaseBrokerHealthRequestValidator.validate(request)
            }

            #expect(error == expected)
        }
    }

    @Test func acceptsExactlyOneMatchingTerminalResponse() throws {
        let request = DatabaseBrokerHealthFixtures.request()
        var validator = try DatabaseBrokerHealthResponseValidator(request: request)

        try validator.validate(DatabaseBrokerHealthFixtures.response())
        try validator.finish()

        #expect(validator.receivedTerminalResponse)
        let error = DatabaseBrokerHealthFixtures.capturedValidationError {
            try validator.validate(DatabaseBrokerHealthFixtures.response())
        }
        #expect(error == .multipleTerminalResponses)
    }

    @Test func rejectsInvalidResponseEnvelopeMetadataWithoutConsumingTerminal() throws {
        let cases:
            [(
                DatabaseBrokerEnvelope<DatabaseBrokerHealthResponse>,
                DatabaseBrokerHealthValidationError
            )] = [
                (
                    DatabaseBrokerHealthFixtures.response(kind: .event),
                    .unexpectedResponseEnvelopeKind
                ),
                (
                    DatabaseBrokerHealthFixtures.response(kind: .failure),
                    .unexpectedResponseEnvelopeKind
                ),
                (
                    DatabaseBrokerHealthFixtures.response(
                        operationID: DatabaseBrokerHealthFixtures.operationID),
                    .operationIDNotAllowed
                ),
                (
                    DatabaseBrokerHealthFixtures.response(sequence: 1),
                    .invalidSequence
                ),
                (
                    DatabaseBrokerHealthFixtures.response(
                        requestID: DatabaseBrokerHealthFixtures.otherRequestID),
                    .requestIDMismatch
                ),
            ]

        for (response, expected) in cases {
            var validator = try DatabaseBrokerHealthResponseValidator(
                request: DatabaseBrokerHealthFixtures.request())
            let error = DatabaseBrokerHealthFixtures.capturedValidationError {
                try validator.validate(response)
            }

            #expect(error == expected)
            #expect(!validator.receivedTerminalResponse)
            try validator.validate(DatabaseBrokerHealthFixtures.response())
            try validator.finish()
        }
    }

    @Test func requiresATerminalResponse() throws {
        let validator = try DatabaseBrokerHealthResponseValidator(
            request: DatabaseBrokerHealthFixtures.request())

        let error = DatabaseBrokerHealthFixtures.capturedValidationError {
            try validator.finish()
        }

        #expect(error == .missingTerminalResponse)
    }

    @Test func refusesToTrackAnInvalidRequest() {
        let error = DatabaseBrokerHealthFixtures.capturedValidationError {
            _ = try DatabaseBrokerHealthResponseValidator(
                request: DatabaseBrokerHealthFixtures.request(sequence: 1))
        }

        #expect(error == .invalidSequence)
    }
}
