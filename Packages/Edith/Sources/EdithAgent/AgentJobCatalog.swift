import EdithKit
import Foundation

public enum AgentJobCatalog {
    public static func descriptors() -> [AgentJobDescriptor] {
        AgentJobPlan.descriptors
    }

    public static func jobs(
        store: AgentStore?, scheduler: JobScheduler? = nil, downloads: DownloadWorker? = nil,
        metrics: AgentMachineMetricsService? = nil, attention: AttentionBackgroundService? = nil
    ) -> [AgentJob] {
        let bodies = collectors(
            store: store, scheduler: scheduler, downloads: downloads, metrics: metrics,
            attention: attention)
        return descriptors().map { descriptor in
            let empty: @Sendable () async throws -> Data? = { nil }
            let body = bodies[descriptor.id] ?? empty
            return AgentJob(
                descriptor: descriptor,
                isEnabled: { isEnabled(descriptor) },
                run: body)
        }
    }

    static func collectors(
        store: AgentStore?, scheduler: JobScheduler? = nil, downloads: DownloadWorker? = nil,
        metrics: AgentMachineMetricsService? = nil, attention: AttentionBackgroundService? = nil
    ) -> [String: @Sendable () async throws -> Data?] {
        let limits = LimitsCollectorJob()
        let usage = UsageCollectorJob(store: store)
        let machines = MachineHealthJob(store: store)
        let updates = UpdateDiscoveryJob(store: store)
        let cleaner = CleanerEstimateJob(store: store)
        let backup = BackupJob(store: store)
        let companion = CompanionHealthJob(store: store)
        let sessions = SessionsJob(store: store) {
            guard let scheduler else { return false }
            return await scheduler.subscriberCount(topic: .sessions) > 0
        }
        return [
            "usage.refresh": { try await usage.run() },
            "usage.limits": { try await limits.run() },
            "machines.health": { try await machines.run() },
            "machines.metrics": {
                guard let metrics else {
                    throw AgentError(.unavailable, "Machine metrics are unavailable.")
                }
                return try await metrics.snapshotData()
            },
            "updates.discover": { try await updates.run() },
            "cleaner.estimate": { try await cleaner.run() },
            "backup.sync": { try await backup.run() },
            "downloads.queue": {
                guard let downloads else {
                    throw AgentError(.unavailable, "The download worker is unavailable.")
                }
                await downloads.refresh()
                return try await AgentPayload.encode(downloads.snapshot())
            },
            "sessions.discover": { try await sessions.run() },
            "attention.ingest": {
                guard let attention else {
                    throw AgentError(.unavailable, "Attention storage is unavailable.")
                }
                return try await attention.run()
            },
            "companion.health": { try await companion.run() },
        ]
    }

    static func isEnabled(_ descriptor: AgentJobDescriptor) -> Bool {
        guard let abilityID = descriptor.abilityID else { return true }
        guard let entry = ExtensionRegistry.entry(abilityID) else { return true }
        return entry.isEnabled(in: SharedDefaults.store)
    }
}
