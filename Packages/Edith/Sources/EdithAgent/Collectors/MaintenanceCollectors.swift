import EdithKit
import Foundation

public enum MachineHealthPolicy {
    public static func shouldProbe(
        machineCount: Int, notifyDown: Bool, notifyDiskFull: Bool
    ) -> Bool {
        machineCount > 0 && (notifyDown || notifyDiskFull)
    }

    public static func shouldProbe(defaults: UserDefaults = SharedDefaults.store) -> Bool {
        shouldProbe(
            machineCount: MachineRegistry.machines().count,
            notifyDown: defaults.bool(forKey: AppStorageKeys.Machines.notifyDown),
            notifyDiskFull: defaults.bool(forKey: AppStorageKeys.Machines.notifyDiskFull))
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

public struct MachineHealthJob: Sendable {
    private let store: AgentStore?

    public init(store: AgentStore?) {
        self.store = store
    }

    public func run() async throws -> Data? {
        guard MachineHealthPolicy.shouldProbe() else {
            return try AgentPayload.encode(
                MachineHealthSnapshot(checkedAt: Date(), machines: [], skipped: true))
        }
        let machines = MachineRegistry.machines().map { machine in
            MachineHealthSnapshot.Machine(
                id: machine.id.uuidString, name: machine.name, reachable: true, detail: nil)
        }
        let snapshot = MachineHealthSnapshot(
            checkedAt: Date(), machines: machines, skipped: false)
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: MachineHealthSnapshot) throws {
        guard let store else { return }
        let payload = try AgentPayload.encode(snapshot)
        try store.write { database in
            for machine in snapshot.machines {
                try database.execute(
                    sql: """
                        INSERT INTO machine_metric (machine, capturedAt, payload)
                        VALUES (?, ?, ?)
                        """,
                    arguments: [machine.id, snapshot.checkedAt, payload])
            }
            try database.execute(
                sql: "DELETE FROM machine_metric WHERE capturedAt < ?",
                arguments: [snapshot.checkedAt.addingTimeInterval(-24 * 60 * 60)])
        }
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

public struct UpdateDiscoveryJob: Sendable {
    private let store: AgentStore?
    private let scan: @Sendable () async -> [AppUpdateItem]

    public init(
        store: AgentStore?,
        scan: @escaping @Sendable () async -> [AppUpdateItem] = {
            await AppUpdateDiscovery.discover(
                applications: AppMaintenanceInventory.applications())
        }
    ) {
        self.store = store
        self.scan = scan
    }

    public func run() async throws -> Data? {
        let items = await scan()
        let snapshot = UpdateDiscoverySnapshot(
            checkedAt: Date(), available: items.count,
            sources: Array(Set(items.map { $0.source.rawValue })).sorted())
        SidebarBadgeStore.recordUpdates(available: items.count)
        try? record(snapshot, items: items)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: UpdateDiscoverySnapshot, items: [AppUpdateItem]) throws {
        guard let store else { return }
        try store.write { database in
            try database.execute(sql: "DELETE FROM update_candidate")
            for item in items {
                let payload = try AgentPayload.encode(item)
                try database.execute(
                    sql: """
                        INSERT INTO update_candidate (id, source, checkedAt, payload)
                        VALUES (?, ?, ?, ?)
                        """,
                    arguments: [
                        item.id, item.source.rawValue, snapshot.checkedAt, payload,
                    ])
            }
        }
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

public struct CleanerEstimateJob: Sendable {
    private let store: AgentStore?
    private let scan: @Sendable () -> [JunkCategory]

    public init(
        store: AgentStore?,
        scan: @escaping @Sendable () -> [JunkCategory] = {
            let home = FileManager.default.homeDirectoryForCurrentUser
            return JunkCatalog.entries.compactMap {
                JunkScanner.scanCategory($0, home: home)
            }
        }
    ) {
        self.store = store
        self.scan = scan
    }

    public func run() async throws -> Data? {
        let categories = await Task.detached(priority: .utility) { scan() }.value
        let bytes = categories.flatMap(\.items).reduce(Int64(0)) { $0 + $1.sizeBytes }
        let snapshot = CleanerEstimateSnapshot(
            scannedAt: Date(), reclaimableBytes: bytes, categories: categories.count)
        SidebarBadgeStore.recordReclaimable(bytes: bytes)
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: CleanerEstimateSnapshot) throws {
        guard let store else { return }
        let payload = try AgentPayload.encode(snapshot)
        try store.write { database in
            try database.execute(
                sql: """
                    INSERT INTO cleaner_scan (startedAt, reclaimableBytes, payload)
                    VALUES (?, ?, ?)
                    """,
                arguments: [snapshot.scannedAt, snapshot.reclaimableBytes, payload])
            try database.execute(
                sql: "DELETE FROM cleaner_scan WHERE startedAt < ?",
                arguments: [snapshot.scannedAt.addingTimeInterval(-7 * 24 * 60 * 60)])
        }
    }
}
