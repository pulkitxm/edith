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

    private struct State: Codable, Equatable {
        var deliveries: [String: AgentNotificationDelivery] = [:]
        var levels = LevelState()
        var session: LimitWindow?
        var week: LimitWindow?
        var reminders: [String: Reminder] = [:]
        var blocked: [String: Set<String>] = [:]
        var tokenExpiredAt: Date?
    }

    public static let shared = AgentNotificationService()
    public static let maximumPending = 256
    private static let limitPrefix = "limits."
    private let url: URL
    private let defaults: UserDefaults
    private let changed: @Sendable () -> Void
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
        }
    ) {
        self.url = url
        self.defaults = defaults
        self.changed = changed
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

    public func evaluateSessions(_ hosts: [HerdrHostSnapshot], now: Date = Date()) throws {
        var next = state
        guard blockedAlertsEnabled else {
            next.blocked = [:]
            next.deliveries = next.deliveries.filter { !$0.key.hasPrefix("session.blocked.") }
            try commit(next)
            return
        }
        for host in hosts where host.reachable && host.error == nil {
            let blocked = host.agents.filter { $0.status == .blocked && !$0.isTerminal }
            let previous = next.blocked[host.id] ?? []
            for agent in blocked where !previous.contains(agent.id) {
                enqueue(
                    AgentNotification(
                        identifier: "session.blocked." + agent.id,
                        title: "Session needs attention",
                        body:
                            "\(agent.title.isEmpty ? agent.session : agent.title) on \(host.name) is waiting for you."
                    ),
                    into: &next, now: now)
            }
            next.blocked[host.id] = Set(blocked.map(\.id))
        }
        try commit(next)
    }

    public func reconcileSettings(now: Date = Date()) throws {
        var next = state
        next.deliveries = next.deliveries.filter { ($0.value.expiresAt ?? .distantFuture) > now }
        reconcileLimits(&next, settings: NotifySettings.fromDefaults(defaults), now: now)
        if !blockedAlertsEnabled {
            next.blocked = [:]
            next.deliveries = next.deliveries.filter { !$0.key.hasPrefix("session.blocked.") }
        }
        try commit(next)
    }

    private var blockedAlertsEnabled: Bool {
        defaults.bool(forKey: AgentSettingsKeys.notifyWhenBlocked)
            && defaults.bool(forKey: AppStorageKeys.Tabs.herdrEnabled)
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
