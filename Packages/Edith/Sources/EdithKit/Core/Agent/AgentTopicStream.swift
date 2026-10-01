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
        decodedValues(type, topic: topic, client: client)
    }

    public static func values(
        _ type: [AgentEvent].Type, topic: AgentTopic, client: AgentClient = .shared
    ) -> AsyncStream<[AgentEvent]> {
        guard topic == .events else {
            return decodedValues(type, topic: topic, client: client)
        }
        return eventValues(client: client)
    }

    private static func decodedValues<Value: Decodable & Sendable>(
        _ type: Value.Type, topic: AgentTopic, client: AgentClient
    ) -> AsyncStream<Value> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = AgentSubscriptionBox()
            let worker = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do {
                        let subscription = try await client.subscribeAsync(topic) { payload in
                            guard let value = try? AgentPayload.decode(Value.self, from: payload)
                            else { return }
                            continuation.yield(value)
                        }
                        box.store(subscription)
                        return
                    } catch let error as AgentError where error.kind == .unavailable {
                        do {
                            try await Task.sleep(for: .seconds(client.subscriptionRetryDelay))
                        } catch {
                            break
                        }
                    } catch {
                        break
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                worker.cancel()
                box.cancel()
            }
        }
    }

    private static func eventValues(client: AgentClient) -> AsyncStream<[AgentEvent]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let box = AgentSubscriptionBox()
            let feed = AgentEventFeedState()
            let worker = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    do {
                        let subscription = try await client.subscribeAsync(.events) { payload in
                            guard let events = feed.reduce(payload) else { return }
                            continuation.yield(events)
                        }
                        box.store(subscription)
                        return
                    } catch let error as AgentError where error.kind == .unavailable {
                        do {
                            try await Task.sleep(for: .seconds(client.subscriptionRetryDelay))
                        } catch {
                            break
                        }
                    } catch {
                        break
                    }
                }
                continuation.finish()
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
        try? await client.snapshotAsync(type, topic: topic)
    }
}

private final class AgentEventFeedState: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [AgentEvent] = []
    private var through: UInt64 = 0

    func reduce(_ payload: Data) -> [AgentEvent]? {
        lock.lock()
        defer { lock.unlock() }
        guard let next = AgentEventFeed.reduce(log: log, through: &through, payload: payload) else {
            return nil
        }
        log = next
        return next
    }
}
