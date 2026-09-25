import EdithKit
import Foundation

public actor AgentNotificationService {
    private struct LevelState: Codable, Equatable {
        var sessionLevel = UsageLevel.green.rawValue
        var weeklyLevel = UsageLevel.green.rawValue
        var sessionPacing = PacingZone.onTrack.rawValue
        var weeklyPacing = PacingZone.onTrack.rawValue

        var value: LimitNotifierState {
            var value = LimitNotifierState()
            value.sessionLevel = UsageLevel(rawValue: sessionLevel) ?? .green
            value.weeklyLevel = UsageLevel(rawValue: weeklyLevel) ?? .green
            value.sessionPacing = PacingZone(rawValue: sessionPacing) ?? .onTrack
            value.weeklyPacing = PacingZone(rawValue: weeklyPacing) ?? .onTrack
            return value
        }

        init(_ value: LimitNotifierState = LimitNotifierState()) {
            sessionLevel = value.sessionLevel.rawValue
            weeklyLevel = value.weeklyLevel.rawValue
            sessionPacing = value.sessionPacing.rawValue
            weeklyPacing = value.weeklyPacing.rawValue
        }
    }

    private struct Reminder: Codable, Equatable {
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
    }

    private struct State: Codable, Equatable {
        var deliveries: [String: AgentNotificationDelivery] = [:]
        var levels = LevelState()
        var session: LimitWindow?
        var week: LimitWindow?
        var reminders: [String: Reminder] = [:]
        var agents: [String: [String: TrackedAgent]] = [:]
        var tokenExpiredAt: Date?
    }

    public static let shared = AgentNotificationService()
    public static let maximumPending = 256
    private static let limitPrefix = "limits."
    private let url: URL
    private let defaults: UserDefaults
    private let changed: @Sendable () -> Void
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
        url: URL = AppData.supportDir.appendingPathComponent("notifications.json"),
        defaults: UserDefaults = SharedDefaults.store,
        changed: @escaping @Sendable () -> Void = {
            IPC.post(AgentNotificationOperation.changed)
        },
        attention: AgentAttention = .live
    ) {
        self.url = url
        self.defaults = defaults
        self.changed = changed
        self.attention = attention
        state =
            (try? Data(contentsOf: url)).flatMap {
                try? AgentPayload.decode(State.self, from: $0)
            } ?? State()
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

    public func evaluateLimits(_ snapshot: LimitsTopicSnapshot, now: Date = Date()) throws {
        var next = state
        let settings = NotifySettings.fromDefaults(defaults)
        if let provider = snapshot.providers.first(where: { $0.provider == .claude }) {
            if provider.error == nil {
                next.session = provider.session
                next.week = provider.week
            }
            if settings.master, settings.tokenExpired,
                provider.error?.hasPrefix("Claude session expired") == true,
                now.timeIntervalSince(next.tokenExpiredAt ?? .distantPast) >= 3600
            {
                enqueue(
                    AgentNotification(
                        identifier: Self.limitPrefix + "token_expired",
                        title: "Claude token expired", body: "Run claude to log in again"),
                    into: &next, now: now)
                next.tokenExpiredAt = now
            }
        }
        reconcileLimits(&next, settings: settings, now: now)
        try commit(next)
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
        next.deliveries = next.deliveries.filter { ($0.value.expiresAt ?? .distantFuture) > now }
        reconcileLimits(&next, settings: NotifySettings.fromDefaults(defaults), now: now)
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
                if agent.status != .unknown, entry?.status != agent.status {
                    if let event = Self.event(from: entry?.status, to: agent.status),
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
                tracked[agent.id] = entry
            }
            next.agents[host.id] = tracked
        }
        return checks
    }

    static func event(from previous: HerdrAgentStatus?, to current: HerdrAgentStatus)
        -> HerdrAttentionEvent?
    {
        switch current {
        case .blocked: .blocked
        case .done, .idle: previous == .working || previous == .blocked ? .finished : nil
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

    private func reconcileLimits(_ next: inout State, settings: NotifySettings, now: Date) {
        let enabled =
            settings.master
            && defaults.bool(forKey: AppStorageKeys.Tabs.usageEnabled)
            && (defaults.object(forKey: AppStorageKeys.Limits.claudeEnabled) as? Bool ?? true)
        guard enabled else {
            next.levels = LevelState()
            next.deliveries = next.deliveries.filter { !$0.key.hasPrefix(Self.limitPrefix) }
            replaceReminders([:], in: &next)
            return
        }
        let session = next.session.flatMap { ($0.resetsAt ?? .distantFuture) > now ? $0 : nil }
        let week = next.week.flatMap { ($0.resetsAt ?? .distantFuture) > now ? $0 : nil }
        var levels = next.levels.value
        for alert in LimitNotifierLogic.decide(
            session: session, week: week, settings: settings, state: &levels, now: now)
        {
            enqueue(
                AgentNotification(
                    identifier: Self.limitPrefix + alert.id, title: alert.title, body: alert.body),
                into: &next, now: now)
        }
        next.levels = LevelState(levels)
        var reminders: [String: Reminder] = [:]
        let choices = [
            (
                "session", "Session", session, settings.reminderSession,
                settings.reminderSessionOffsetMin
            ),
            ("weekly", "Weekly", week, settings.reminderWeekly, settings.reminderWeeklyOffsetMin),
        ]
        for (key, title, window, enabled, offset) in choices where enabled {
            guard let reset = window?.resetsAt else { continue }
            let identifier = "reminder_" + key
            let fire = reset.addingTimeInterval(-Double(offset) * 60)
            guard fire > now || next.reminders[identifier]?.expiresAt == reset else { continue }
            reminders[identifier] = Reminder(
                notification: AgentNotification(
                    identifier: identifier,
                    title: "\(title) resets in \(LimitNotifierLogic.offsetLabel(minutes: offset))",
                    body: key == "session" ? "Save your spot or send it" : "Last lap on the cycle"),
                fireAt: fire, expiresAt: reset)
        }
        replaceReminders(reminders, in: &next)
    }

    private func replaceReminders(_ reminders: [String: Reminder], in next: inout State) {
        for identifier in Set(next.reminders.keys).union(reminders.keys) {
            guard next.reminders[identifier] != reminders[identifier] else { continue }
            let reminder = reminders[identifier]
            next.deliveries[identifier] = AgentNotificationDelivery(
                identifier: identifier, notification: reminder?.notification,
                fireAt: reminder?.fireAt, expiresAt: reminder?.expiresAt)
        }
        next.reminders = reminders
    }

    private func enqueue(_ notification: AgentNotification, into next: inout State, now: Date) {
        next.deliveries[notification.identifier] = AgentNotificationDelivery(
            identifier: notification.identifier, notification: notification,
            expiresAt: now.addingTimeInterval(86_400))
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
