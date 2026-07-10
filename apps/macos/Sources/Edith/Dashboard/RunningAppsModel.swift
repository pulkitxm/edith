import AppKit
import Darwin

struct RunningAppRow: Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    let icon: NSImage?
    var cpuPercent: Double
    var memoryMB: Double
    var id: pid_t { pid }
}

enum AppSortKey: String {
    case name, cpu, memory
}

@MainActor
final class RunningAppsModel: ObservableObject {
    @Published private(set) var apps: [RunningAppRow] = []
    @Published private(set) var totalMemoryMB: Double = 0
    @Published private(set) var sortKey: AppSortKey = .cpu
    @Published private(set) var ascending = false

    private var lastCPU: [pid_t: (time: UInt64, at: Date)] = [:]

    func sort(by key: AppSortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key == .name
        }
        apps = sorted(apps)
    }

    private func sorted(_ rows: [RunningAppRow]) -> [RunningAppRow] {
        let ordered: [RunningAppRow]
        switch sortKey {
        case .name:
            ordered = rows.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .cpu:
            ordered = rows.sorted { $0.cpuPercent < $1.cpuPercent }
        case .memory:
            ordered = rows.sorted { $0.memoryMB < $1.memoryMB }
        }
        return ascending ? ordered : ordered.reversed()
    }

    func refresh() {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }
        let now = Date()
        var rows: [RunningAppRow] = []
        var seen = Set<pid_t>()
        var memTotal = 0.0
        for app in running {
            let pid = app.processIdentifier
            guard pid > 0 else { continue }
            seen.insert(pid)
            let usage = Self.usage(pid: pid)
            var cpu = 0.0
            if let prev = lastCPU[pid] {
                let dt = now.timeIntervalSince(prev.at)
                if dt > 0 { cpu = Double(usage.cpuNS &- prev.time) / (dt * 1e9) * 100 }
            }
            lastCPU[pid] = (usage.cpuNS, now)
            memTotal += usage.memMB
            rows.append(
                RunningAppRow(
                    pid: pid, name: app.localizedName ?? "Unknown",
                    bundleID: app.bundleIdentifier, icon: app.icon,
                    cpuPercent: max(0, cpu), memoryMB: usage.memMB))
        }
        lastCPU = lastCPU.filter { seen.contains($0.key) }
        totalMemoryMB = memTotal
        apps = sorted(rows)
    }

    static func usage(pid: pid_t) -> (cpuNS: UInt64, memMB: Double) {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else { return (0, 0) }
        return (
            info.ri_user_time &+ info.ri_system_time,
            Double(info.ri_phys_footprint) / 1_048_576
        )
    }

    func quit(_ row: RunningAppRow, force: Bool = false) {
        guard let app = NSRunningApplication(processIdentifier: row.pid) else { return }
        if force { app.forceTerminate() } else { app.terminate() }
    }

    func quitAll(force: Bool = false) {
        let mine = ProcessInfo.processInfo.processIdentifier
        let finder = "com.apple.finder"
        for row in apps where row.pid != mine && row.bundleID != finder {
            quit(row, force: force)
        }
    }
}
