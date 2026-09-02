import Darwin
import EdithKit
import Foundation

public actor AgentRuntime {
    public typealias OperationHandler = @Sendable (Data) async throws -> Data

    private struct Subscriber {
        let topics: Set<AgentTopic>
        let proxy: EdithAgentSubscriberXPC?
    }

    private let build: String
    private let startedAt: Date
    private let store: AgentStore?
    private var scheduler: JobScheduler!
    private var subscribers: [UUID: Subscriber] = [:]
    private var latest: [AgentTopic: Data] = [:]
    private var operations: [String: OperationHandler] = [:]
    private var busSubscribers: [UUID: Set<String>] = [:]

    public init(build: String, store: AgentStore?, startedAt: Date = Date()) {
        self.build = build
        self.store = store
        self.startedAt = startedAt
    }

    public func attach(scheduler: JobScheduler) {
        self.scheduler = scheduler
    }

    public func register(operation: String, handler: @escaping OperationHandler) {
        operations[operation] = handler
    }

    public func handshake() -> AgentHandshake {
        AgentHandshake(
            protocolVersion: AgentService.protocolVersion, build: build, startedAt: startedAt)
    }

    public func publish(topic: AgentTopic, payload: Data) {
        latest[topic] = payload
        for subscriber in subscribers.values where subscriber.topics.contains(topic) {
            subscriber.proxy?.topicChanged(topic: topic.rawValue, payload: payload)
        }
    }

    public func subscribeBus(peer: UUID, channel: String, subscriber: EdithAgentSubscriberXPC?) {
        busSubscribers[peer, default: []].insert(channel)
        if let subscriber, subscribers[peer] == nil {
            subscribers[peer] = Subscriber(topics: [], proxy: subscriber)
        }
    }

    public func unsubscribeBus(peer: UUID, channel: String) {
        busSubscribers[peer]?.remove(channel)
        if busSubscribers[peer]?.isEmpty == true { busSubscribers[peer] = nil }
    }

    public func publishBus(_ message: AgentBusMessage, from peer: UUID?) {
        let topic = AgentBus.topic(for: message.channel)
        for (id, channels) in busSubscribers where channels.contains(message.channel) {
            guard id != peer else { continue }
            subscribers[id]?.proxy?.topicChanged(topic: topic, payload: message.body)
        }
    }

    public var busChannelCount: Int {
        Set(busSubscribers.values.flatMap { $0 }).count
    }

    public func snapshot(topic: AgentTopic) async throws -> Data {
        if let cached = latest[topic] { return cached }
        guard let scheduler else { throw AgentError(.unavailable, "The agent is still starting.") }
        for snapshot in await scheduler.snapshots where snapshot.descriptor.topic == topic {
            if let payload = await scheduler.runNow(snapshot.descriptor.id) {
                latest[topic] = payload
                return payload
            }
        }
        throw AgentError(.unknownTopic, "No job publishes \(topic.rawValue) yet.")
    }

    public func subscribe(peer: UUID, topic: AgentTopic, subscriber: EdithAgentSubscriberXPC?) async
    {
        var topics = subscribers[peer]?.topics ?? []
        let isNew = !topics.contains(topic)
        topics.insert(topic)
        subscribers[peer] = Subscriber(
            topics: topics, proxy: subscriber ?? subscribers[peer]?.proxy)
        guard isNew else { return }
        await scheduler?.addSubscriber(topic: topic)
        if let cached = latest[topic] {
            subscriber?.topicChanged(topic: topic.rawValue, payload: cached)
        }
    }

    public func unsubscribe(peer: UUID, topic: AgentTopic) async {
        guard var existing = subscribers[peer], existing.topics.contains(topic) else { return }
        var topics = existing.topics
        topics.remove(topic)
        existing = Subscriber(topics: topics, proxy: existing.proxy)
        subscribers[peer] = topics.isEmpty ? nil : existing
        await scheduler?.removeSubscriber(topic: topic)
    }

    public func forget(peer: UUID) async {
        busSubscribers[peer] = nil
        guard let existing = subscribers.removeValue(forKey: peer) else { return }
        for topic in existing.topics {
            await scheduler?.removeSubscriber(topic: topic)
        }
    }

    public func perform(operation: String, payload: Data) async throws -> Data {
        guard let handler = operations[operation] else {
            throw AgentError(.unknownOperation, "The agent does not serve \(operation).")
        }
        return try await handler(payload)
    }

    public func jobSnapshots() async -> [AgentJobSnapshot] {
        await scheduler?.snapshots ?? []
    }

    public func runtimeSnapshot() async -> AgentRuntimeSnapshot {
        AgentRuntimeSnapshot(
            build: build, startedAt: startedAt,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            residentBytes: AgentProcessMetrics.residentBytes(),
            cpuPercent: AgentProcessMetrics.cpuPercent(since: startedAt),
            subscriberCount: subscribers.count,
            storePath: store?.url.path ?? "",
            schemaVersion: store?.schemaVersion ?? 0)
    }
}

enum AgentProcessMetrics {
    static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    static func cpuPercent(since started: Date) -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let seconds =
            Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
            + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
        let elapsed = max(1, Date().timeIntervalSince(started))
        return min(100, seconds / elapsed * 100)
    }
}
