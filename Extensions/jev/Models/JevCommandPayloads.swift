import Foundation

struct JevStatusQuery: Codable, Sendable {
    let probe: Bool
}

struct JevKeyUpdate: Codable, Sendable {
    let key: String?
}

struct JevCall: Codable, Sendable, Equatable {
    let purpose: String
    let request: JevRequest
}

struct JevReply: Codable, Sendable, Equatable {
    var decision: JevDecision?
    var error: JevError?

    func unwrap() throws -> JevDecision {
        guard let decision else { throw error ?? .malformedResponse }
        return decision
    }
}
