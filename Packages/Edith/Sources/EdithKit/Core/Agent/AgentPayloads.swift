import Foundation

public struct UsageTopicSnapshot: Codable, Equatable, Sendable {
    public let refreshedAt: Date
    public let seconds: Double
    public let days: Int
    public let totalCostCents: Int
    public let failure: String?

    public init(
        refreshedAt: Date, seconds: Double, days: Int, totalCostCents: Int, failure: String?
    ) {
        self.refreshedAt = refreshedAt
        self.seconds = seconds
        self.days = days
        self.totalCostCents = totalCostCents
        self.failure = failure
    }
}

public struct MachineHealthSnapshot: Codable, Equatable, Sendable {
    public struct Machine: Codable, Equatable, Sendable {
        public let id: String
        public let name: String
        public let reachable: Bool
        public let detail: String?

        public init(id: String, name: String, reachable: Bool, detail: String?) {
            self.id = id
            self.name = name
            self.reachable = reachable
            self.detail = detail
        }
    }

    public let checkedAt: Date
    public let machines: [Machine]
    public let skipped: Bool

    public init(checkedAt: Date, machines: [Machine], skipped: Bool) {
        self.checkedAt = checkedAt
        self.machines = machines
        self.skipped = skipped
    }
}

public struct UpdateDiscoverySnapshot: Codable, Equatable, Sendable {
    public let checkedAt: Date
    public let available: Int
    public let sources: [String]

    public init(checkedAt: Date, available: Int, sources: [String]) {
        self.checkedAt = checkedAt
        self.available = available
        self.sources = sources
    }
}

public struct CleanerEstimateSnapshot: Codable, Equatable, Sendable {
    public let scannedAt: Date
    public let reclaimableBytes: Int64
    public let categories: Int

    public init(scannedAt: Date, reclaimableBytes: Int64, categories: Int) {
        self.scannedAt = scannedAt
        self.reclaimableBytes = reclaimableBytes
        self.categories = categories
    }
}

public struct DownloadQueueTopicSnapshot: Codable, Equatable, Sendable {
    public let readAt: Date
    public let queued: Int
    public let running: Int
    public let finished: Int
    public let failed: Int

    public init(readAt: Date, queued: Int, running: Int, finished: Int, failed: Int) {
        self.readAt = readAt
        self.queued = queued
        self.running = running
        self.finished = finished
        self.failed = failed
    }

    public var pending: Int { queued + running }
}

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
    public let hosts: [HerdrHostSnapshot]
    public let working: Int
    public let total: Int

    public init(discoveredAt: Date, hosts: [HerdrHostSnapshot], working: Int, total: Int) {
        self.discoveredAt = discoveredAt
        self.hosts = hosts
        self.working = working
        self.total = total
    }

    public var summaries: [SessionsHost] { hosts.map(SessionsHost.init) }
}

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

public struct SiteAuditSnapshot: Codable, Equatable, Sendable {
    public let startedAt: Date
    public let requested: Int
    public let audited: Int
    public let concurrency: Int
    public let failure: String?

    public init(
        startedAt: Date, requested: Int, audited: Int, concurrency: Int, failure: String?
    ) {
        self.startedAt = startedAt
        self.requested = requested
        self.audited = audited
        self.concurrency = concurrency
        self.failure = failure
    }
}

public struct SiteAuditRequest: Codable, Equatable, Sendable {
    public let urls: [URL]
    public let lighthouse: Bool

    public init(urls: [URL], lighthouse: Bool = false) {
        self.urls = urls
        self.lighthouse = lighthouse
    }
}

public struct BackupSnapshotResult: Codable, Equatable, Sendable {
    public let ranAt: Date
    public let classes: [String]
    public let snapshotTables: [String]
    public let skipped: Bool

    public init(ranAt: Date, classes: [String], snapshotTables: [String], skipped: Bool) {
        self.ranAt = ranAt
        self.classes = classes
        self.snapshotTables = snapshotTables
        self.skipped = skipped
    }
}
