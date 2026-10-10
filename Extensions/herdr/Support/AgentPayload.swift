import Foundation
public enum AgentPayload {
    private static let lock = NSLock()
    private static let cachedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private static let cachedDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public static func encode(_ value: some Encodable) throws -> Data {
        try lock.withLock { try cachedEncoder.encode(value) }
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try lock.withLock { try cachedDecoder.decode(type, from: data) }
    }
}
