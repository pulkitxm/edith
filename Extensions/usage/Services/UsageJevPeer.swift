import EdithExtensionSupport
import Foundation

public protocol JevDeciding: Sendable {
    func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision
}

public struct UsageJevPeer: JevDeciding {
    private struct Call: Encodable {
        let purpose: String
        let request: JevRequest
    }

    private struct Reply: Decodable {
        let decision: JevDecision?
        let error: JevError?
    }

    private let active: @Sendable () async -> Bool
    private let invoke: @Sendable (Data) async throws -> Data

    public init(
        active: @escaping @Sendable () async -> Bool,
        invoke: @escaping @Sendable (Data) async throws -> Data
    ) {
        self.active = active
        self.invoke = invoke
    }

    public static func current() async -> UsageJevPeer? {
        await MainActor.run {
            guard let context = SurfaceHostContext.current, context.activeIDs.contains("jev"),
                let endpoint = ExtensionPeerEndpoint.current(owner: "jev")
            else { return nil }
            return UsageJevPeer(
                active: { await MainActor.run { context.activeIDs.contains("jev") } },
                invoke: { try await endpoint.invoke("jev.decide", payload: $0, timeout: 10) })
        }
    }

    public func decide(_ request: JevRequest, purpose: String) async throws -> JevDecision {
        guard await active(), !purpose.isEmpty, purpose.utf8.count <= 128,
            !purpose.utf8.contains(0)
        else { throw ExtensionPeerError.unavailable }
        let data = try JSONEncoder().encode(Call(purpose: purpose, request: request.validated()))
        guard data.count <= 65_536 else { throw ExtensionPeerError.invalidRequest }
        let result = try await invoke(data)
        try Task.checkCancellation()
        guard await active(), result.count <= 65_536 else { throw ExtensionPeerError.unavailable }
        let reply = try JSONDecoder().decode(Reply.self, from: result)
        guard let decision = reply.decision else { throw reply.error ?? .malformedResponse }
        return decision
    }
}
