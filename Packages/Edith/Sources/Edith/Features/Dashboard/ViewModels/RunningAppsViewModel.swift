import AppKit
import EdithKit
import Observation

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
@Observable
final class RunningAppsModel {
    private(set) var apps: [RunningAppRow] = []
    private(set) var totalMemoryMB: Double = 0
    private(set) var sortKey: AppSortKey = .cpu
    private(set) var ascending = false

    private var resourceBaseline: RunningAppResourceBaseline?
    private let operations = RunningAppOperationCenter()

    var quitAllTargetCount: Int {
        apps.filter { !RunningAppOperationCenter.protectedBundleIDs.contains($0.bundleID ?? "") }
            .count
    }

    func canQuit(_ row: RunningAppRow) -> Bool {
        !RunningAppOperationCenter.protectedBundleIDs.contains(row.bundleID ?? "")
    }

    init() {
        let d = SharedDefaults.store
        if let raw = d.string(forKey: "systemAppsSort"), let key = AppSortKey(rawValue: raw) {
            sortKey = key
        }
        if d.object(forKey: "systemAppsSortAsc") != nil {
            ascending = d.bool(forKey: "systemAppsSortAsc")
        }
    }

    func sort(by key: AppSortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key == .name
        }
        let d = SharedDefaults.store
        d.set(sortKey.rawValue, forKey: "systemAppsSort")
        d.set(ascending, forKey: "systemAppsSortAsc")
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

    func refresh() async {
        var icons: [pid_t: NSImage] = [:]
        let snapshots = operations.list()
        let operations = self.operations
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier > 0 {
            icons[app.processIdentifier] = app.icon
        }
        let previous = resourceBaseline
        let now = Date()
        let measured = await Task.detached(priority: .utility) {
            let baseline = previous ?? operations.resourceBaseline(for: snapshots, at: now)
            return operations.measureResources(for: snapshots, from: baseline, at: now)
        }.value
        resourceBaseline = measured.baseline
        totalMemoryMB = measured.apps.reduce(0) { $0 + $1.memoryMB }
        apps = sorted(
            measured.apps.map { app in
                RunningAppRow(
                    pid: app.pid, name: app.name, bundleID: app.bundleID,
                    icon: icons[app.pid], cpuPercent: app.cpuPercent, memoryMB: app.memoryMB)
            })
    }

    func quit(_ row: RunningAppRow, force: Bool = false) {
        guard let plan = try? operations.plan(.pid(row.pid), force: force) else { return }
        _ = operations.apply(plan, confirmed: true)
    }

    func quitAll(force: Bool = false) {
        guard let plan = try? operations.plan(.all, force: force) else { return }
        _ = operations.apply(plan, confirmed: true)
    }
}
