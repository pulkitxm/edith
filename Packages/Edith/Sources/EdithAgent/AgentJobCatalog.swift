import EdithKit
import Foundation

public enum AgentJobCatalog {
    public static func descriptors() -> [AgentJobDescriptor] {
        AgentJobPlan.descriptors
    }

    public static func jobs(store: AgentStore?, scheduler: JobScheduler? = nil) -> [AgentJob] {
        let bodies = collectors(store: store, scheduler: scheduler)
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
        store: AgentStore?, scheduler: JobScheduler? = nil
    ) -> [String: @Sendable () async throws -> Data?] {
        let usage = UsageCollectorJob(store: store)
        let machines = MachineHealthJob(store: store)
        let updates = UpdateDiscoveryJob(store: store)
        let cleaner = CleanerEstimateJob(store: store)
        let backup = BackupJob(store: store)
        let downloads = DownloadQueueJob(store: store)
        let siteAudit = SiteAuditJob(store: store)
        let sessions = SessionsJob(store: store) {
            guard let scheduler else { return false }
            return await scheduler.subscriberCount(topic: .sessions) > 0
        }
        return [
            "usage.refresh": { try await usage.run() },
            "machines.health": { try await machines.run() },
            "updates.discover": { try await updates.run() },
            "cleaner.estimate": { try await cleaner.run() },
            "backup.sync": { try await backup.run() },
            "downloads.queue": { try await downloads.run() },
            "sessions.discover": { try await sessions.run() },
            "siteAudit.crawl": { try await siteAudit.run() },
        ]
    }

    static func isEnabled(_ descriptor: AgentJobDescriptor) -> Bool {
        guard let abilityID = descriptor.abilityID else { return true }
        guard let entry = ExtensionRegistry.entry(abilityID) else { return true }
        return entry.isEnabled(in: SharedDefaults.store)
    }
}
