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
    private var events: [AgentEvent] = []
    public private(set) var isShuttingDown = false
    private var shutdownHandlers: [String: @Sendable () async -> Void] = [:]
    private var shutdownTasks: [String: Task<Void, Never>] = [:]

    public init(build: String, store: AgentStore?, startedAt: Date = Date()) {
        self.build = build
        self.store = store
        self.startedAt = startedAt
        self.events = AgentEventJournal.load(store: store)
    }

    public func attach(scheduler: JobScheduler) {
        self.scheduler = scheduler
    }

    public func register(operation: String, handler: @escaping OperationHandler) {
        guard !isShuttingDown else { return }
        operations[operation] = handler
    }

    public func registerShutdown(id: String, handler: @escaping @Sendable () async -> Void) async {
        guard isShuttingDown else {
            shutdownHandlers[id] = handler
            return
        }
        if let existing = shutdownTasks[id] {
            await existing.value
            return
        }
        let task = Task { await handler() }
        shutdownTasks[id] = task
        await task.value
    }

    public func shutdown() async {
        if !isShuttingDown {
            isShuttingDown = true
            for (id, handler) in shutdownHandlers {
                shutdownTasks[id] = Task { await handler() }
            }
            shutdownHandlers.removeAll()
        }
        var completed = Set<String>()
        while let (id, task) = shutdownTasks.first(where: { !completed.contains($0.key) }) {
            await task.value
            completed.insert(id)
        }
    }

    public var registeredOperations: Set<String> { Set(operations.keys) }

    public func handshake() -> AgentHandshake {
        AgentHandshake(
            protocolVersion: AgentService.protocolVersion, build: build, startedAt: startedAt)
    }

    public func publish(topic: AgentTopic, payload: Data) {
        guard latest[topic] != payload else { return }
        latest[topic] = payload
        for subscriber in subscribers.values where subscriber.topics.contains(topic) {
            subscriber.proxy?.topicChanged(topic: topic.rawValue, payload: payload)
        }
    }

    public func record(_ event: AgentEvent) {
        events.append(event)
        if events.count > AgentDiagnostics.capacity {
            events.removeFirst(events.count - AgentDiagnostics.capacity)
        }
        AgentEventJournal.append(event, store: store)
        if let payload = try? AgentPayload.encode(events) {
            publish(topic: .events, payload: payload)
        }
        AgentLog.logger.info(
            "\(event.category, privacy: .public).\(event.name, privacy: .public): \(event.message, privacy: .private)"
        )
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
        if busSubscribers[peer] == nil, subscribers[peer]?.topics.isEmpty == true {
            subscribers[peer] = nil
        }
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
        if topic == .events { return try AgentPayload.encode(events) }
        if topic == .jobs { return try AgentPayload.encode(await jobSnapshots()) }
        if let cached = latest[topic] { return cached }
        guard let scheduler else { throw AgentError(.unavailable, "The agent is still starting.") }
        for snapshot in await scheduler.snapshots where snapshot.descriptor.topic == topic {
            if let payload = await scheduler.runNow(snapshot.descriptor.id) {
                latest[topic] = payload
                return payload
            }
            let job = await scheduler.snapshots.first { $0.id == snapshot.id }
            throw AgentError(.failed, job?.lastError ?? "This job has no data yet or is disabled.")
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
        Task { await deliverSnapshot(peer: peer, topic: topic) }
    }

    private func deliverSnapshot(peer: UUID, topic: AgentTopic) async {
        guard let payload = try? await snapshot(topic: topic),
            let subscriber = subscribers[peer], subscriber.topics.contains(topic)
        else { return }
        subscriber.proxy?.topicChanged(topic: topic.rawValue, payload: payload)
    }

    public func unsubscribe(peer: UUID, topic: AgentTopic) async {
        guard var existing = subscribers[peer], existing.topics.contains(topic) else { return }
        var topics = existing.topics
        topics.remove(topic)
        existing = Subscriber(topics: topics, proxy: existing.proxy)
        subscribers[peer] = topics.isEmpty && busSubscribers[peer] == nil ? nil : existing
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
        guard !isShuttingDown else { throw AgentError.unavailable }
        guard let handler = operations[operation] else {
            throw AgentError(.unknownOperation, "The agent does not serve \(operation).")
        }
        do {
            return try await handler(payload)
        } catch {
            record(
                AgentEvent(
                    level: .error, category: "operation", name: operation,
                    message: error.localizedDescription))
            throw error
        }
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
