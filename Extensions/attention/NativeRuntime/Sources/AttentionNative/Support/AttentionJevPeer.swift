@_implementationOnly import EdithExtensionSupport
import Foundation

protocol JevDeciding: Sendable {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision
}

struct AttentionJevPeer: JevDeciding {
    static func configured() async -> JevDeciding? {
        guard ExtensionSharedState.current?.values(for: "jev")["configured"] == "1" else {
            return nil
        }
        return AttentionJevPeer()
    }
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        struct Call: Codable { let purpose: String; let request: JevRequest }
        struct Reply: Codable { var decision: JevDecision?; var error: JevError? }
        guard let endpoint = ExtensionPeerEndpoint.current(owner: "jev") else {
            throw JevError.missingKey
        }
        let payload = try JSONEncoder().encode(Call(purpose: purpose, request: request.validated()))
        let reply = try JSONDecoder().decode(
            Reply.self, from: await endpoint.invoke("jev.decide", payload: payload, timeout: 120))
        guard let decision = reply.decision else { throw reply.error ?? .malformedResponse }
        return decision
    }
}
