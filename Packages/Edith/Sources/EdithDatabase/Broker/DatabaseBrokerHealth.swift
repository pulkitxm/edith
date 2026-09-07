import Foundation

struct DatabaseBrokerHealthRequest: Codable, Equatable, Sendable {
    init() {}

    init(from decoder: Decoder) throws {
        try DatabaseBrokerHealthPayloadCoding.validateFields(
            in: decoder,
            expected: ["type"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == DatabaseBrokerHealthPayloadCoding.type else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unexpected broker health request type")
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(DatabaseBrokerHealthPayloadCoding.type, forKey: .type)
    }

    private enum CodingKeys: String, CodingKey {
        case type
    }
}

struct DatabaseBrokerHealthResponse: Codable, Equatable, Sendable {
    let brokerInstanceID: UUID
    let isReady: Bool

    init(
        brokerInstanceID: UUID = UUID(),
        isReady: Bool
    ) {
        self.brokerInstanceID = brokerInstanceID
        self.isReady = isReady
    }

    init(from decoder: Decoder) throws {
        try DatabaseBrokerHealthPayloadCoding.validateFields(
            in: decoder,
            expected: ["type", "brokerInstanceID", "ready"])
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        guard type == DatabaseBrokerHealthPayloadCoding.type else {
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unexpected broker health response type")
        }
        brokerInstanceID = try container.decode(UUID.self, forKey: .brokerInstanceID)
        isReady = try container.decode(Bool.self, forKey: .ready)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(DatabaseBrokerHealthPayloadCoding.type, forKey: .type)
        try container.encode(brokerInstanceID, forKey: .brokerInstanceID)
        try container.encode(isReady, forKey: .ready)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case brokerInstanceID
        case ready
    }
}

enum DatabaseBrokerHealthValidationError: Error, Equatable, Sendable {
    case unexpectedRequestEnvelopeKind
    case unexpectedResponseEnvelopeKind
    case operationIDNotAllowed
    case invalidSequence
    case requestIDMismatch
    case missingTerminalResponse
    case multipleTerminalResponses
}

enum DatabaseBrokerHealthRequestValidator {
    static func validate(
        _ envelope: DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest>
    ) throws(DatabaseBrokerHealthValidationError) {
        guard envelope.kind == .request else {
            throw .unexpectedRequestEnvelopeKind
        }
        guard envelope.operationID == nil else {
            throw .operationIDNotAllowed
        }
        guard envelope.sequence == 0 else {
            throw .invalidSequence
        }
    }
}

struct DatabaseBrokerHealthResponseValidator: Sendable {
    let requestID: UUID
    private(set) var receivedTerminalResponse = false

    init(
        request: DatabaseBrokerEnvelope<DatabaseBrokerHealthRequest>
    ) throws(DatabaseBrokerHealthValidationError) {
        try DatabaseBrokerHealthRequestValidator.validate(request)
        requestID = request.requestID
    }

    mutating func validate(
        _ envelope: DatabaseBrokerEnvelope<DatabaseBrokerHealthResponse>
    ) throws(DatabaseBrokerHealthValidationError) {
        guard envelope.kind == .response else {
            throw .unexpectedResponseEnvelopeKind
        }
        guard envelope.operationID == nil else {
            throw .operationIDNotAllowed
        }
        guard envelope.sequence == 0 else {
            throw .invalidSequence
        }
        guard envelope.requestID == requestID else {
            throw .requestIDMismatch
        }
        guard !receivedTerminalResponse else {
            throw .multipleTerminalResponses
        }
        receivedTerminalResponse = true
    }

    func finish() throws(DatabaseBrokerHealthValidationError) {
        guard receivedTerminalResponse else {
            throw .missingTerminalResponse
        }
    }
}

private enum DatabaseBrokerHealthPayloadCoding {
    static let type = "health"

    static func validateFields(
        in decoder: Decoder,
        expected: Set<String>
    ) throws {
        let container = try decoder.container(keyedBy: DatabaseBrokerHealthAnyCodingKey.self)
        let actual = Set(container.allKeys.map(\.stringValue))
        guard actual == expected else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unexpected broker health payload fields"))
        }
    }
}

private struct DatabaseBrokerHealthAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}
