import EdithKit
import Foundation

public struct MachineHealthPolicySettings: Equatable, Sendable {
    public let notifyDown: Bool
    public let notifyDiskFull: Bool
    public let diskThreshold: Double

    public init(notifyDown: Bool, notifyDiskFull: Bool, diskThreshold: Double) {
        self.notifyDown = notifyDown
        self.notifyDiskFull = notifyDiskFull
        self.diskThreshold = diskThreshold
    }

    public static func current(
        defaults: UserDefaults = SharedDefaults.store
    ) -> MachineHealthPolicySettings {
        MachineHealthPolicySettings(
            notifyDown: defaults.object(forKey: AppStorageKeys.Machines.notifyDown) as? Bool
                ?? true,
            notifyDiskFull: defaults.object(forKey: AppStorageKeys.Machines.notifyDiskFull)
                as? Bool ?? true,
            diskThreshold: defaults.object(forKey: AppStorageKeys.Machines.diskThreshold)
                as? Double ?? FleetMath.diskWarningPercent)
    }
}

public final class MachineHealthMonitor: @unchecked Sendable {
    public typealias Probe =
        @Sendable (Machine, Double) async -> (
            health: MachineHealth, disks: [MachineFilesystem], failure: String?
        )

    private let machines: @Sendable () -> [Machine]
    private let settings: @Sendable () -> MachineHealthPolicySettings
    private let probe: Probe
    private let notify: @Sendable (MachineAlert) -> Void
    private let load: @Sendable () -> [UUID: MachineHealth]
    private let save: @Sendable ([UUID: MachineHealth]) -> Void

    public init(
        machines: @escaping @Sendable () -> [Machine] = { MachineRegistry.machines() },
        settings: @escaping @Sendable () -> MachineHealthPolicySettings = {
            MachineHealthPolicySettings.current()
        },
        probe: @escaping Probe = { machine, threshold in
            await MachineHealthProbe.probe(machine: machine, threshold: threshold)
        },
        notify: @escaping @Sendable (MachineAlert) -> Void = { AgentNotifier.shared.send($0) },
        load: @escaping @Sendable () -> [UUID: MachineHealth] = { MachineHealthStore.load() },
        save: @escaping @Sendable ([UUID: MachineHealth]) -> Void = { MachineHealthStore.save($0) }
    ) {
        self.machines = machines
        self.settings = settings
        self.probe = probe
        self.notify = notify
        self.load = load
        self.save = save
    }

    public func run() async -> MachineHealthSnapshot {
        let now = Date()
        let configured = machines()
        guard !configured.isEmpty else {
            return MachineHealthSnapshot(checkedAt: now, machines: [], skipped: true)
        }
        let policy = settings()
        let known = Set(configured.map(\.id))
        var stored = load().filter { known.contains($0.key) }
        var rows: [MachineHealthSnapshot.Machine] = []
        for machine in configured {
            let outcome = await probe(machine, policy.diskThreshold)
            let previous = stored[machine.id] ?? MachineHealth()
            let alerts = MachineMonitorLogic.alerts(
                machineName: machine.name, previous: previous, current: outcome.health,
                disks: outcome.disks, threshold: policy.diskThreshold,
                notifyDown: policy.notifyDown, notifyDisk: policy.notifyDiskFull)
            stored[machine.id] = outcome.health
            for alert in alerts { notify(alert) }
            rows.append(
                MachineHealthSnapshot.Machine(
                    id: machine.id.uuidString, name: machine.name,
                    reachable: outcome.health.reachable, detail: outcome.failure))
        }
        save(stored)
        return MachineHealthSnapshot(checkedAt: now, machines: rows, skipped: false)
    }
}
