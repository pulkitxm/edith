import EdithKit
import Foundation

public struct CompanionHealthSnapshot: Codable, Equatable, Sendable {
    public struct Check: Codable, Equatable, Sendable {
        public let name: String
        public let ok: Bool
        public let detail: String

        public init(name: String, ok: Bool, detail: String) {
            self.name = name
            self.ok = ok
            self.detail = detail
        }
    }

    public let checkedAt: Date
    public let endpoint: String
    public let reachable: Bool
    public let degraded: Bool
    public let checks: [Check]
    public let failure: String?
    public let skipped: Bool

    public init(
        checkedAt: Date, endpoint: String, reachable: Bool, degraded: Bool, checks: [Check],
        failure: String?, skipped: Bool
    ) {
        self.checkedAt = checkedAt
        self.endpoint = endpoint
        self.reachable = reachable
        self.degraded = degraded
        self.checks = checks
        self.failure = failure
        self.skipped = skipped
    }

    public static func unconfigured(at date: Date) -> CompanionHealthSnapshot {
        CompanionHealthSnapshot(
            checkedAt: date, endpoint: "", reachable: false, degraded: false, checks: [],
            failure: nil, skipped: true)
    }
}

public struct CompanionHealthJob: Sendable {
    private let store: AgentStore?
    private let isConfigured: @Sendable () -> Bool
    private let probe: @Sendable (URL) async throws -> CompanionHealth
    private let endpoint: @Sendable () -> URL

    public init(
        store: AgentStore?,
        isConfigured: @escaping @Sendable () -> Bool = {
            CompanionClient.hasConfiguredEndpointOrDeployment()
        },
        endpoint: @escaping @Sendable () -> URL = { CompanionClient.endpoint(override: nil) },
        probe: @escaping @Sendable (URL) async throws -> CompanionHealth = { url in
            try await CompanionClient(baseURL: url).health()
        }
    ) {
        self.store = store
        self.isConfigured = isConfigured
        self.endpoint = endpoint
        self.probe = probe
    }

    public func run() async throws -> Data? {
        let checkedAt = Date()
        guard isConfigured() else {
            return try AgentPayload.encode(CompanionHealthSnapshot.unconfigured(at: checkedAt))
        }
        let url = endpoint()
        let snapshot: CompanionHealthSnapshot
        do {
            let health = try await probe(url)
            snapshot = CompanionHealthSnapshot(
                checkedAt: checkedAt, endpoint: url.absoluteString, reachable: health.ok,
                degraded: health.degraded ?? false,
                checks: health.checks.map {
                    CompanionHealthSnapshot.Check(name: $0.name, ok: $0.ok, detail: $0.detail)
                },
                failure: nil, skipped: false)
        } catch {
            snapshot = CompanionHealthSnapshot(
                checkedAt: checkedAt, endpoint: url.absoluteString, reachable: false,
                degraded: false, checks: [], failure: error.localizedDescription,
                skipped: false)
        }
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: CompanionHealthSnapshot) throws {
        guard let store, !snapshot.skipped else { return }
        let payload = try AgentPayload.encode(snapshot)
        try store.write { database in
            try database.execute(
                sql: """
                    INSERT INTO companion_health (checkedAt, reachable, payload)
                    VALUES (?, ?, ?)
                    """,
                arguments: [snapshot.checkedAt, snapshot.reachable, payload])
            try database.execute(
                sql: "DELETE FROM companion_health WHERE checkedAt < ?",
                arguments: [snapshot.checkedAt.addingTimeInterval(-7 * 24 * 60 * 60)])
        }
    }
}
