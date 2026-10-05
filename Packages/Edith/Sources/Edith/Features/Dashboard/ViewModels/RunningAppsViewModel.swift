import AppKit
import EdithKit
import Observation

@Observable
final class RunningAppRow: Identifiable {
    let pid: pid_t
    var name: String
    let bundleID: String?
    var icon: NSImage?
    var cpuPercent: Double
    var memoryMB: Double
    var id: pid_t { pid }

    init(
        pid: pid_t, name: String, bundleID: String?, icon: NSImage?, cpuPercent: Double,
        memoryMB: Double
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.icon = icon
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
    }
}

enum AppSortKey: String {
    case name, cpu, memory
}

enum RunningAppActionStatus: Equatable {
    case planRejected(RunningAppResolutionError)
    case planningFailed(String)
    case rejected(name: String?, requested: Int, force: Bool)
    case partial(changed: Int, requested: Int, force: Bool)
    case accepted(name: String?, changed: Int, requested: Int, force: Bool)

    var message: String {
        switch self {
        case .planRejected(.notFound(let query)):
            return "\(query) is no longer running. Refresh the list and try again."
        case .planRejected(.ambiguous(let query, let matches)):
            return
                "\(query) matches \(matches.joined(separator: ", ")). Choose one app and try again."
        case .planRejected(.protected(let name)):
            return "\(name) stays open because Edith protects essential apps."
        case .planningFailed(let detail):
            return "The quit request could not be prepared: \(detail)"
        case .rejected(let name, let requested, let force):
            if let name {
                return
                    "\(name) did not accept the \(force ? "force-quit" : "quit") request. Resolve any open dialogs and try again."
            }
            return
                "None of the \(requested) apps accepted the \(force ? "force-quit" : "quit") request. Resolve open dialogs and try again."
        case .partial(let changed, let requested, let force):
            return
                "\(changed) of \(requested) apps accepted the \(force ? "force-quit" : "quit") request. Resolve open dialogs in the remaining apps and retry."
        case .accepted(let name, let changed, let requested, let force):
            if requested == 0 { return "No quit-eligible apps are running." }
            if let name {
                return "\(name) accepted the \(force ? "force-quit" : "quit") request."
            }
            return "\(changed) apps accepted the \(force ? "force-quit" : "quit") request."
        }
    }
}

@MainActor
@Observable
final class RunningAppsModel {
    private(set) var apps: [RunningAppRow] = []
    private(set) var totalMemoryMB: Double = 0
    private(set) var sortKey: AppSortKey = .cpu
    private(set) var ascending = false
    private(set) var actionStatus: RunningAppActionStatus?
    let loading = ContentLoad()
    var loaded: Bool { loading.hasContent }
    var refreshing: Bool { loading.isRunning }
    private(set) var scrolling = false

    private var resourceBaseline: RunningAppResourceBaseline?
    private let operations: RunningAppOperationCenter

    var quitAllTargetCount: Int {
        apps.filter { !RunningAppOperationCenter.protectedBundleIDs.contains($0.bundleID ?? "") }
            .count
    }

    func canQuit(_ row: RunningAppRow) -> Bool {
        !RunningAppOperationCenter.protectedBundleIDs.contains(row.bundleID ?? "")
    }

    init(operations: RunningAppOperationCenter = RunningAppOperationCenter()) {
        self.operations = operations
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

    func setScrolling(_ value: Bool) {
        if scrolling != value { scrolling = value }
    }

    func refresh() async {
        let operations = self.operations
        let previous = resourceBaseline
        let now = Date()
        await loading.perform(operation: {
            let snapshots = operations.list()
            let baseline = previous ?? operations.resourceBaseline(for: snapshots, at: now)
            let sample = operations.measureResources(for: snapshots, from: baseline, at: now)
            return (sample, Self.icons(for: sample.apps))
        }) { measured in
            resourceBaseline = measured.0.baseline
            publish(measured.0.apps, icons: measured.1)
        }
    }

    private func publish(_ snapshots: [RunningAppSnapshot], icons: [pid_t: NSImage]) {
        var existing: [pid_t: RunningAppRow] = [:]
        for row in apps { existing[row.pid] = row }
        var next: [RunningAppRow] = []
        next.reserveCapacity(snapshots.count)
        var memory = 0.0
        for snapshot in snapshots {
            let row =
                existing[snapshot.pid]
                ?? RunningAppRow(
                    pid: snapshot.pid, name: snapshot.name, bundleID: snapshot.bundleID,
                    icon: icons[snapshot.pid], cpuPercent: snapshot.cpuPercent,
                    memoryMB: snapshot.memoryMB)
            row.name = snapshot.name
            row.cpuPercent = snapshot.cpuPercent
            row.memoryMB = snapshot.memoryMB
            if let icon = icons[snapshot.pid] { row.icon = icon }
            memory += snapshot.memoryMB
            next.append(row)
        }
        totalMemoryMB = memory
        apps = sorted(next)
    }

    nonisolated private static func icons(for apps: [RunningAppSnapshot]) -> [pid_t: NSImage] {
        var wanted: Set<pid_t> = []
        for app in apps { wanted.insert(app.pid) }
        var icons: [pid_t: NSImage] = [:]
        for application in NSWorkspace.shared.runningApplications {
            let pid = application.processIdentifier
            guard pid > 0, wanted.contains(pid), let icon = application.icon else { continue }
            icons[pid] = icon
        }
        return icons
    }

    func quit(_ row: RunningAppRow, force: Bool = false) {
        do {
            let plan = try operations.plan(.pid(row.pid), force: force)
            record(operations.apply(plan, confirmed: true), name: row.name)
        } catch let error as RunningAppResolutionError {
            actionStatus = .planRejected(error)
        } catch {
            actionStatus = .planningFailed(error.localizedDescription)
        }
    }

    func quitAll(force: Bool = false) {
        do {
            let plan = try operations.plan(.all, force: force)
            record(operations.apply(plan, confirmed: true), name: nil)
        } catch let error as RunningAppResolutionError {
            actionStatus = .planRejected(error)
        } catch {
            actionStatus = .planningFailed(error.localizedDescription)
        }
    }

    func clearActionStatus() {
        actionStatus = nil
    }

    private func record(_ outcome: RunningAppQuitOutcome, name: String?) {
        let requested = outcome.plan.targets.count
        if requested == 0 || outcome.changed == requested {
            actionStatus = .accepted(
                name: name, changed: outcome.changed, requested: requested,
                force: outcome.plan.force)
        } else if outcome.changed == 0 {
            actionStatus = .rejected(
                name: name, requested: requested, force: outcome.plan.force)
        } else {
            actionStatus = .partial(
                changed: outcome.changed, requested: requested, force: outcome.plan.force)
        }
    }
}
