import CoreFoundation
import Foundation

public enum DatabaseBrokerProtocol {
    public static let magic = "EDITHDB"
    public static let majorVersion: UInt16 = 1
    public static let requestMaximumFrameBytes = 4 * 1_024 * 1_024
    public static let responseMaximumFrameBytes = 32 * 1_024 * 1_024
    public static let maximumJSONDepth = 64
    public static let requestMaximumJSONNodes = 20_000
    public static let responseMaximumJSONNodes = 1_100_000
    public static let requestMaximumJSONStringBytes = 1_024 * 1_024
    public static let responseMaximumJSONStringBytes = 16 * 1_024 * 1_024
}

public enum DatabaseBrokerEnvelopeKind: String, CaseIterable, Codable, Hashable, Sendable {
    case request
    case event
    case response
    case failure
}

public struct DatabaseBrokerEnvelope<Payload: Codable & Sendable>: Codable, Sendable {
    public let magic: String
    public let majorVersion: UInt16
    public let requestID: UUID
    public let operationID: DatabaseOperationID?
    public let sequence: UInt64
    public let kind: DatabaseBrokerEnvelopeKind
    public let payload: Payload

    public init(
        requestID: UUID,
        operationID: DatabaseOperationID? = nil,
        sequence: UInt64,
        kind: DatabaseBrokerEnvelopeKind,
        payload: Payload
    ) {
        magic = DatabaseBrokerProtocol.magic
        majorVersion = DatabaseBrokerProtocol.majorVersion
        self.requestID = requestID
        self.operationID = operationID
        self.sequence = sequence
        self.kind = kind
        self.payload = payload
    }
}

extension DatabaseBrokerEnvelope: Equatable where Payload: Equatable {}
extension DatabaseBrokerEnvelope: Hashable where Payload: Hashable {}

public enum DatabaseBrokerFrameStream: Sendable {
    case requests
    case responses

    public var maximumFrameBytes: Int {
        switch self {
        case .requests:
            DatabaseBrokerProtocol.requestMaximumFrameBytes
        case .responses:
            DatabaseBrokerProtocol.responseMaximumFrameBytes
        }
    }

    fileprivate var maximumJSONNodes: Int {
        switch self {
        case .requests:
            DatabaseBrokerProtocol.requestMaximumJSONNodes
        case .responses:
            DatabaseBrokerProtocol.responseMaximumJSONNodes
        }
    }

    fileprivate var maximumJSONStringBytes: Int {
        switch self {
        case .requests:
            DatabaseBrokerProtocol.requestMaximumJSONStringBytes
        case .responses:
            DatabaseBrokerProtocol.responseMaximumJSONStringBytes
        }
    }

    fileprivate func accepts(_ kind: DatabaseBrokerEnvelopeKind) -> Bool {
        switch self {
        case .requests:
            kind == .request
        case .responses:
            kind != .request
        }
    }
}

public enum DatabaseBrokerProtocolError: Error, Equatable, Sendable {
    case zeroLengthFrame
    case frameTooLarge
    case truncatedFrame
    case invalidUTF8
    case malformedJSON
    case jsonDepthLimitExceeded
    case jsonNodeLimitExceeded
    case jsonStringLimitExceeded
    case invalidMagic
    case unsupportedMajorVersion
    case unexpectedEnvelopeKind
    case encodingFailed
}

public enum DatabaseBrokerFrameCodec {
    public static func encode<Payload: Codable & Sendable>(
        _ envelope: DatabaseBrokerEnvelope<Payload>,
        stream: DatabaseBrokerFrameStream
    ) throws(DatabaseBrokerProtocolError) -> Data {
        guard envelope.magic == DatabaseBrokerProtocol.magic else {
            throw .invalidMagic
        }
        guard envelope.majorVersion == DatabaseBrokerProtocol.majorVersion else {
            throw .unsupportedMajorVersion
        }
        guard stream.accepts(envelope.kind) else {
            throw .unexpectedEnvelopeKind
        }
        let payload: Data
        do {
            payload = try JSONEncoder().encode(envelope)
        } catch {
            throw .encodingFailed
        }
        guard payload.count <= stream.maximumFrameBytes else {
            throw .frameTooLarge
        }
        try DatabaseBrokerJSONValidator.validate(payload, stream: stream)
        return frame(payload)
    }

    fileprivate static func decode<Payload: Codable & Sendable>(
        _ payload: Data,
        stream: DatabaseBrokerFrameStream,
        as _: Payload.Type
    ) throws(DatabaseBrokerProtocolError) -> DatabaseBrokerEnvelope<Payload> {
        try DatabaseBrokerJSONValidator.validate(payload, stream: stream)
        let envelope: DatabaseBrokerEnvelope<Payload>
        do {
            envelope = try JSONDecoder().decode(DatabaseBrokerEnvelope<Payload>.self, from: payload)
        } catch {
            throw .malformedJSON
        }
        guard envelope.magic == DatabaseBrokerProtocol.magic else {
            throw .invalidMagic
        }
        guard envelope.majorVersion == DatabaseBrokerProtocol.majorVersion else {
            throw .unsupportedMajorVersion
        }
        guard stream.accepts(envelope.kind) else {
            throw .unexpectedEnvelopeKind
        }
        return envelope
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

public struct DatabaseBrokerIncrementalDecoder<Payload: Codable & Sendable>: Sendable {
    public let stream: DatabaseBrokerFrameStream
    public private(set) var maximumObservedBufferedByteCount = 0

    private var header: [UInt8] = []
    private var expectedPayloadByteCount: Int?
    private var payload = Data()

    public init(stream: DatabaseBrokerFrameStream) {
        self.stream = stream
        header.reserveCapacity(MemoryLayout<UInt32>.size)
    }

    public var bufferedByteCount: Int {
        header.count + payload.count
    }

    public mutating func append(
        _ chunk: Data
    ) throws(DatabaseBrokerProtocolError) -> [DatabaseBrokerEnvelope<Payload>] {
        do {
            return try appendFrames(chunk)
        } catch {
            resetFrameState()
            throw error
        }
    }

    public mutating func finish() throws(DatabaseBrokerProtocolError) {
        guard header.isEmpty, expectedPayloadByteCount == nil else {
            resetFrameState()
            throw .truncatedFrame
        }
    }

    public mutating func reset() {
        resetFrameState()
        maximumObservedBufferedByteCount = 0
    }

    private mutating func appendFrames(
        _ chunk: Data
    ) throws(DatabaseBrokerProtocolError) -> [DatabaseBrokerEnvelope<Payload>] {
        var envelopes: [DatabaseBrokerEnvelope<Payload>] = []
        var index = chunk.startIndex
        while index < chunk.endIndex {
            if expectedPayloadByteCount == nil {
                while header.count < MemoryLayout<UInt32>.size, index < chunk.endIndex {
                    header.append(chunk[index])
                    chunk.formIndex(after: &index)
                    recordBufferedByteCount()
                }
                guard header.count == MemoryLayout<UInt32>.size else {
                    break
                }
                let declaredLength = header.reduce(UInt32(0)) {
                    ($0 << 8) | UInt32($1)
                }
                header.removeAll(keepingCapacity: true)
                guard declaredLength != 0 else {
                    throw .zeroLengthFrame
                }
                guard declaredLength <= UInt32(stream.maximumFrameBytes) else {
                    throw .frameTooLarge
                }
                expectedPayloadByteCount = Int(declaredLength)
                payload.reserveCapacity(Int(declaredLength))
            }

            guard let expectedPayloadByteCount else {
                continue
            }
            let neededByteCount = expectedPayloadByteCount - payload.count
            let availableByteCount = chunk.distance(from: index, to: chunk.endIndex)
            let copiedByteCount = min(neededByteCount, availableByteCount)
            let copyEnd = chunk.index(index, offsetBy: copiedByteCount)
            payload.append(chunk[index..<copyEnd])
            index = copyEnd
            recordBufferedByteCount()

            guard payload.count == expectedPayloadByteCount else {
                continue
            }
            let completePayload = payload
            payload = Data()
            self.expectedPayloadByteCount = nil
            let envelope = try DatabaseBrokerFrameCodec.decode(
                completePayload,
                stream: stream,
                as: Payload.self)
            envelopes.append(envelope)
        }
        return envelopes
    }

    private mutating func recordBufferedByteCount() {
        maximumObservedBufferedByteCount = max(
            maximumObservedBufferedByteCount,
            bufferedByteCount)
    }

    private mutating func resetFrameState() {
        header.removeAll(keepingCapacity: true)
        expectedPayloadByteCount = nil
        payload = Data()
    }
}

private enum DatabaseBrokerJSONValidator {
    static func validate(
        _ data: Data,
        stream: DatabaseBrokerFrameStream
    ) throws(DatabaseBrokerProtocolError) {
        guard String(data: data, encoding: .utf8) != nil else {
            throw .invalidUTF8
        }
        do {
            try data.withUnsafeBytes { rawBytes in
                var scanner = DatabaseBrokerJSONScanner(
                    bytes: rawBytes.bindMemory(to: UInt8.self),
                    maximumDepth: DatabaseBrokerProtocol.maximumJSONDepth,
                    maximumNodes: stream.maximumJSONNodes,
                    maximumStringBytes: stream.maximumJSONStringBytes)
                try scanner.validate()
            }
        } catch let error as DatabaseBrokerProtocolError {
            throw error
        } catch {
            throw .malformedJSON
        }

        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw .malformedJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw .malformedJSON
        }
        guard let magic = dictionary["magic"] as? String else {
            throw .malformedJSON
        }
        guard magic == DatabaseBrokerProtocol.magic else {
            throw .invalidMagic
        }
        guard let version = dictionary["majorVersion"] as? NSNumber else {
            throw .malformedJSON
        }
        guard CFGetTypeID(version) != CFBooleanGetTypeID() else {
            throw .malformedJSON
        }
        let numericVersion = version.doubleValue
        guard
            numericVersion.isFinite,
            numericVersion.rounded(.towardZero) == numericVersion,
            numericVersion >= 0,
            numericVersion <= Double(UInt16.max)
        else {
            throw .malformedJSON
        }
        guard UInt16(numericVersion) == DatabaseBrokerProtocol.majorVersion else {
            throw .unsupportedMajorVersion
        }
    }
}

private struct DatabaseBrokerJSONScanner {
    let bytes: UnsafeBufferPointer<UInt8>
    let maximumDepth: Int
    let maximumNodes: Int
    let maximumStringBytes: Int

    private var index = 0
    private var depth = 0
    private var nodes = 0
    private var sawToken = false

    init(
        bytes: UnsafeBufferPointer<UInt8>,
        maximumDepth: Int,
        maximumNodes: Int,
        maximumStringBytes: Int
    ) {
        self.bytes = bytes
        self.maximumDepth = maximumDepth
        self.maximumNodes = maximumNodes
        self.maximumStringBytes = maximumStringBytes
    }

    mutating func validate() throws(DatabaseBrokerProtocolError) {
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                try recordNode()
                sawToken = true
                depth += 1
                guard depth <= maximumDepth else {
                    throw .jsonDepthLimitExceeded
                }
                index += 1
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                depth -= 1
                guard depth >= 0 else {
                    throw .malformedJSON
                }
                index += 1
            case UInt8(ascii: "\""):
                try recordNode()
                sawToken = true
                try scanString()
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "t"),
                UInt8(ascii: "f"), UInt8(ascii: "n"):
                try recordNode()
                sawToken = true
                scanScalar()
            case UInt8(ascii: ":"), UInt8(ascii: ","):
                index += 1
            case UInt8(ascii: " "), UInt8(ascii: "\n"), UInt8(ascii: "\r"), UInt8(ascii: "\t"):
                index += 1
            default:
                throw .malformedJSON
            }
        }
        guard sawToken, depth == 0 else {
            throw .malformedJSON
        }
    }

    private mutating func recordNode() throws(DatabaseBrokerProtocolError) {
        nodes += 1
        guard nodes <= maximumNodes else {
            throw .jsonNodeLimitExceeded
        }
    }

    private mutating func scanString() throws(DatabaseBrokerProtocolError) {
        index += 1
        var stringBytes = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                return
            }
            guard byte >= 0x20 else {
                throw .malformedJSON
            }
            if byte == UInt8(ascii: "\\") {
                try addStringBytes(2, to: &stringBytes)
                index += 1
                guard index < bytes.count else {
                    throw .malformedJSON
                }
                let escaped = bytes[index]
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"),
                    UInt8(ascii: "b"), UInt8(ascii: "f"), UInt8(ascii: "n"),
                    UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    guard index + 4 < bytes.count else {
                        throw .malformedJSON
                    }
                    for hexadecimalIndex in (index + 1)...(index + 4) {
                        guard isHexadecimal(bytes[hexadecimalIndex]) else {
                            throw .malformedJSON
                        }
                    }
                    try addStringBytes(4, to: &stringBytes)
                    index += 5
                default:
                    throw .malformedJSON
                }
            } else {
                try addStringBytes(1, to: &stringBytes)
                index += 1
            }
        }
        throw .malformedJSON
    }

    private mutating func addStringBytes(
        _ count: Int,
        to stringBytes: inout Int
    ) throws(DatabaseBrokerProtocolError) {
        stringBytes += count
        guard stringBytes <= maximumStringBytes else {
            throw .jsonStringLimitExceeded
        }
    }

    private mutating func scanScalar() {
        repeat {
            index += 1
        } while index < bytes.count && !isScalarDelimiter(bytes[index])
    }

    private func isScalarDelimiter(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
            UInt8(ascii: ":"), UInt8(ascii: ","), UInt8(ascii: " "), UInt8(ascii: "\n"),
            UInt8(ascii: "\r"), UInt8(ascii: "\t"):
            true
        default:
            false
        }
    }

    private func isHexadecimal(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "a")...UInt8(ascii: "f"),
            UInt8(ascii: "A")...UInt8(ascii: "F"):
            true
        default:
            false
        }
    }
}
