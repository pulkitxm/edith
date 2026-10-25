import Foundation

public enum ExtensionEngineError: Error, Equatable, Sendable {
    case unavailable, rejected, timedOut
    case failed(String)
}

extension ExtensionEngineError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable: "The extension is not available."
        case .rejected: "The extension rejected the request."
        case .timedOut: "The extension did not answer in time."
        case .failed(let message): message
        }
    }
}

public struct ExtensionEngineRequest: Codable, Sendable {
    public let token: UUID
    public let presentationID: UUID
    public let operation: String
    public let payload: Data
    public let timeout: Double

    public init(
        token: UUID = UUID(), presentationID: UUID, operation: String,
        payload: Data = Data("{}".utf8), timeout: Double = 30
    ) {
        self.token = token
        self.presentationID = presentationID
        self.operation = operation
        self.payload = payload
        self.timeout = timeout
    }

    public func validate() throws {
        guard timeout.isFinite, timeout > 0, timeout <= 600,
            !operation.isEmpty, operation.utf8.count <= 128,
            operation.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0)
                    || (97...122).contains($0) || [45, 46, 95].contains($0)
            }), !operation.hasPrefix("extension."),
            payload.count <= ExtensionEngineWire.maximumPayloadBytes,
            (try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)) != nil
        else { throw ExtensionEngineError.rejected }
    }
}

public struct ExtensionEngineReply: Codable, Sendable {
    public let token: UUID
    public let ok: Bool
    public let payload: Data
    public let message: String?

    public init(token: UUID, ok: Bool, payload: Data = Data(), message: String? = nil) {
        self.token = token
        self.ok = ok
        self.payload = payload
        self.message = message.map { String($0.prefix(512)) }
    }
}

public enum ExtensionEngineWire {
    public static let maximumPayloadBytes = 8 * 1024 * 1024
    public static let maximumMessageBytes = 12 * 1024 * 1024
    public static let maximumConcurrentRequests = ExtensionPeerEndpoint.maximumConcurrentCommands

    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard !data.isEmpty, data.count <= maximumMessageBytes else {
            throw ExtensionEngineError.rejected
        }
        return data
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard !data.isEmpty, data.count <= maximumMessageBytes else {
            throw ExtensionEngineError.rejected
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
