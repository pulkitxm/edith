import EdithDatabase
import Foundation
import Testing

private struct DatabaseBrokerTestPayload: Codable, Equatable, Sendable {
    let index: Int
    let value: String
}

private enum DatabaseBrokerProtocolFixtures {
    static let requestID = UUID(uuidString: "2D9B403A-74AA-4DD9-A1D4-C219B5E2D2B3")!
    static let operationID = DatabaseOperationID(
        rawValue: UUID(uuidString: "EC69DA47-42EA-4E64-B383-D97654B77BFD")!)

    static func envelope(
        sequence: UInt64 = 0,
        kind: DatabaseBrokerEnvelopeKind = .request,
        value: String = "value"
    ) -> DatabaseBrokerEnvelope<DatabaseBrokerTestPayload> {
        DatabaseBrokerEnvelope(
            requestID: requestID,
            operationID: operationID,
            sequence: sequence,
            kind: kind,
            payload: DatabaseBrokerTestPayload(
                index: Int(truncatingIfNeeded: sequence),
                value: value))
    }

    static func json(
        magic: String = DatabaseBrokerProtocol.magic,
        majorVersion: UInt16 = DatabaseBrokerProtocol.majorVersion,
        kind: DatabaseBrokerEnvelopeKind = .request,
        sequence: UInt64 = 0,
        payload: String = #"{"index":0,"value":"value"}"#
    ) -> Data {
        Data(
            """
            {"magic":"\(magic)","majorVersion":\(majorVersion),"requestID":"\(requestID.uuidString)","operationID":{"rawValue":"\(operationID.rawValue.uuidString)"},"sequence":\(sequence),"kind":"\(kind.rawValue)","payload":\(payload)}
            """.utf8)
    }

    static func frame(_ payload: Data, declaredLength: Int? = nil) -> Data {
        var length = UInt32(declaredLength ?? payload.count).bigEndian
        var frame = Data(capacity: MemoryLayout<UInt32>.size + payload.count)
        Swift.withUnsafeBytes(of: &length) { bytes in
            frame.append(contentsOf: bytes)
        }
        frame.append(payload)
        return frame
    }

    static func exactPayload(
        byteCount: Int,
        kind: DatabaseBrokerEnvelopeKind
    ) -> Data {
        var payload = json(kind: kind)
        payload.append(
            Data(
                repeating: UInt8(ascii: " "),
                count: byteCount - payload.count))
        return payload
    }

    static func capturedError(_ operation: () throws -> Void) -> DatabaseBrokerProtocolError? {
        do {
            try operation()
            return nil
        } catch let error as DatabaseBrokerProtocolError {
            return error
        } catch {
            Issue.record("Unexpected error type")
            return nil
        }
    }
}

@Suite struct DatabaseBrokerProtocolTests {
    @Test func fixedProtocolIdentityIsASCIIAndVersioned() {
        #expect(!DatabaseBrokerProtocol.magic.isEmpty)
        #expect(DatabaseBrokerProtocol.magic.utf8.allSatisfy { $0 < 0x80 })
        #expect(DatabaseBrokerProtocol.majorVersion == 1)
    }

    @Test func decodesAFrameByteByByte() throws {
        let envelope = DatabaseBrokerProtocolFixtures.envelope(sequence: 7)
        let frame = try DatabaseBrokerFrameCodec.encode(envelope, stream: .requests)
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        var decoded: [DatabaseBrokerEnvelope<DatabaseBrokerTestPayload>] = []

        for byte in frame {
            decoded.append(contentsOf: try decoder.append(Data([byte])))
        }

        #expect(decoded == [envelope])
        #expect(decoder.bufferedByteCount == 0)
        #expect(
            decoder.maximumObservedBufferedByteCount
                <= DatabaseBrokerProtocol.requestMaximumFrameBytes)
        try decoder.finish()
    }

    @Test func decodesMultipleCoalescedFramesInOrder() throws {
        let envelopes = (0..<64).map {
            DatabaseBrokerProtocolFixtures.envelope(sequence: UInt64($0))
        }
        var coalesced = Data()
        for envelope in envelopes {
            coalesced.append(
                try DatabaseBrokerFrameCodec.encode(envelope, stream: .requests))
        }
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)

        let decoded = try decoder.append(coalesced)

        #expect(decoded == envelopes)
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.maximumObservedBufferedByteCount < coalesced.count)
    }

    @Test func acceptsExactRequestAndResponseLimitsAndRejectsTheNextByte() throws {
        let cases: [(DatabaseBrokerFrameStream, DatabaseBrokerEnvelopeKind, Int)] = [
            (
                .requests,
                .request,
                DatabaseBrokerProtocol.requestMaximumFrameBytes
            ),
            (
                .responses,
                .response,
                DatabaseBrokerProtocol.responseMaximumFrameBytes
            ),
        ]

        for (stream, kind, maximum) in cases {
            let payload = DatabaseBrokerProtocolFixtures.exactPayload(
                byteCount: maximum,
                kind: kind)
            var exactDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
                stream: stream)
            let decoded = try exactDecoder.append(
                DatabaseBrokerProtocolFixtures.frame(payload))
            #expect(decoded.count == 1)
            #expect(exactDecoder.maximumObservedBufferedByteCount == maximum)

            var oversizedDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
                stream: stream)
            let error = DatabaseBrokerProtocolFixtures.capturedError {
                _ = try oversizedDecoder.append(
                    DatabaseBrokerProtocolFixtures.frame(
                        Data(),
                        declaredLength: maximum + 1))
            }
            #expect(error == .frameTooLarge)
            #expect(oversizedDecoder.bufferedByteCount == 0)
            #expect(oversizedDecoder.maximumObservedBufferedByteCount == 4)
        }
    }

    @Test func appliesIndependentRequestAndResponseLimits() throws {
        let byteCount = DatabaseBrokerProtocol.requestMaximumFrameBytes + 1
        let payload = DatabaseBrokerProtocolFixtures.exactPayload(
            byteCount: byteCount,
            kind: .response)
        let frame = DatabaseBrokerProtocolFixtures.frame(payload)
        var requestDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        var responseDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .responses)

        let requestError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try requestDecoder.append(frame)
        }
        let responses = try responseDecoder.append(frame)

        #expect(requestError == .frameTooLarge)
        #expect(responses.count == 1)
        #expect(responses.first?.kind == .response)
    }

    @Test func rejectsZeroLengthAndTruncatedFrames() throws {
        var zeroDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let zeroError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try zeroDecoder.append(
                DatabaseBrokerProtocolFixtures.frame(Data(), declaredLength: 0))
        }
        #expect(zeroError == .zeroLengthFrame)

        var headerDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        _ = try headerDecoder.append(Data([0, 0]))
        let truncatedHeaderError = DatabaseBrokerProtocolFixtures.capturedError {
            try headerDecoder.finish()
        }
        #expect(truncatedHeaderError == .truncatedFrame)
        #expect(headerDecoder.bufferedByteCount == 0)

        var payloadDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        _ = try payloadDecoder.append(
            DatabaseBrokerProtocolFixtures.frame(
                Data([1, 2, 3]),
                declaredLength: 10))
        let truncatedPayloadError = DatabaseBrokerProtocolFixtures.capturedError {
            try payloadDecoder.finish()
        }
        #expect(truncatedPayloadError == .truncatedFrame)
        #expect(payloadDecoder.bufferedByteCount == 0)
    }

    @Test func rejectsMalformedJSONAndInvalidUTF8() {
        var malformedDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let malformed = Data(#"{"magic":"EDITHDB""#.utf8)
        let malformedError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try malformedDecoder.append(
                DatabaseBrokerProtocolFixtures.frame(malformed))
        }
        #expect(malformedError == .malformedJSON)

        var invalidUTF8Decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let invalidUTF8Error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try invalidUTF8Decoder.append(
                DatabaseBrokerProtocolFixtures.frame(Data([0xFF])))
        }
        #expect(invalidUTF8Error == .invalidUTF8)
    }

    @Test func rejectsJSONBeyondDepthLimitBeforeDecoding() {
        let nesting = DatabaseBrokerProtocol.maximumJSONDepth
        let nestedPayload =
            String(repeating: "[", count: nesting) + "0"
            + String(repeating: "]", count: nesting)
        let payload = DatabaseBrokerProtocolFixtures.json(payload: nestedPayload)
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)

        let error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try decoder.append(DatabaseBrokerProtocolFixtures.frame(payload))
        }

        #expect(error == .jsonDepthLimitExceeded)
    }

    @Test func rejectsJSONBeyondNodeLimitBeforeDecoding() {
        let elements = String(
            repeating: "0,",
            count: DatabaseBrokerProtocol.requestMaximumJSONNodes + 1)
        let payload = DatabaseBrokerProtocolFixtures.json(
            payload: "[\(elements)0]")
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)

        let error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try decoder.append(DatabaseBrokerProtocolFixtures.frame(payload))
        }

        #expect(error == .jsonNodeLimitExceeded)
    }

    @Test func rejectsJSONBeyondStringLimitBeforeDecoding() {
        let value = String(
            repeating: "x",
            count: DatabaseBrokerProtocol.requestMaximumJSONStringBytes + 1)
        let payload = DatabaseBrokerProtocolFixtures.json(
            payload: #"{"index":0,"value":"\#(value)"}"#)
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)

        let error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try decoder.append(DatabaseBrokerProtocolFixtures.frame(payload))
        }

        #expect(error == .jsonStringLimitExceeded)
    }

    @Test func rejectsWrongMagicAndMajorVersion() {
        var magicDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let magicError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try magicDecoder.append(
                DatabaseBrokerProtocolFixtures.frame(
                    DatabaseBrokerProtocolFixtures.json(magic: "OTHER")))
        }
        #expect(magicError == .invalidMagic)

        var versionDecoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let versionError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try versionDecoder.append(
                DatabaseBrokerProtocolFixtures.frame(
                    DatabaseBrokerProtocolFixtures.json(majorVersion: 2)))
        }
        #expect(versionError == .unsupportedMajorVersion)
    }

    @Test func preservesMonotonicSequenceAndCorrelationIdentifiers() throws {
        let event = DatabaseBrokerProtocolFixtures.envelope(
            sequence: UInt64.max - 1,
            kind: .event)
        let response = DatabaseBrokerProtocolFixtures.envelope(
            sequence: UInt64.max,
            kind: .response)
        var frames = try DatabaseBrokerFrameCodec.encode(event, stream: .responses)
        frames.append(try DatabaseBrokerFrameCodec.encode(response, stream: .responses))
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .responses)

        let decoded = try decoder.append(frames)

        #expect(decoded.map(\.sequence) == [UInt64.max - 1, UInt64.max])
        #expect(decoded.allSatisfy { $0.requestID == DatabaseBrokerProtocolFixtures.requestID })
        #expect(decoded.allSatisfy { $0.operationID == DatabaseBrokerProtocolFixtures.operationID })
        #expect(decoded.map(\.kind) == [.event, .response])
    }

    @Test func enforcesEnvelopeKindsForEachStream() {
        let request = DatabaseBrokerProtocolFixtures.envelope(kind: .request)
        let response = DatabaseBrokerProtocolFixtures.envelope(kind: .response)

        let requestError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try DatabaseBrokerFrameCodec.encode(request, stream: .responses)
        }
        let responseError = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try DatabaseBrokerFrameCodec.encode(response, stream: .requests)
        }

        #expect(requestError == .unexpectedEnvelopeKind)
        #expect(responseError == .unexpectedEnvelopeKind)
    }

    @Test func automaticallyResetsAfterAnError() throws {
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)
        let error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try decoder.append(
                DatabaseBrokerProtocolFixtures.frame(Data(), declaredLength: 0))
        }
        #expect(error == .zeroLengthFrame)
        #expect(decoder.bufferedByteCount == 0)

        let envelope = DatabaseBrokerProtocolFixtures.envelope(sequence: 3)
        let decoded = try decoder.append(
            DatabaseBrokerFrameCodec.encode(envelope, stream: .requests))

        #expect(decoded == [envelope])
    }

    @Test func neverBuffersAnUnvalidatedOversizedChunk() {
        let maximum = DatabaseBrokerProtocol.requestMaximumFrameBytes
        var attack = DatabaseBrokerProtocolFixtures.frame(
            Data(),
            declaredLength: maximum + 1)
        attack.append(Data(repeating: 0x41, count: maximum * 2))
        var decoder = DatabaseBrokerIncrementalDecoder<DatabaseBrokerTestPayload>(
            stream: .requests)

        let error = DatabaseBrokerProtocolFixtures.capturedError {
            _ = try decoder.append(attack)
        }

        #expect(error == .frameTooLarge)
        #expect(decoder.bufferedByteCount == 0)
        #expect(decoder.maximumObservedBufferedByteCount == 4)
    }
}
