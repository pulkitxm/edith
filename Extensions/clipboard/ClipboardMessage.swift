import Foundation

struct ClipboardServiceError: LocalizedError, Equatable, Sendable {
    enum Code: String, Sendable { case failed, refused, unavailable, unknownOperation }
    let code: Code
    let message: String
    init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    var errorDescription: String? { message }
}

enum ClipboardMessage {
    static func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}
