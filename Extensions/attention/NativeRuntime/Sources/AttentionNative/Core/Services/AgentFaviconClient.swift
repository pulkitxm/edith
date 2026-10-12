import Foundation

struct AgentFaviconClient: Sendable {
    static let operation = "attention.favicon"
    func data(for url: URL) async throws -> Data? {
        try AttentionPayload.decode(
            Data?.self,
            from: await AttentionPeer.invoke(
                Self.operation, payload: AttentionPayload.encode(url), timeout: 40))
    }
}
