import EdithExtensionSupport
import Foundation
import UserNotifications

@MainActor final class HerdrNotificationService {
    typealias Deliver = @MainActor (HerdrNotification) async throws -> Void
    private struct Tracked {
        var agent: HerdrAgent
        var since: Date
        var checkedAt: Date?
        var fingerprint: UInt64?
        var stuck = false
    }
    private struct Pending: Codable {
        let notification: HerdrNotification
        let expiresAt: Date
    }
    private struct QueueState: Codable {
        let pending: [String: Pending]
        let delivered: Set<String>
    }
    private let queueURL: URL
    private var pending: [String: Pending] = [:]
    private let defaults: UserDefaults
    private let attention: HerdrNotificationAttention
    private let deliver: Deliver
    private let remove: @MainActor ([String]) -> Void
    private let currentHosts: @MainActor () -> [HerdrHostSnapshot]?
    private let open: @MainActor (HerdrOpenRequest) -> Void
    private var tracked: [String: Tracked] = [:]
    private var delivered: Set<String> = []
    private var generation = 0
    private var stopped = false
    private(set) var deliveryError: String?

    init(
        defaults: UserDefaults = SharedDefaults.store,
        queueURL: URL = ExtensionData.root.appendingPathComponent("herdr/notifications.json"),
        attention: HerdrNotificationAttention = .init(
            inspect: { await HerdrPaneReader.inspect($0) },
            decider: { nil },
            appIsRunning: { true }),
        deliver: @escaping Deliver = { notification in
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.body = notification.body
            content.userInfo = notification.userInfo
            content.sound = .default
            try await UNUserNotificationCenter.current().add(
                UNNotificationRequest(
                    identifier: notification.identifier, content: content, trigger: nil))
        },
        remove: @escaping @MainActor ([String]) -> Void = { identifiers in
            guard !identifiers.isEmpty else { return }
            UNUserNotificationCenter.current().removePendingNotificationRequests(
                withIdentifiers: identifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(
                withIdentifiers: identifiers)
        },
        currentHosts: @escaping @MainActor () -> [HerdrHostSnapshot]? = { nil },
        open: @escaping @MainActor (HerdrOpenRequest) -> Void = { HerdrOpenRequests.submit($0) }
    ) {
        self.queueURL = queueURL
        if let data = try? Data(contentsOf: queueURL), data.count <= 1_048_576,
            let values = try? JSONDecoder().decode(QueueState.self, from: data)
        {
            delivered = Set(values.delivered.prefix(2048))
            pending = values.pending.filter {
                $0.key == $0.value.notification.identifier && $0.value.expiresAt > Date()
            }
        }
        self.defaults = defaults
        self.attention = attention
        self.deliver = deliver
        self.remove = remove
        self.open = open
        self.currentHosts = currentHosts
    }

    func evaluate(_ hosts: [HerdrHostSnapshot], hidden: Bool = false, now: Date = Date()) async {
        guard !stopped else { return }
        generation += 1
        let currentGeneration = generation
        let settings = HerdrAttentionSettings(defaults: defaults)
        reconcile(settings)
        guard !hidden, settings.anyEnabled else {
            tracked = [:]
            pending = [:]
            persist()
            return
        }
        let known = tracked
        var next: [String: Tracked] = [:]
        var checks: [AttentionCheck] = []
        for host in hosts.prefix(64) where host.reachable && host.error == nil {
            for agent in host.agents.prefix(512) where !agent.isTerminal {
                var value = known[agent.id]
                let moved =
                    agent.stateSequence != nil && value?.agent.stateSequence != nil
                    && agent.stateSequence != value?.agent.stateSequence
                if agent.status != .unknown, value?.agent.status != agent.status || moved {
                    if let event = Self.event(
                        from: value?.agent.status, to: agent.status, moved: moved),
                        Self.wanted(event, settings)
                    {
                        checks.append(.init(agent: agent, hostID: host.id, event: event))
                    }
                    value = Tracked(agent: agent, since: now)
                } else if var entry = value, agent.status == .working, settings.stuckMonitoring,
                    now.timeIntervalSince(entry.checkedAt ?? entry.since)
                        >= Double(settings.stuckMinutes * 60)
                {
                    checks.append(
                        .init(
                            agent: agent, hostID: host.id, event: .stalled,
                            fingerprint: entry.fingerprint))
                    entry.checkedAt = now
                    value = entry
                }
                value?.agent = agent
                next[agent.id] = value
            }
        }
        tracked = next
        guard !checks.isEmpty else {
            await flush(generation: currentGeneration, now: now)
            return
        }
        let outcomes = await attention.resolve(checks, settings: settings)
        guard !Task.isCancelled, !stopped, generation == currentGeneration else { return }
        for outcome in outcomes {
            if let hosts = currentHosts() {
                guard
                    let current = hosts.first(where: {
                        $0.id == outcome.hostID && $0.reachable && $0.error == nil
                    })?.agents.first(where: { $0.id == outcome.agentID }),
                    current.status == outcome.status, current.stateSequence == outcome.sequence
                else { continue }
            }
            guard var entry = tracked[outcome.agentID], entry.agent.machineID == outcome.hostID,
                entry.agent.status == outcome.status, entry.agent.stateSequence == outcome.sequence
            else { continue }
            let repeatedStall = entry.stuck && outcome.state == .looping
            entry.checkedAt = now
            entry.fingerprint = outcome.fingerprint
            entry.stuck = outcome.state == .looping
            tracked[outcome.agentID] = entry
            let currentSettings = HerdrAttentionSettings(defaults: defaults)
            if let request = outcome.openRequest, currentSettings.openDiff { open(request) }
            guard let notification = outcome.notification, !repeatedStall,
                permitted(notification.identifier, settings: currentSettings)
            else { continue }
            pending[notification.identifier] = Pending(
                notification: notification, expiresAt: now.addingTimeInterval(120))
        }
        persist()
        await flush(generation: currentGeneration, now: now)
    }

    private func flush(generation current: Int, now: Date) async {
        pending = pending.filter { $0.value.expiresAt > now }
        for identifier in pending.keys.sorted() {
            guard !Task.isCancelled, !stopped, generation == current,
                let value = pending[identifier]
            else { return }
            guard permitted(identifier, settings: HerdrAttentionSettings(defaults: defaults)) else {
                pending.removeValue(forKey: identifier)
                continue
            }
            do {
                try await deliver(value.notification)
                guard !Task.isCancelled, !stopped, generation == current else {
                    remove([identifier]); return
                }
                delivered.insert(identifier)
                if delivered.count > 2048 {
                    let retained = Set(delivered.sorted().suffix(2048))
                    remove(Array(delivered.subtracting(retained)))
                    delivered = retained
                }
                pending.removeValue(forKey: identifier)
                deliveryError = nil
            } catch { deliveryError = error.localizedDescription }
        }
        persist()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(
                at: queueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(QueueState(pending: pending, delivered: delivered)).write(
                to: queueURL, options: .atomic)
        } catch { deliveryError = error.localizedDescription }
    }

    func reconcile(_ settings: HerdrAttentionSettings) {
        let rejected = delivered.filter { !permitted($0, settings: settings) }
        remove(Array(rejected))
        delivered.subtract(rejected)
        pending = pending.filter { permitted($0.key, settings: settings) }
        persist()
        if !settings.stuckMonitoring {
            for id in tracked.keys { tracked[id]?.stuck = false; tracked[id]?.fingerprint = nil }
        }
    }

    func shutdown() {
        stopped = true
        generation += 1
        tracked = [:]
        remove(Array(delivered))
        delivered = []
        pending = [:]
        persist()
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

    private static func wanted(_ event: HerdrAttentionEvent, _ settings: HerdrAttentionSettings)
        -> Bool
    {
        switch event {
        case .blocked: settings.blocked || settings.monitoring
        case .finished:
            settings.finished || settings.errors || settings.openDiff || settings.monitoring
        case .stalled: settings.stuckMonitoring
        }
    }

    private func permitted(_ id: String, settings: HerdrAttentionSettings) -> Bool {
        for (kind, enabled) in zip(
            HerdrNotificationAttention.kinds,
            [settings.blocked, settings.finished, settings.errors, settings.stuck])
        {
            if id.hasPrefix("session.\(kind).") { return enabled }
        }
        return false
    }
}
