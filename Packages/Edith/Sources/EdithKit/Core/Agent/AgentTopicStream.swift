import Foundation

final class AgentSubscriptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var subscription: AgentSubscription?
    private var cancelled = false

    func store(_ value: AgentSubscription) {
        lock.lock()
        let discard = cancelled
        if !discard { subscription = value }
        lock.unlock()
        if discard { value.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let value = subscription
        subscription = nil
        lock.unlock()
        value?.cancel()
    }
}

public enum AgentTopicStream {
    public static func values<Value: Decodable & Sendable>(
        _ type: Value.Type, topic: AgentTopic, client: AgentClient = .shared
    ) -> AsyncStream<Value> {
        AsyncStream { continuation in
            let box = AgentSubscriptionBox()
            let worker = Task.detached(priority: .utility) {
                do {
                    let subscription = try client.subscribe(topic) { payload in
                        guard let value = try? AgentPayload.decode(Value.self, from: payload)
                        else { return }
                        continuation.yield(value)
                    }
                    box.store(subscription)
                } catch {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                worker.cancel()
                box.cancel()
            }
        }
    }

    public static func snapshot<Value: Decodable & Sendable>(
        _ type: Value.Type, topic: AgentTopic, client: AgentClient = .shared
    ) async -> Value? {
        await AgentQuery.optional { try client.snapshot(type, topic: topic) }
    }
}
