import EdithKit
import Foundation

public struct AgentJob: Sendable {
    public let descriptor: AgentJobDescriptor
    public let isEnabled: @Sendable () -> Bool
    public let run: @Sendable () async throws -> Data?

    public init(
        descriptor: AgentJobDescriptor,
        isEnabled: @escaping @Sendable () -> Bool = { true },
        run: @escaping @Sendable () async throws -> Data?
    ) {
        self.descriptor = descriptor
        self.isEnabled = isEnabled
        self.run = run
    }
}

public protocol AgentPowerSource: Sendable {
    var isOnBattery: Bool { get }
    var isScreenLocked: Bool { get }
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
    public typealias Publish = @Sendable (AgentTopic, Data) -> Void
    public typealias Observe = @Sendable (AgentEvent) async -> Void

    private struct Flight {
        let id: UUID
        let task: Task<Data?, Error>
    }

    private struct State {
        var job: AgentJob
        var subscribers = 0
        var lastRun: Date?
        var lastDuration: TimeInterval?
        var lastError: String?
        var runCount = 0
        var flight: Flight?
        var nextRun: Date?
        var interval: TimeInterval?
    }

    private var states: [String: State] = [:]
    private var order: [String] = []
    private let publish: Publish
    private let observe: Observe
    private let power: AgentPowerSource
    private let clock: @Sendable () -> Date
    private var pauseAmbientOnBattery: Bool
    private var started = false
    private var shuttingDown = false
    private var shutdownFlights: [Task<Data?, Error>] = []
    private var timer: Task<Void, Never>?

    public init(
        publish: @escaping Publish = { _, _ in },
        power: AgentPowerSource = StaticPowerSource(),
        pauseAmbientOnBattery: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() },
        observe: @escaping Observe = { _ in }
    ) {
        self.publish = publish
        self.power = power
        self.pauseAmbientOnBattery = pauseAmbientOnBattery
        self.clock = clock
        self.observe = observe
    }

    public func register(_ job: AgentJob) {
        guard !shuttingDown else { return }
        let id = job.descriptor.id
        let subscribers = states[id]?.subscribers ?? 0
        states[id]?.flight?.task.cancel()
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
            states[id]?.flight?.task.cancel()
            states[id]?.flight = nil
            states[id]?.nextRun = nil
            states[id]?.interval = nil
        }
        publishJobs()
    }

    public func shutdown() async {
        if !shuttingDown {
            shuttingDown = true
            shutdownFlights = states.values.compactMap { $0.flight?.task }
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
        guard !shuttingDown, let state = states[id], state.job.isEnabled() else { return false }
        guard state.flight == nil else { return true }
        Task { await runNow(id) }
        return true
    }

    @discardableResult
    public func runNow(_ id: String) async -> Data? {
        guard !shuttingDown, let state = states[id], state.job.isEnabled() else { return nil }
        if let flight = state.flight { return try? await flight.task.value }
        let token = UUID()
        let began = clock()
        let task = Task { try await state.job.run() }
        states[id]?.flight = Flight(id: token, task: task)
        publishJobs()
        await observe(AgentEvent(category: "job", name: id, message: "Started"))
        let result = await task.result
        guard states[id]?.flight?.id == token else { return nil }
        states[id]?.flight = nil
        states[id]?.lastRun = began
        let duration = max(0, clock().timeIntervalSince(began))
        states[id]?.lastDuration = duration
        var payload: Data?
        switch result {
        case .success(let value):
            states[id]?.lastError = nil
            states[id]?.runCount += 1
            payload = value
            if let value, let topic = state.job.descriptor.topic { publish(topic, value) }
            await observe(
                AgentEvent(
                    category: "job", name: id, message: "Completed", duration: duration))
        case .failure(let error):
            let cancelled = error is CancellationError
            states[id]?.lastError = cancelled ? nil : error.localizedDescription
            await observe(
                AgentEvent(
                    level: cancelled ? .info : .error, category: "job", name: id,
                    message: cancelled ? "Cancelled" : error.localizedDescription,
                    duration: duration))
        }
        if let interval = states[id].flatMap(interval(for:)) {
            states[id]?.nextRun = clock().addingTimeInterval(interval)
        }
        publishJobs()
        refreshSchedule()
        return payload
    }

    public func cancel(_ id: String) {
        states[id]?.flight?.task.cancel()
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
                states[id]?.interval = current
                states[id]?.nextRun = current.map { now.addingTimeInterval($0) }
            }
            if !state.job.isEnabled() { states[id]?.flight?.task.cancel() }
        }
        let next = order.compactMap { states[$0]?.nextRun }.min()
        let delay = min(30, max(0.05, next?.timeIntervalSince(now) ?? 30))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
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

    private func phase(of state: State) -> AgentJobPhase {
        if !state.job.isEnabled() { return .disabled }
        if state.flight != nil { return .running }
        if state.lastError != nil { return .failed }
        if state.job.descriptor.cadence == .onDemand { return .idle }
        return interval(for: state) == nil ? .paused : .idle
    }

    private func interval(for state: State) -> TimeInterval? {
        guard state.job.isEnabled() else { return nil }
        switch state.job.descriptor.power {
        case .pauseOnLock where power.isScreenLocked: return nil
        case .pauseOnBattery where power.isOnBattery: return nil
        default: break
        }
        let value = AgentCadenceMath.interval(
            for: state.job.descriptor.cadence, subscribers: state.subscribers,
            pauseAmbient: pauseAmbientOnBattery && power.isOnBattery)
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private func publishJobs() {
        guard let payload = try? AgentPayload.encode(snapshots) else { return }
        publish(.jobs, payload)
    }
}
