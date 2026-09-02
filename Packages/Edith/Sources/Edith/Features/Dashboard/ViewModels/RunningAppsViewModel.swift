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
    private(set) var loaded = false
    private(set) var refreshing = false

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

    func refresh() async {
        refreshing = true
        defer {
            refreshing = false
            loaded = true
        }
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
