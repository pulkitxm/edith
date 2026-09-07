import EdithKit
import Foundation

public struct CompanionHealthJob: Sendable {
    private let store: AgentStore?
    private let isConfigured: @Sendable () -> Bool
    private let probe: @Sendable (URL) async throws -> CompanionHealth
    private let endpoint: @Sendable () -> URL
    private let repair: @Sendable (URL) async -> Bool
    private let deliverOutbox: @Sendable (URL) async -> Void

    public init(
        store: AgentStore?,
        isConfigured: @escaping @Sendable () -> Bool = {
            CompanionClient.hasConfiguredEndpointOrDeployment()
        },
        endpoint: @escaping @Sendable () -> URL = { CompanionClient.endpoint(override: nil) },
        probe: @escaping @Sendable (URL) async throws -> CompanionHealth = { url in
            try await CompanionClient(baseURL: url).health()
        },
        repair: @escaping @Sendable (URL) async -> Bool = { url in
            guard let deployment = CompanionDeploymentStore.load(),
                deployment.machineID != nil,
                ["localhost", "127.0.0.1", "::1"].contains(url.host ?? ""),
                url.port == deployment.localPort
            else { return false }
            return await CompanionTunnel.ensure(deployment)
        },
        deliverOutbox: @escaping @Sendable (URL) async -> Void = { url in
            await CompanionOutboxDelivery.shared.enqueue(endpoint: url)
        }
    ) {
        self.store = store
        self.isConfigured = isConfigured
        self.endpoint = endpoint
        self.probe = probe
        self.repair = repair
        self.deliverOutbox = deliverOutbox
    }

    public func run() async throws -> Data? {
        let checkedAt = Date()
        guard isConfigured() else {
            return try AgentPayload.encode(CompanionHealthSnapshot.unconfigured(at: checkedAt))
        }
        let url = endpoint()
        let snapshot: CompanionHealthSnapshot
        do {
            let health: CompanionHealth
            do {
                health = try await probe(url)
            } catch {
                try Task.checkCancellation()
                guard await repair(url) else { throw error }
                health = try await probe(url)
            }
            snapshot = CompanionHealthSnapshot(
                checkedAt: checkedAt, endpoint: url.absoluteString, reachable: health.ok,
                degraded: health.degraded ?? false,
                checks: health.checks.map {
                    CompanionHealthSnapshot.Check(name: $0.name, ok: $0.ok, detail: $0.detail)
                },
                failure: nil, skipped: false)
            if health.ok, !Task.isCancelled { await deliverOutbox(url) }
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
