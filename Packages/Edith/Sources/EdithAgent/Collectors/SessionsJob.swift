import EdithKit
import Foundation

public struct SessionsHost: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let isLocal: Bool
    public let reachable: Bool
    public let herdrPresent: Bool
    public let working: Int
    public let total: Int
    public let failure: String?

    public init(_ host: HerdrHostSnapshot) {
        id = host.id
        name = host.name
        isLocal = host.isLocal
        reachable = host.reachable
        herdrPresent = host.herdrPresent
        working = host.agents.filter { $0.status == .working }.count
        total = host.agents.count
        failure = host.error
    }
}

public struct SessionsSnapshot: Codable, Equatable, Sendable {
    public let discoveredAt: Date
    public let hosts: [SessionsHost]
    public let working: Int
    public let total: Int

    public init(discoveredAt: Date, hosts: [SessionsHost], working: Int, total: Int) {
        self.discoveredAt = discoveredAt
        self.hosts = hosts
        self.working = working
        self.total = total
    }
}

public enum SessionsTally {
    public static func snapshot(
        hosts: [HerdrHostSnapshot], now: Date = Date()
    ) -> SessionsSnapshot {
        let agents = hosts.flatMap(\.agents)
        return SessionsSnapshot(
            discoveredAt: now, hosts: hosts.map(SessionsHost.init),
            working: agents.filter { $0.status == .working }.count, total: agents.count)
    }

    public static func scope(subscribed: Bool, blockAlerts: Bool) -> HerdrCollectScope? {
        if subscribed { return .all }
        return blockAlerts ? .local : nil
    }
}

public final class SessionsJob: @unchecked Sendable {
    private let store: AgentStore?
    private let collect: @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot]
    private let isSubscribed: @Sendable () async -> Bool
    private let defaults: UserDefaults

    public init(
        store: AgentStore?,
        isSubscribed: @escaping @Sendable () async -> Bool,
        defaults: UserDefaults = SharedDefaults.store,
        collect: @escaping @Sendable (HerdrCollectScope) async -> [HerdrHostSnapshot] = {
            await HerdrCollector.collect($0)
        }
    ) {
        self.store = store
        self.isSubscribed = isSubscribed
        self.defaults = defaults
        self.collect = collect
    }

    public func run() async throws -> Data? {
        let blockAlerts = defaults.bool(forKey: AgentSettingsKeys.notifyWhenBlocked)
        guard
            let scope = await SessionsTally.scope(
                subscribed: isSubscribed(), blockAlerts: blockAlerts)
        else { return nil }
        let hosts = await collect(scope)
        let snapshot = SessionsTally.snapshot(hosts: hosts)
        SidebarBadgeStore.recordSessions(working: snapshot.working)
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: SessionsSnapshot) throws {
        guard let store else { return }
        try store.write { database in
            try database.execute(sql: "DELETE FROM session_snapshot")
            for host in snapshot.hosts {
                let payload = try AgentPayload.encode(host)
                try database.execute(
                    sql: """
                        INSERT INTO session_snapshot (id, machine, capturedAt, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [host.id, host.name, snapshot.discoveredAt, payload])
            }
        }
    }
}
