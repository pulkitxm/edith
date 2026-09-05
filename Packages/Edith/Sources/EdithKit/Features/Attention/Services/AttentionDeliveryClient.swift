import Foundation

public enum AttentionDeliveryClient {
    public static let operation = "attention.deliver"
    public static let statusOperation = "attention.delivery-status"

    public static func deliver(
        _ request: AttentionDeliveryRequest, client: AgentClient = .shared
    ) async throws {
        _ = try await client.performInternalAsync(
            operation, payload: AgentPayload.encode(request), timeout: 5)
    }

    public static func health(client: AgentClient = .shared) async throws -> AttentionDeliveryHealth
    {
        let data = try await client.performInternalAsync(statusOperation, timeout: 5)
        return try AgentPayload.decode(AttentionDeliveryHealth.self, from: data)
    }
}
