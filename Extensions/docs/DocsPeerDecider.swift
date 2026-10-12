import EdithDocsWorker
import EdithExtensionSupport
import Foundation

struct DocsPeerDecider: JevDeciding {
    let call: @Sendable (Data) async throws -> Data

    @MainActor
    static func configured() -> Self? {
        let configured =
            SurfaceHostContext.current?.activeIDs.contains("jev") == true
            && ExtensionSharedState.current?.values(for: "jev")["configured"] == "1"
        let endpoint = configured ? ExtensionPeerEndpoint.current(owner: "jev") : nil
        JevAvailability.record(configured: endpoint != nil, in: SharedDefaults.store)
        guard let endpoint else { return nil }
        return Self { try await endpoint.invoke("jev.decide", payload: $0, timeout: 5) }
    }

    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        guard purpose == DocsAsk.purpose else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(Call(purpose: purpose, request: request.validated()))
        guard data.count <= 131_072 else { throw ExtensionPeerError.invalidRequest }
        let response = try await call(data)
        try Task.checkCancellation()
        guard response.count <= 524_288 else { throw ExtensionPeerError.invalidRequest }
        let reply = try JSONDecoder().decode(Reply.self, from: response)
        guard let decision = reply.decision else { throw reply.error ?? .malformedResponse }
        return decision
    }

    private struct Call: Codable { let purpose: String; let request: JevRequest }
    private struct Reply: Codable { let decision: JevDecision?; let error: JevError? }
}
