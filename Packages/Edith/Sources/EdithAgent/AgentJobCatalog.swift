import EdithKit
import Foundation

public enum AgentJobCatalog {
    public static func descriptors() -> [AgentJobDescriptor] {
        [
            AgentJobDescriptor(
                id: "usage.refresh", title: "Usage cost refresh", trigger: .fileSystem,
                topic: .usage, cadence: .every(ambient: 900), power: .any, abilityID: "usage"),
            AgentJobDescriptor(
                id: "usage.limits", title: "Agent rate limits", trigger: .timer, topic: .limits,
                cadence: .every(ambient: 900, live: 300), power: .any, abilityID: "usage"),
            AgentJobDescriptor(
                id: "sessions.discover", title: "Herdr session discovery", trigger: .subscription,
                topic: .sessions, cadence: .every(live: 2), power: .pauseOnLock,
                abilityID: "herdr"),
            AgentJobDescriptor(
                id: "machines.health", title: "Machine health probe", trigger: .timer,
                topic: .machines, cadence: .every(ambient: 300), power: .any),
            AgentJobDescriptor(
                id: "machines.metrics", title: "Machine metrics stream", trigger: .subscription,
                topic: .machineMetrics, cadence: .every(live: 5), power: .any),
            AgentJobDescriptor(
                id: "updates.discover", title: "Update discovery", trigger: .timer,
                topic: .updates, cadence: .every(ambient: 21_600), power: .pauseOnBattery,
                abilityID: "appMaintenance"),
            AgentJobDescriptor(
                id: "cleaner.estimate", title: "Weekly cleaner estimate", trigger: .timer,
                topic: .cleaner, cadence: .every(ambient: 604_800), power: .pauseOnBattery,
                abilityID: "cleaner"),
            AgentJobDescriptor(
                id: "downloads.queue", title: "Download queue", trigger: .queue,
                topic: .downloads, cadence: .onDemand, power: .any, abilityID: "downloads"),
            AgentJobDescriptor(
                id: "attention.ingest", title: "Attention ingestion", trigger: .subscription,
                topic: .attention, cadence: .onDemand, power: .pauseOnLock,
                abilityID: "attention"),
            AgentJobDescriptor(
                id: "companion.health", title: "Memory health", trigger: .timer,
                topic: .companion, cadence: .every(ambient: 60, live: 20), power: .any,
                abilityID: "companion"),
            AgentJobDescriptor(
                id: "siteAudit.crawl", title: "Site audit crawl", trigger: .queue,
                topic: .siteAudit, cadence: .onDemand, power: .any, abilityID: "seoAudit"),
            AgentJobDescriptor(
                id: "backup.sync", title: "iCloud backup", trigger: .fileSystem, topic: .backup,
                cadence: .every(ambient: 86_400), power: .pauseOnBattery),
        ]
    }

    public static func jobs(store: AgentStore?) -> [AgentJob] {
        let bodies = collectors(store: store)
        return descriptors().map { descriptor in
            let empty: @Sendable () async throws -> Data? = { nil }
            let body = bodies[descriptor.id] ?? empty
            return AgentJob(
                descriptor: descriptor,
                isEnabled: { isEnabled(descriptor) },
                run: body)
        }
    }

    static func collectors(store: AgentStore?) -> [String: @Sendable () async throws -> Data?] {
        let usage = UsageCollectorJob(store: store)
        let machines = MachineHealthJob(store: store)
        let updates = UpdateDiscoveryJob(store: store)
        let cleaner = CleanerEstimateJob(store: store)
        let backup = BackupJob(store: store)
        return [
            "usage.refresh": { try await usage.run() },
            "machines.health": { try await machines.run() },
            "updates.discover": { try await updates.run() },
            "cleaner.estimate": { try await cleaner.run() },
            "backup.sync": { try await backup.run() },
        ]
    }

    static func isEnabled(_ descriptor: AgentJobDescriptor) -> Bool {
        guard let abilityID = descriptor.abilityID else { return true }
        guard let entry = ExtensionRegistry.entry(abilityID) else { return true }
        return entry.isEnabled(in: SharedDefaults.store)
    }
}
