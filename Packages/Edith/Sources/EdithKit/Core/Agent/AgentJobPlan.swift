import Foundation

public enum AgentJobPlan {
    public static let descriptors: [AgentJobDescriptor] = [
        AgentJobDescriptor(
            id: "usage.refresh", title: "Usage cost refresh", trigger: .fileSystem,
            topic: .usage, cadence: .every(ambient: 900), power: .any, abilityID: "usage"),
        AgentJobDescriptor(
            id: "usage.limits", title: "Agent rate limits", trigger: .timer, topic: .limits,
            cadence: .every(ambient: 900, live: 300), power: .any, abilityID: "usage"),
        AgentJobDescriptor(
            id: "sessions.discover", title: "Herdr session discovery", trigger: .subscription,
            topic: .sessions, cadence: .every(ambient: 30, live: 2), power: .pauseOnLock,
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
            id: "attention.ingest", title: "Attention ingestion", trigger: .timer,
            topic: .attention, cadence: .every(ambient: 900, live: 900), power: .pauseOnLock,
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
