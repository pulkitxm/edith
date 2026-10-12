import Foundation

enum AttentionDeliveryClient {
    static let operation = "attention.deliver"
    static let statusOperation = "attention.deliveryStatus"
    static func deliver(_ request: AttentionDeliveryRequest) async throws {
        _ = try await AttentionPeer.invoke(
            operation, payload: AttentionPayload.encode(request), timeout: 5)
    }
    static func health() async throws -> AttentionDeliveryHealth {
        try AttentionPayload.decode(
            AttentionDeliveryHealth.self,
            from: await AttentionPeer.invoke(statusOperation))
    }
}
