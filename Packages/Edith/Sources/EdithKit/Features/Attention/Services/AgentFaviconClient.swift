import Foundation

public struct AgentFaviconClient: Sendable {
    public static let operation = "attention.favicon"
    private let client: AgentClient

    public init(client: AgentClient = .shared) { self.client = client }

    public func data(for url: URL) async throws -> Data? {
        try AgentPayload.decode(
            Data?.self,
            from: await client.performInternalAsync(
                Self.operation, payload: AgentPayload.encode(url), timeout: 40))
    }
}
