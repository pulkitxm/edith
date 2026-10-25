import Foundation

public struct HostAgentCommandError: LocalizedError, Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unavailable, refused, failed, cancelled, unknownOperation
    }
    public let kind: Kind
    public let message: String
    public var errorDescription: String? { message }
    public init(_ kind: Kind, _ message: String) { self.kind = kind; self.message = message }
}

public enum HostAgentPayload {
    public static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: data)
    }
}
