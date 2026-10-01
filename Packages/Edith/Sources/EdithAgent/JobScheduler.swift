import EdithKit
import Foundation

public struct AgentJob: Sendable {
    public let descriptor: AgentJobDescriptor
    public let isEnabled: @Sendable () -> Bool
    public let run: @Sendable () async throws -> Data?
    public let cancelPending: @Sendable () -> Void

    public init(
        descriptor: AgentJobDescriptor,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        cancelPending: @escaping @Sendable () -> Void = {},
        run: @escaping @Sendable () async throws -> Data?
    ) {
        self.descriptor = descriptor
        self.isEnabled = isEnabled
        self.cancelPending = cancelPending
        self.run = run
    }
}

public protocol AgentPowerSource: Sendable {
    var isOnBattery: Bool { get }
    var isScreenLocked: Bool { get }
    var isConstrained: Bool { get }
}

extension AgentPowerSource {
    public var isConstrained: Bool { false }
}

public struct StaticPowerSource: AgentPowerSource {
    public let isOnBattery: Bool
    public let isScreenLocked: Bool

    public init(isOnBattery: Bool = false, isScreenLocked: Bool = false) {
        self.isOnBattery = isOnBattery
        self.isScreenLocked = isScreenLocked
    }
}

public actor JobScheduler {
    public typealias Publish = @Sendable (AgentTopic, Data, UInt64?) -> Void
    public typealias Observe = @Sendable (AgentEvent) async -> Void

    private struct Flight {
        let id: UUID
        let task: Task<Data?, Error>
        let finished: Task<Data?, Never>
    }

    private struct State {
        var job: AgentJob
        var subscribers = 0
        var lastRun: Date?
        var lastDuration: TimeInterval?
        var lastError: String?
        var runCount = 0
        var enqueued = false
        var rerunRequested = false
        var flight: Flight?
        var joinedRuns = 0
        var nextRun: Date?
        var interval: TimeInterval?
    }

    private var states: [String: State] = [:]
    private var order: [String] = []
    private var launchWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private let publish: Publish
    private let observe: Observe
    private let power: AgentPowerSource
    private let clock: @Sendable () -> Date
    private let maxConcurrent: Int
    private var pauseAmbientOnBattery: Bool
    private var started = false
    private var shuttingDown = false
    private var shutdownFlights: [Task<Data?, Never>] = []
    private var timer: Task<Void, Never>?
    private var jobsRevision: UInt64 = 0

    var concurrencyLimit: Int { maxConcurrent }

    public init(
        publish: @escaping Publish = { _, _, _ in },
        power: AgentPowerSource = StaticPowerSource(),
        pauseAmbientOnBattery: Bool = false,
        maxConcurrent: Int? = nil,
        clock: @escaping @Sendable () -> Date = { Date() },
        observe: @escaping Observe = { _ in }
    ) {
        self.publish = publish
        self.power = power
        self.pauseAmbientOnBattery = pauseAmbientOnBattery
        let processors = ProcessInfo.processInfo.activeProcessorCount
        self.maxConcurrent = max(1, maxConcurrent ?? max(2, processors))
        self.clock = clock
        self.observe = observe
    }

    public func register(_ job: AgentJob) {
        guard !shuttingDown else { return }
        let id = job.descriptor.id
        let subscribers = states[id]?.subscribers ?? 0
        states[id]?.job.cancelPending()
        states[id]?.flight?.task.cancel()
        states[id]?.flight?.finished.cancel()
        resumeLaunchWaiters(id)
        if states[id] == nil { order.append(id) }
        states[id] = State(job: job, subscribers: subscribers)
        refreshSchedule()
    }

    public func start() {
        guard !started, !shuttingDown else { return }
        started = true
        refreshSchedule()
    }

    public func stop() {
        started = false
        timer?.cancel()
        timer = nil
        for id in order {
            cancel(id)
            states[id]?.flight = nil
            states[id]?.nextRun = nil
            states[id]?.interval = nil
        }
        publishJobs()
    }

    public func shutdown() async {
        if !shuttingDown {
            shuttingDown = true
            shutdownFlights = states.values.compactMap { $0.flight?.finished }
            stop()
        }
        for flight in shutdownFlights { _ = await flight.result }
        shutdownFlights.removeAll()
    }

    public func setPauseAmbientOnBattery(_ paused: Bool) {
        pauseAmbientOnBattery = paused
        refreshSchedule()
    }

    public func addSubscriber(topic: AgentTopic) {
        for id in identifiers(for: topic) { states[id]?.subscribers += 1 }
        refreshSchedule()
    }

    public func removeSubscriber(topic: AgentTopic) {
        for id in identifiers(for: topic) {
            let count = states[id]?.subscribers ?? 0
            states[id]?.subscribers = max(0, count - 1)
        }
        refreshSchedule()
    }

    private func identifiers(for topic: AgentTopic) -> [String] {
        order.filter { states[$0]?.job.descriptor.topic == topic }
    }

    public func subscriberCount(topic: AgentTopic) -> Int {
        identifiers(for: topic).compactMap { states[$0]?.subscribers }.max() ?? 0
    }

    public var snapshots: [AgentJobSnapshot] {
        order.compactMap { id in
            guard let state = states[id] else { return nil }
            return AgentJobSnapshot(
                descriptor: state.job.descriptor, phase: phase(of: state),
                subscribers: state.subscribers, lastRun: state.lastRun,
                lastDuration: state.lastDuration, lastError: state.lastError,
                runCount: state.runCount)
        }
    }

    @discardableResult
    public func enqueue(_ id: String) -> Bool {
        guard !shuttingDown, var state = states[id], state.job.isEnabled() else { return false }
        if state.flight != nil {
            state.rerunRequested = true
            states[id] = state
            return true
        }
        guard !state.enqueued else { return true }
        state.enqueued = true
        states[id] = state
        pump()
        return true
    }

    @discardableResult
    public func enqueueIfDue(_ id: String) -> Bool {
        guard !shuttingDown, let state = states[id], state.job.isEnabled() else { return false }
        guard state.flight == nil else { return true }
        guard state.lastRun != nil else { return enqueue(id) }
        guard state.nextRun.map({ $0 <= clock() }) ?? true else { return false }
        return enqueue(id)
    }

    @discardableResult
    public func enqueueFileSystemChange(_ id: String, topic: AgentTopic) -> Bool {
        if subscriberCount(topic: topic) > 0 { return enqueue(id) }
        return enqueueIfDue(id)
    }

    var joinedRuns: [String: Int] {
        states.mapValues(\.joinedRuns)
    }

    @discardableResult
    public func runNow(_ id: String) async -> Data? {
        guard !shuttingDown, let state = states[id], state.job.isEnabled() else { return nil }
        if let flight = state.flight {
            states[id]?.joinedRuns += 1
            return await flight.finished.value
        }
        if state.enqueued {
            states[id]?.joinedRuns += 1
            await waitForLaunch(id)
            guard let flight = states[id]?.flight else { return nil }
            return await flight.finished.value
        }
        states[id]?.enqueued = true
        pump()
        if states[id]?.flight == nil { await waitForLaunch(id) }
        guard let flight = states[id]?.flight else { return nil }
        return await flight.finished.value
    }

    public func cancel(_ id: String) {
        states[id]?.job.cancelPending()
        states[id]?.enqueued = false
        states[id]?.rerunRequested = false
        states[id]?.flight?.task.cancel()
        resumeLaunchWaiters(id)
    }

    private var inFlightCount: Int {
        states.values.reduce(into: 0) { count, state in
            if state.flight != nil { count += 1 }
        }
    }

    private func pump() {
        guard !shuttingDown else { return }
        while inFlightCount < maxConcurrent {
            guard
                let id = order.first(where: {
                    states[$0]?.enqueued == true && states[$0]?.flight == nil
                })
            else { return }
            guard states[id]?.job.isEnabled() == true else {
                states[id]?.enqueued = false
                continue
            }
            if !startFlight(id) {
                states[id]?.enqueued = false
            }
        }
    }

    private func startFlight(_ id: String) -> Bool {
        guard let state = states[id], state.flight == nil else { return false }
        let token = UUID()
        let began = clock()
        let run = state.job.run
        let task = Task.detached(priority: .utility) {
            try await run()
        }
        let finished = Task { () -> Data? in
            await self.observe(AgentEvent(category: "job", name: id, message: "Started"))
            let result = await task.result
            return await self.complete(id: id, token: token, began: began, result: result)
        }
        states[id]?.flight = Flight(id: token, task: task, finished: finished)
        states[id]?.enqueued = false
        publishJobs()
        resumeLaunchWaiters(id)
        return true
    }

    private func complete(
        id: String, token: UUID, began: Date, result: Result<Data?, Error>
    ) async -> Data? {
        guard states[id]?.flight?.id == token else { return nil }
        states[id]?.lastRun = began
        let duration = max(0, clock().timeIntervalSince(began))
        states[id]?.lastDuration = duration
        var payload: Data?
        let topic = states[id]?.job.descriptor.topic
        switch result {
        case .success(let value):
            let failure = Self.payloadFailure(value, topic: topic)
            states[id]?.lastError = failure
            if failure == nil { states[id]?.runCount += 1 }
            payload = value
            if let value, let topic { publish(topic, value, nil) }
            await observe(
                AgentEvent(
                    level: failure == nil ? .info : .error,
                    category: "job", name: id, message: failure ?? "Completed",
                    duration: duration))
        case .failure(let error):
            let cancelled = error is CancellationError
            if cancelled { states[id]?.rerunRequested = false }
            states[id]?.lastError = cancelled ? nil : error.localizedDescription
            await observe(
                AgentEvent(
                    level: cancelled ? .info : .error, category: "job", name: id,
                    message: cancelled ? "Cancelled" : error.localizedDescription,
                    duration: duration))
        }
        guard var state = states[id], state.flight?.id == token else { return nil }
        state.flight = nil
        let rerunRequested = state.rerunRequested
        state.rerunRequested = false
        if let interval = interval(for: state) {
            state.nextRun = clock().addingTimeInterval(interval)
        }
        states[id] = state
        publishJobs()
        refreshSchedule()
        if rerunRequested { enqueue(id) }
        pump()
        return payload
    }

    private func waitForLaunch(_ id: String) async {
        if states[id]?.flight != nil { return }
        await withCheckedContinuation { continuation in
            launchWaiters[id, default: []].append(continuation)
        }
    }

    private func resumeLaunchWaiters(_ id: String) {
        let waiters = launchWaiters.removeValue(forKey: id) ?? []
        for waiter in waiters { waiter.resume() }
    }

    public func refreshSchedule() {
        timer?.cancel()
        timer = nil
        guard started else { return }
        let now = clock()
        for id in order {
            guard let state = states[id] else { continue }
            let current = interval(for: state)
            if current != state.interval {
                var updated = state
                updated.interval = current
                updated.nextRun = current.map { now.addingTimeInterval($0) }
                states[id] = updated
            }
            if !state.job.isEnabled() { cancel(id) }
        }
        let next = order.compactMap { id in
            states[id].flatMap { $0.flight == nil ? $0.nextRun : nil }
        }.min()
        let delay = min(30, max(0.05, next?.timeIntervalSince(now) ?? 30))
        timer = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay), tolerance: .seconds(delay / 10))
            } catch { return }
            guard !Task.isCancelled else { return }
            await self?.tick()
        }
    }

    public func tick() {
        guard started else { return }
        let now = clock()
        for id in order {
            guard let state = states[id], interval(for: state) != nil,
                let next = state.nextRun, next <= now, state.flight == nil
            else { continue }
            states[id]?.nextRun = now.addingTimeInterval(interval(for: state) ?? 30)
            enqueue(id)
        }
        refreshSchedule()
    }

    static func payloadFailure(_ payload: Data?, topic: AgentTopic?) -> String? {
        guard let payload else { return nil }
        switch topic {
        case .usage:
            return (try? AgentPayload.decode(UsageTopicSnapshot.self, from: payload))?.failure
        case .limits:
            guard let snapshot = try? AgentPayload.decode(LimitsTopicSnapshot.self, from: payload)
            else { return nil }
            return snapshot.failure ?? snapshot.providers.compactMap(\.error).first
        default: return nil
        }
    }

    private func phase(of state: State) -> AgentJobPhase {
        if !state.job.isEnabled() { return .disabled }
        if state.flight != nil { return .running }
        if state.lastError != nil { return .failed }
        if state.job.descriptor.cadence == .onDemand { return .idle }
        return interval(for: state) == nil ? .paused : .idle
    }

    private func interval(for state: State) -> TimeInterval? {
        interval(for: state, constrained: power.isConstrained)
    }

    private func interval(for state: State, constrained: Bool) -> TimeInterval? {
        guard state.job.isEnabled() else { return nil }
        switch state.job.descriptor.power {
        case .pauseOnLock where power.isScreenLocked: return nil
        case .pauseOnBattery where power.isOnBattery: return nil
        default: break
        }
        let value = AgentCadenceMath.interval(
            for: state.job.descriptor.cadence, subscribers: state.subscribers,
            pauseAmbient: pauseAmbientOnBattery && power.isOnBattery,
            constrained: constrained)
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func publishJobs() {
        jobsRevision &+= 1
        guard let payload = try? AgentPayload.encode(snapshots) else { return }
        publish(.jobs, payload, jobsRevision)
    }
}
