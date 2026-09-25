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

public struct MachineHealthJob: Sendable {
    private let store: AgentStore?
    private let monitor: MachineHealthMonitor

    public init(store: AgentStore?, monitor: MachineHealthMonitor = MachineHealthMonitor()) {
        self.store = store
        self.monitor = monitor
    }

    public func run() async throws -> Data? {
        let snapshot = await monitor.run()
        try? record(snapshot)
        return try AgentPayload.encode(snapshot)
    }

    private func record(_ snapshot: MachineHealthSnapshot) throws {
        guard let store, !snapshot.skipped else { return }
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
