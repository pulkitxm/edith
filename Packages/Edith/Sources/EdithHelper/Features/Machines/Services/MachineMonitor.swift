import EdithKit
import Foundation
import UserNotifications

enum MachineAlert: Equatable, Sendable {
    case unreachable(machine: String)
    case recovered(machine: String)
    case diskFull(machine: String, mount: String, percent: Double)
    case filesystemStalled(machine: String, stuckProcesses: Int)

    var identifier: String {
        switch self {
        case let .unreachable(machine), let .recovered(machine):
            return "machine.reachability.\(machine)"
        case let .diskFull(machine, mount, _):
            return "machine.disk.\(machine).\(mount)"
        case let .filesystemStalled(machine, _):
            return "machine.filesystem.\(machine)"
        }
    }

    var title: String {
        switch self {
        case let .unreachable(machine): return "\(machine) is offline"
        case let .recovered(machine): return "\(machine) is back"
        case let .diskFull(machine, _, _): return "\(machine) is running out of space"
        case let .filesystemStalled(machine, _): return "\(machine) has a stalled filesystem"
        }
    }

    var body: String {
        switch self {
        case .unreachable: return "Edith could not reach it over SSH."
        case .recovered: return "The SSH connection works again."
        case let .diskFull(_, mount, percent):
            return String(format: "%@ is %.0f%% full.", mount, percent)
        case let .filesystemStalled(_, stuck):
            let processes = stuck == 1 ? "process is" : "processes are"
            return
                "\(stuck) \(processes) stuck in uninterruptible sleep. They cannot be killed, "
                + "so the machine needs a restart."
        }
    }
}

struct MachineHealth: Equatable, Sendable, Codable {
    var reachable: Bool
    var fullMounts: Set<String>
    var stalledProcesses: Int

    init(reachable: Bool = true, fullMounts: Set<String> = [], stalledProcesses: Int = 0) {
        self.reachable = reachable
        self.fullMounts = fullMounts
        self.stalledProcesses = stalledProcesses
    }
}

enum MachineHealthStore {
    static let defaultsKey = "machinesHealth"

    static func load() -> [UUID: MachineHealth] {
        guard let data = SharedDefaults.store.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode([String: MachineHealth].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    static func save(_ health: [UUID: MachineHealth]) {
        let stored = health.reduce(into: [String: MachineHealth]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        SharedDefaults.store.set(data, forKey: defaultsKey)
    }
}

enum MachineMonitorLogic {
    static func alerts(
        machineName: String, previous: MachineHealth, current: MachineHealth,
        disks: [MachineFilesystem], threshold: Double, notifyDown: Bool, notifyDisk: Bool
    ) -> [MachineAlert] {
        var alerts: [MachineAlert] = []
        if notifyDown, previous.reachable, !current.reachable {
            alerts.append(.unreachable(machine: machineName))
        }
        if notifyDown, !previous.reachable, current.reachable {
            alerts.append(.recovered(machine: machineName))
        }
        guard notifyDisk, current.reachable else { return alerts }
        for mount in current.fullMounts.subtracting(previous.fullMounts).sorted() {
            let percent = disks.first { $0.mount == mount }?.usedPercent ?? threshold
            alerts.append(.diskFull(machine: machineName, mount: mount, percent: percent))
        }
        let stalledLimit = MachineMonitor.stalledProcessThreshold
        if current.stalledProcesses >= stalledLimit, previous.stalledProcesses < stalledLimit {
            alerts.append(
                .filesystemStalled(
                    machine: machineName, stuckProcesses: current.stalledProcesses))
        }
        return alerts
    }

    static func fullMounts(disks: [MachineFilesystem], threshold: Double) -> Set<String> {
        Set(disks.filter { $0.usedPercent >= threshold }.map(\.mount))
    }
}

@MainActor
final class MachineMonitor: FeatureModule {
    private var timer: Timer?
    private var health: [UUID: MachineHealth] = MachineHealthStore.load()
    private var probing = false
    private let store = MachineStore()

    init() {
        startPolling()
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        health = [:]
    }

    private func startPolling() {
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.probe() }
        }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            probe()
        }
    }

    private func probe() {
        guard !probing else { return }
        let machines = store.machines
        guard !machines.isEmpty else { return }
        let notifyDown = AppServices.preferenceOnByDefault(AppStorageKeys.Machines.notifyDown)
        let notifyDisk = AppServices.preferenceOnByDefault(AppStorageKeys.Machines.notifyDiskFull)
        guard notifyDown || notifyDisk else { return }
        let threshold =
            SharedDefaults.store.object(forKey: AppStorageKeys.Machines.diskThreshold) as? Double
            ?? FleetMath.diskWarningPercent
        let known = Set(machines.map(\.id))
        health = health.filter { known.contains($0.key) }
        probing = true
        Task { @MainActor in
            defer { probing = false }
            for machine in machines {
                await probe(
                    machine: machine, threshold: threshold, notifyDown: notifyDown,
                    notifyDisk: notifyDisk)
            }
        }
    }

    private func probe(
        machine: Machine, threshold: Double, notifyDown: Bool, notifyDisk: Bool
    ) async {
        let connection = SSHConnection(machine: machine)
        var current = MachineHealth()
        var disks: [MachineFilesystem] = []
        do {
            try await connection.connect()
            let result = try await connection.run(MachineMonitor.diskCommand, timeout: 30)
            disks = MachineMonitor.parseDisks(result.stdoutText)
            current = MachineHealth(
                reachable: true,
                fullMounts: MachineMonitorLogic.fullMounts(disks: disks, threshold: threshold),
                stalledProcesses: MachineMonitor.parseStalledProcesses(result.stdoutText))
        } catch {
            current = MachineHealth(reachable: false, fullMounts: [])
        }
        await connection.disconnect()
        let previous = health[machine.id] ?? MachineHealth()
        let alerts = MachineMonitorLogic.alerts(
            machineName: machine.name, previous: previous, current: current, disks: disks,
            threshold: threshold, notifyDown: notifyDown, notifyDisk: notifyDisk)
        health[machine.id] = current
        MachineHealthStore.save(health)
        for alert in alerts { MachineMonitor.notify(alert) }
    }

    nonisolated static let mountsMarker = "@@EDITH-MOUNTS@@"
    nonisolated static let stalledMarker = "@@EDITH-STALLED@@"

    nonisolated static let localFilesystemTypes = [
        "ext4", "ext3", "ext2", "xfs", "btrfs", "zfs", "f2fs", "vfat", "exfat", "ntfs",
        "ntfs3", "overlay",
    ]

    nonisolated static let stalledProcessThreshold = 3

    nonisolated static let diskCommand = """
        if [ -r /proc/mounts ]; then
        df -Pk \(localFilesystemTypes.map { "-t \($0)" }.joined(separator: " ")) 2>/dev/null
        else
        df -Pk 2>/dev/null
        fi
        echo '\(mountsMarker)'
        mount 2>/dev/null
        echo '\(stalledMarker)'
        if [ -d /proc ]; then
        awk '{ n = index($0, ") "); if (n > 0 && substr($0, n + 2, 1) == "D") c++ } END { print c + 0 }' /proc/[0-9]*/stat 2>/dev/null
        fi
        """

    nonisolated static func parseStalledProcesses(_ output: String) -> Int {
        let sections = output.components(separatedBy: stalledMarker)
        guard sections.count > 1 else { return 0 }
        for line in sections[1].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let count = Int(text) { return count }
        }
        return 0
    }

    nonisolated static func parseDisks(_ output: String) -> [MachineFilesystem] {
        let sections = output.components(separatedBy: mountsMarker)
        let afterDf = sections.count > 1 ? sections[1] : ""
        let mountText = afterDf.components(separatedBy: stalledMarker)[0]
        let readOnly = sections.count > 1 ? readOnlyMounts(mountText) : []
        return sections[0].split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard parts.count == 6, parts[0].hasPrefix("/"), let total = Int64(parts[1]),
                let used = Int64(parts[2]), let available = Int64(parts[3]), total > 0
            else { return nil }
            let mount = String(parts[5])
            guard !readOnly.contains(mount) else { return nil }
            return MachineFilesystem(
                fs: String(parts[0]), mount: mount, totalKB: total, usedKB: used,
                availKB: available)
        }
    }

    nonisolated static func readOnlyMounts(_ output: String) -> Set<String> {
        var mounts: Set<String> = []
        for line in output.split(separator: "\n") {
            let text = String(line)
            guard let onRange = text.range(of: " on ") else { continue }
            let rest = text[onRange.upperBound...]
            let mountEnd =
                rest.range(of: " type ", options: .backwards)?.lowerBound
                ?? rest.range(of: " (", options: .backwards)?.lowerBound
            guard let mountEnd else { continue }
            guard let open = text.range(of: "(", options: .backwards),
                let close = text.range(of: ")", options: .backwards),
                open.upperBound < close.lowerBound
            else { continue }
            let options = text[open.upperBound..<close.lowerBound]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard options.contains("ro") || options.contains("read-only") else { continue }
            mounts.insert(String(rest[..<mountEnd]))
        }
        return mounts
    }

    nonisolated static func notify(
        _ alert: MachineAlert, center: UNUserNotificationCenter = .current()
    ) {
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default
        center.removeDeliveredNotifications(withIdentifiers: [alert.identifier])
        center.add(
            UNNotificationRequest(identifier: alert.identifier, content: content, trigger: nil)
        ) { error in
            if let error {
                NSLog("Edith machines: alert failed: %@", error.localizedDescription)
            }
        }
    }
}
