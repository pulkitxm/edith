import Foundation

public enum MachineAlert: Equatable, Sendable {
    case unreachable(machine: String)
    case recovered(machine: String)
    case diskFull(machine: String, mount: String, percent: Double)
    case filesystemStalled(machine: String, stuckProcesses: Int)

    public var identifier: String {
        switch self {
        case let .unreachable(machine), let .recovered(machine):
            return "machine.reachability.\(machine)"
        case let .diskFull(machine, mount, _):
            return "machine.disk.\(machine).\(mount)"
        case let .filesystemStalled(machine, _):
            return "machine.filesystem.\(machine)"
        }
    }

    public var title: String {
        switch self {
        case let .unreachable(machine): return "\(machine) is offline"
        case let .recovered(machine): return "\(machine) is back"
        case let .diskFull(machine, _, _): return "\(machine) is running out of space"
        case let .filesystemStalled(machine, _): return "\(machine) has a stalled filesystem"
        }
    }

    public var body: String {
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

public struct MachineHealth: Equatable, Sendable, Codable {
    public var reachable: Bool
    public var fullMounts: Set<String>
    public var stalledProcesses: Int

    public init(
        reachable: Bool = true, fullMounts: Set<String> = [], stalledProcesses: Int = 0
    ) {
        self.reachable = reachable
        self.fullMounts = fullMounts
        self.stalledProcesses = stalledProcesses
    }
}

public enum MachineHealthStore {
    public static let defaultsKey = "machinesHealth"

    public static func load() -> [UUID: MachineHealth] {
        guard let data = SharedDefaults.store.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode([String: MachineHealth].self, from: data)
        else { return [:] }
        return stored.reduce(into: [:]) { result, entry in
            guard let id = UUID(uuidString: entry.key) else { return }
            result[id] = entry.value
        }
    }

    public static func save(_ health: [UUID: MachineHealth]) {
        let stored = health.reduce(into: [String: MachineHealth]()) { result, entry in
            result[entry.key.uuidString] = entry.value
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        SharedDefaults.store.set(data, forKey: defaultsKey)
    }
}

public enum MachineMonitorLogic {
    public static func alerts(
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
        let stalledLimit = MachineHealthProbe.stalledProcessThreshold
        if current.stalledProcesses >= stalledLimit, previous.stalledProcesses < stalledLimit {
            alerts.append(
                .filesystemStalled(
                    machine: machineName, stuckProcesses: current.stalledProcesses))
        }
        return alerts
    }

    public static func fullMounts(disks: [MachineFilesystem], threshold: Double) -> Set<String> {
        Set(disks.filter { $0.usedPercent >= threshold }.map(\.mount))
    }
}

public enum MachineHealthProbe {
    public static let mountsMarker = "@@EDITH-MOUNTS@@"
    public static let stalledMarker = "@@EDITH-STALLED@@"
    public static let localFilesystemTypes = [
        "ext4", "ext3", "ext2", "xfs", "btrfs", "zfs", "f2fs", "vfat", "exfat", "ntfs",
        "ntfs3", "overlay",
    ]
    public static let stalledProcessThreshold = 3
    public static let diskCommand = """
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
    public static func parseStalledProcesses(_ output: String) -> Int {
        let sections = output.components(separatedBy: stalledMarker)
        guard sections.count > 1 else { return 0 }
        for line in sections[1].split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if let count = Int(text) { return count }
        }
        return 0
    }
    public static func parseDisks(_ output: String) -> [MachineFilesystem] {
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
    public static func readOnlyMounts(_ output: String) -> Set<String> {
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

    public static func probe(
        machine: Machine, threshold: Double, timeout: TimeInterval = 30
    ) async -> (health: MachineHealth, disks: [MachineFilesystem], failure: String?) {
        let connection = SSHConnection(machine: machine)
        defer { Task { await connection.disconnect() } }
        do {
            try await connection.connect()
            let result = try await connection.run(diskCommand, timeout: timeout)
            let disks = parseDisks(result.stdoutText)
            let health = MachineHealth(
                reachable: true,
                fullMounts: MachineMonitorLogic.fullMounts(disks: disks, threshold: threshold),
                stalledProcesses: parseStalledProcesses(result.stdoutText))
            return (health, disks, nil)
        } catch {
            return (MachineHealth(reachable: false, fullMounts: []), [], error.localizedDescription)
        }
    }
}
