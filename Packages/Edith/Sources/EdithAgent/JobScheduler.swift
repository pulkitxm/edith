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

    private struct State {
        var job: AgentJob
        var subscribers = 0
        var lastRun: Date?
        var lastDuration: TimeInterval?
        var lastError: String?
        var runCount = 0
        var running = false
        var task: Task<Void, Never>?
    }

    private var states: [String: State] = [:]
    private var order: [String] = []
    private let publish: Publish
    private let power: AgentPowerSource
    private let clock: @Sendable () -> Date
    private var pauseAmbientOnBattery: Bool
    private var started = false

    public init(
        publish: @escaping Publish = { _, _ in },
        power: AgentPowerSource = StaticPowerSource(),
        pauseAmbientOnBattery: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.publish = publish
        self.power = power
        self.pauseAmbientOnBattery = pauseAmbientOnBattery
        self.clock = clock
    }

    public func register(_ job: AgentJob) {
        if states[job.descriptor.id] == nil { order.append(job.descriptor.id) }
        states[job.descriptor.id] = State(job: job)
        if started { schedule(job.descriptor.id) }
    }

    public func start() {
        started = true
        for id in order { schedule(id) }
    }

    public func stop() {
        started = false
        for id in order {
            states[id]?.task?.cancel()
            states[id]?.task = nil
        }
    }

    public func setPauseAmbientOnBattery(_ paused: Bool) {
        pauseAmbientOnBattery = paused
        guard started else { return }
        for id in order { schedule(id) }
    }

    public func addSubscriber(topic: AgentTopic) {
        for id in identifiers(for: topic) {
            states[id]?.subscribers += 1
            schedule(id)
        }
    }

    public func removeSubscriber(topic: AgentTopic) {
        for id in identifiers(for: topic) {
            let current = states[id]?.subscribers ?? 0
            states[id]?.subscribers = max(0, current - 1)
            schedule(id)
        }
    }

    private func identifiers(for topic: AgentTopic) -> [String] {
        order.filter { states[$0]?.job.descriptor.topic == topic }
    }

    public func subscriberCount(topic: AgentTopic) -> Int {
        order.compactMap { id -> Int? in
            guard let state = states[id], state.job.descriptor.topic == topic else { return nil }
            return state.subscribers
        }.max() ?? 0
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
    public func runNow(_ id: String) async -> Data? {
        guard let state = states[id], state.job.isEnabled() else { return nil }
        states[id]?.running = true
        let started = clock()
        do {
            let payload = try await state.job.run()
            states[id]?.running = false
            states[id]?.lastRun = started
            states[id]?.lastDuration = clock().timeIntervalSince(started)
            states[id]?.lastError = nil
            states[id]?.runCount += 1
            if let payload, let topic = state.job.descriptor.topic {
                publish(topic, payload)
            }
            return payload
        } catch {
            states[id]?.running = false
            states[id]?.lastRun = started
            states[id]?.lastDuration = clock().timeIntervalSince(started)
            states[id]?.lastError = error.localizedDescription
            return nil
        }
    }

    private func phase(of state: State) -> AgentJobPhase {
        if !state.job.isEnabled() { return .disabled }
        if state.running { return .running }
        if state.lastError != nil { return .failed }
        let cadence = state.job.descriptor.cadence
        if cadence.ambient == nil, cadence.live == nil { return .idle }
        if interval(for: state) == nil { return .paused }
        return .idle
    }

    private func interval(for state: State) -> TimeInterval? {
        guard state.job.isEnabled(), isPermitted(state.job.descriptor.power) else { return nil }
        return AgentCadenceMath.interval(
            for: state.job.descriptor.cadence, subscribers: state.subscribers,
            pauseAmbient: pauseAmbientOnBattery && power.isOnBattery)
    }

    private func isPermitted(_ policy: AgentPowerPolicy) -> Bool {
        switch policy {
        case .any: true
        case .pauseOnLock: !power.isScreenLocked
        case .pauseOnSleep: true
        case .pauseOnBattery: !power.isOnBattery
        }
    }

    private func schedule(_ id: String) {
        states[id]?.task?.cancel()
        states[id]?.task = nil
        guard started, let state = states[id], let interval = interval(for: state) else { return }
        states[id]?.task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let tolerance = AgentCadenceMath.tolerance(for: interval)
                let jitter = Double.random(in: 0...tolerance)
                try? await Task.sleep(for: .seconds(interval + jitter))
                guard !Task.isCancelled else { return }
                await self.runNow(id)
            }
        }
    }
}
