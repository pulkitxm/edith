import EdithKit
import Foundation

public enum SessionsTally {
    public static func snapshot(
        hosts: [HerdrHostSnapshot], now: Date = Date()
    ) -> SessionsSnapshot {
        let agents = hosts.flatMap(\.agents)
        return SessionsSnapshot(
            discoveredAt: now, hosts: hosts,
            working: agents.filter { $0.status == .working }.count, total: agents.count)
    }

    public static let remoteInterval: TimeInterval = 120

    public static func scope(subscribed: Bool, alerts: Bool, remoteDue: Bool)
        -> HerdrCollectScope?
    {
        if subscribed { return .all }
        guard alerts else { return nil }
        return remoteDue ? .all : .local
    }
}

public final class SessionsJob: @unchecked Sendable {
    private let store: AgentStore?
    private let collect: @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot]
    private let isSubscribed: @Sendable () async -> Bool
    private let defaults: UserDefaults
    private let notify: @Sendable ([HerdrHostSnapshot]) async throws -> Void
    private let now: @Sendable () -> Date
    private let tracksAgents: @Sendable () -> Bool
    private let observe: @Sendable ([HerdrHostSnapshot]) async -> Void
    private let lock = NSLock()
    private var remoteCollectedAt = Date.distantPast
    private var remoteHosts: [HerdrHostSnapshot] = []
    private var recordedPayloads: [Data]?

    public init(
        store: AgentStore?,
        isSubscribed: @escaping @Sendable () async -> Bool,
        defaults: UserDefaults = SharedDefaults.store,
        notify: @escaping @Sendable ([HerdrHostSnapshot]) async throws -> Void = {
            try await AgentNotificationService.collectSessions($0)
        },
        collect: @escaping @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot] = {
            await HerdrCollector.collect($0)
        },
        now: @escaping @Sendable () -> Date = Date.init,
        tracksAgents: @escaping @Sendable () -> Bool = { false },
        observe: @escaping @Sendable ([HerdrHostSnapshot]) async -> Void = { _ in }
    ) {
        self.tracksAgents = tracksAgents
        self.observe = observe
        self.store = store
        self.isSubscribed = isSubscribed
        self.defaults = defaults
        self.notify = notify
        self.collect = collect
        self.now = now
    }

    public func run() async throws -> Data? {
        let alerts = AgentAttentionSettings(defaults: defaults).anyEnabled || tracksAgents()
        let subscribed = await isSubscribed()
        guard
            let scope = SessionsTally.scope(
                subscribed: subscribed, alerts: alerts, remoteDue: remoteDue())
        else { return nil }
        if case .all = scope { markRemoteCollected() }
        let collected = await collect(scope)
        let snapshot = SessionsTally.snapshot(hosts: merged(collected, scope: scope))
        try await notify(collected)
        await observe(snapshot.hosts)
        SidebarBadgeStore.recordSessions(working: snapshot.working)
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func remoteDue() -> Bool {
        lock.withLock { now().timeIntervalSince(remoteCollectedAt) >= SessionsTally.remoteInterval }
    }

    private func markRemoteCollected() {
        lock.withLock { remoteCollectedAt = now() }
    }

    private func merged(_ collected: [HerdrHostSnapshot], scope: HerdrCollectScope)
        -> [HerdrHostSnapshot]
    {
        lock.withLock {
            switch scope {
            case .all:
                remoteHosts = collected.filter { !$0.isLocal }
                return collected
            case .local:
                return collected + remoteHosts
            case .machine:
                return collected
            }
        }
    }

    private func record(_ snapshot: SessionsSnapshot) throws {
        guard let store else { return }
        let payloads = try snapshot.hosts.map { try AgentPayload.encode($0) }
        guard lock.withLock({ recordedPayloads != payloads }) else { return }
        try store.write { database in
            try database.execute(sql: "DELETE FROM session_snapshot")
            for (host, payload) in zip(snapshot.hosts, payloads) {
                try database.execute(
                    sql: """
                        INSERT INTO session_snapshot (id, machine, capturedAt, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [host.id, host.name, snapshot.discoveredAt, payload])
            }
        }
        lock.withLock { recordedPayloads = payloads }
    }
}
