import EdithKit
import Foundation

public actor AgentNotificationService {
    public typealias HistoryLoader = @Sendable (Date) -> [LimitAlertTarget: [LimitAlertSample]]
    public typealias JevResolver = @Sendable () async -> (any JevDeciding)?
    public typealias ClockFactory = @Sendable (Date) -> LimitAlertClock

    private struct Scheduled: Codable, Equatable {
        let notification: AgentNotification
        let fireAt: Date
        let expiresAt: Date
    }

    private struct TrackedAgent: Codable, Equatable {
        var status: HerdrAgentStatus
        var since: Date
        var checkedAt: Date?
        var fingerprint: UInt64?
        var stuck = false
        var sequence: Int?
    }

    private struct State: Codable, Equatable {
        var deliveries: [String: AgentNotificationDelivery] = [:]
        var ledger = LimitAlertLedger()
        var scheduled: [String: Scheduled] = [:]
        var agents: [String: [String: TrackedAgent]] = [:]
    }

    public static let shared = AgentNotificationService()
    public static let maximumPending = 256
    private static let limitPrefix = "limits."
    private let url: URL
    private let defaults: UserDefaults
    private let changed: @Sendable () -> Void
    private let history: HistoryLoader
    private let jev: JevResolver
    private let clock: ClockFactory
    private let attention: AgentAttention
    private var state: State
    private var observation: NSObjectProtocol?

    public nonisolated static func collectLimits(_ snapshot: LimitsTopicSnapshot) async throws {
        try await shared.evaluateLimits(snapshot)
    }

    public nonisolated static func collectSessions(_ hosts: [HerdrHostSnapshot]) async throws {
        try await shared.evaluateSessions(hosts)
    }

    public init(
        url: URL = LimitAlertLedger.outboxURL,
        defaults: UserDefaults = SharedDefaults.store,
        changed: @escaping @Sendable () -> Void = {
            IPC.post(AgentNotificationOperation.changed)
        },
        history: @escaping HistoryLoader = { LimitsHistory.alertSamples(since: $0) },
        jev: @escaping JevResolver = { await AgentNotificationService.decider(AgentJev.engine) },
        clock: @escaping ClockFactory = { LimitAlertClock(now: $0) },
        attention: AgentAttention = .live
    ) {
        self.url = url
        self.defaults = defaults
        self.changed = changed
        self.history = history
        self.jev = jev
        self.clock = clock
        self.attention = attention
        state =
            (try? Data(contentsOf: url)).flatMap {
                try? AgentPayload.decode(State.self, from: $0)
            } ?? State()
    }

    public static func decider(_ engine: JevEngine) async -> (any JevDeciding)? {
        await engine.isConfigured ? engine : nil
    }

    deinit {
        if let observation { IPC.stopObserving(observation) }
    }

    public func start() throws {
        guard observation == nil else { return }
        observation = IPC.observe(IPC.Name.settingsChanged) { [weak self] in
            Task { try? await self?.reconcileSettings() }
        }
        try reconcileSettings()
    }

    public func enqueue(_ notification: AgentNotification, now: Date = Date()) throws {
        var next = state
        enqueue(notification, into: &next, now: now)
        try commit(next)
    }

    public func pending(now: Date = Date()) throws -> [AgentNotificationDelivery] {
        try reconcileSettings(now: now)
        return state.deliveries.values.sorted { $0.identifier < $1.identifier }
    }

    public func acknowledge(_ ids: [UUID]) throws {
        let accepted = Set(ids)
        var next = state
        next.deliveries = next.deliveries.filter { !accepted.contains($0.value.id) }
        try commit(next)
    }

    public func evaluateLimits(_ snapshot: LimitsTopicSnapshot, now: Date = Date()) async throws {
        let settings = LimitAlertSettings.fromDefaults(defaults)
        guard settings.master else { return try reconcileSettings(now: now) }
        let samples = history(now.addingTimeInterval(-LimitAlertPlanner.historySpan))
        var assessments: [LimitAlertAssessment] = []
        var problems: [LimitProvider: LimitLoginProblem] = [:]
        var healthy: Set<LimitProvider> = []
        for provider in snapshot.providers where settings.providers.contains(provider.provider) {
            if let error = provider.error {
                problems[provider.provider] = LimitLoginProblem(error: error)
                continue
            }
            guard provider.session != nil || provider.week != nil || provider.fable != nil else {
                continue
            }
            healthy.insert(provider.provider)
            for target in LimitAlertTarget.all
            where target.provider == provider.provider && settings.tracks(target) {
                guard let window = provider.window(for: target.slot),
                    (window.resetsAt ?? .distantFuture) > now
                else { continue }
                assessments.append(
                    LimitAlertPlanner.assess(
                        target, window: window, samples: samples[target] ?? [], now: now))
            }
        }
        let proposed = LimitAlertPlanner.plan(
            assessments, problems: problems, healthy: healthy, ledger: state.ledger,
            settings: settings, clock: clock(now))
        let needsJev = proposed.alerts.contains { !$0.kind.isCritical }
        let gate = LimitAlertJevGate(decider: needsJev ? await jev() : nil)
        var held: Set<String> = []
        for alert in proposed.alerts where !alert.kind.isCritical {
            if await !gate.allows(alert) { held.insert(alert.identifier) }
        }
        let plan =
            held.isEmpty
            ? proposed
            : LimitAlertPlanner.plan(
                assessments, problems: problems, healthy: healthy, ledger: state.ledger,
                settings: settings, clock: clock(now), held: held)
        let approved = plan.alerts
        var next = state
        next.ledger = plan.ledger
        replaceScheduled(
            Dictionary(
                plan.scheduled.compactMap { alert in
                    alert.fireAt.map {
                        (
                            alert.identifier,
                            Scheduled(
                                notification: Self.notification(alert), fireAt: $0,
                                expiresAt: alert.expiresAt ?? $0)
                        )
                    }
                }, uniquingKeysWith: { first, _ in first }), in: &next, now: now)
        for alert in approved {
            enqueue(
                Self.notification(alert), into: &next, now: now,
                expiresAt: alert.expiresAt ?? now.addingTimeInterval(86_400))
        }
        try commit(next)
    }

    private static func notification(_ alert: LimitAlert) -> AgentNotification {
        AgentNotification(identifier: alert.identifier, title: alert.title, body: alert.body)
    }

    public func evaluateSessions(_ hosts: [HerdrHostSnapshot], now: Date = Date()) async throws {
        let settings = AgentAttentionSettings(defaults: defaults)
        var next = state
        purgeSessions(&next, settings: settings)
        let checks =
            settings.anyEnabled ? track(hosts, settings: settings, into: &next, now: now) : []
        try commit(next)
        guard !checks.isEmpty else { return }
        let outcomes = await attention.resolve(checks, settings: settings)
        var resolved = state
        for outcome in outcomes {
            if var tracked = resolved.agents[outcome.hostID]?[outcome.agentID],
                tracked.status == .working, let fingerprint = outcome.fingerprint
            {
                tracked.fingerprint = fingerprint
                tracked.stuck =
                    outcome.notification?.identifier.hasPrefix("session.stuck.") ?? false
                resolved.agents[outcome.hostID]?[outcome.agentID] = tracked
            }
            if let notification = outcome.notification {
                enqueue(notification, into: &resolved, now: now)
            }
        }
        purgeSessions(&resolved, settings: AgentAttentionSettings(defaults: defaults))
        try commit(resolved)
    }

    public func reconcileSettings(now: Date = Date()) throws {
        var next = state
        let settings = LimitAlertSettings.fromDefaults(defaults)
        next.deliveries = next.deliveries.filter { identifier, delivery in
            guard (delivery.expiresAt ?? .distantFuture) > now else { return false }
            guard identifier.hasPrefix(Self.limitPrefix), delivery.notification != nil else {
                return true
            }
            return settings.permits(identifier: identifier)
        }
        replaceScheduled(
            next.scheduled.filter { settings.permits(identifier: $0.key) }, in: &next, now: now)
        purgeSessions(&next, settings: AgentAttentionSettings(defaults: defaults))
        try commit(next)
    }

    private func track(
        _ hosts: [HerdrHostSnapshot], settings: AgentAttentionSettings, into next: inout State,
        now: Date
    ) -> [AttentionCheck] {
        var checks: [AttentionCheck] = []
        let stall = TimeInterval(settings.stuckMinutes * 60)
        for host in hosts where host.reachable && host.error == nil {
            let known = next.agents[host.id] ?? [:]
            var tracked: [String: TrackedAgent] = [:]
            for agent in host.agents where !agent.isTerminal {
                var entry = known[agent.id]
                let moved =
                    agent.stateSequence != nil && entry?.sequence != nil
                    && entry?.sequence != agent.stateSequence
                if agent.status != .unknown, entry?.status != agent.status || moved {
                    if let event = Self.event(from: entry?.status, to: agent.status, moved: moved),
                        Self.wanted(event, settings: settings)
                    {
                        checks.append(AttentionCheck(agent: agent, hostID: host.id, event: event))
                    }
                    entry = TrackedAgent(status: agent.status, since: now)
                } else if var current = entry, current.status == .working, settings.stuck,
                    !current.stuck,
                    now.timeIntervalSince(current.checkedAt ?? current.since) >= stall
                {
                    checks.append(
                        AttentionCheck(
                            agent: agent, hostID: host.id, event: .stalled,
                            fingerprint: current.fingerprint))
                    current.checkedAt = now
                    entry = current
                }
                entry?.sequence = agent.stateSequence
                tracked[agent.id] = entry
            }
            next.agents[host.id] = tracked
        }
        return checks
    }

    static func event(
        from previous: HerdrAgentStatus?, to current: HerdrAgentStatus, moved: Bool = false
    ) -> HerdrAttentionEvent? {
        let ran = previous == .working || previous == .blocked
        return switch current {
        case .blocked: .blocked
        case .done: ran || moved ? .finished : nil
        case .idle: ran ? .finished : nil
        case .working, .unknown: nil
        }
    }

    private static func wanted(_ event: HerdrAttentionEvent, settings: AgentAttentionSettings)
        -> Bool
    {
        switch event {
        case .blocked: settings.blocked
        case .finished: settings.finished || settings.errors || settings.openDiff
        case .stalled: settings.stuck
        }
    }

    private func purgeSessions(_ next: inout State, settings: AgentAttentionSettings) {
        if !settings.anyEnabled { next.agents = [:] }
        let enabled = [settings.blocked, settings.finished, settings.errors, settings.stuck]
        for (kind, on) in zip(AgentAttention.kinds, enabled) where !on {
            next.deliveries = next.deliveries.filter { !$0.key.hasPrefix("session.\(kind).") }
        }
    }

    private func replaceScheduled(
        _ scheduled: [String: Scheduled], in next: inout State, now: Date
    ) {
        for identifier in Set(next.scheduled.keys).union(scheduled.keys) {
            let previous = next.scheduled[identifier]
            let wanted = scheduled[identifier]
            guard previous != wanted else { continue }
            if wanted == nil, let previous, previous.fireAt <= now { continue }
            next.deliveries[identifier] = AgentNotificationDelivery(
                identifier: identifier, notification: wanted?.notification,
                fireAt: wanted?.fireAt, expiresAt: wanted?.expiresAt)
        }
        next.scheduled = scheduled
    }

    private func enqueue(
        _ notification: AgentNotification, into next: inout State, now: Date,
        expiresAt: Date? = nil
    ) {
        next.deliveries[notification.identifier] = AgentNotificationDelivery(
            identifier: notification.identifier, notification: notification,
            expiresAt: expiresAt ?? now.addingTimeInterval(86_400))
        if next.deliveries.count > Self.maximumPending {
            let oldest = next.deliveries.values
                .filter { $0.fireAt == nil && $0.notification != nil }
                .min { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
            if let oldest { next.deliveries[oldest.identifier] = nil }
        }
    }

    private func commit(_ next: State) throws {
        guard next != state else { return }
        let data = try AgentPayload.encode(next)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let notify = state.deliveries != next.deliveries
        state = next
        if notify { changed() }
    }
}
