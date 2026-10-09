import EdithExtensionUI
import EdithExtensionSupport
import Foundation

public struct CompanionHealthJob: Sendable {
    private let isConfigured: @Sendable () -> Bool
    private let probe: @Sendable (URL) async throws -> CompanionHealth
    private let endpoint: @Sendable () -> URL
    private let repair: @Sendable (URL) async -> Bool
    private let deliverOutbox: @Sendable (URL) async -> Void

    public init(
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
        self.isConfigured = isConfigured
        self.endpoint = endpoint
        self.probe = probe
        self.repair = repair
        self.deliverOutbox = deliverOutbox
    }

    public func run() async -> CompanionHealthSnapshot {
        let checkedAt = Date()
        guard isConfigured() else { return .unconfigured(at: checkedAt) }
        let url = endpoint()
        do {
            let health: CompanionHealth
            do {
                health = try await probe(url)
            } catch {
                try Task.checkCancellation()
                guard await repair(url) else { throw error }
                health = try await probe(url)
            }
            if health.ok, !Task.isCancelled { await deliverOutbox(url) }
            return CompanionHealthSnapshot(
                checkedAt: checkedAt, endpoint: url.absoluteString, reachable: health.ok,
                degraded: health.degraded ?? false,
                checks: health.checks.map {
                    CompanionHealthSnapshot.Check(name: $0.name, ok: $0.ok, detail: $0.detail)
                },
                failure: nil, skipped: false)
        } catch {
            return CompanionHealthSnapshot(
                checkedAt: checkedAt, endpoint: url.absoluteString, reachable: false,
                degraded: false, checks: [],
                failure: Task.isCancelled
                    ? "The health check was cancelled."
                    : error
                        .localizedDescription,
                skipped: false)
        }
    }
}
