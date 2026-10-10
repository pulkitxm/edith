import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import Observation

enum RunningAppsKeys {
    static let sort = "systemAppsSort"
    static let ascending = "systemAppsSortAsc"
}

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

    private var engineClient: ExtensionEngineClient?
    private var presentation: SystemPresentationState?
    private var remoteTasks: [UUID: Task<Void, Never>] = [:]
    private var stopped = false
    private var resourceBaseline: RunningAppResourceBaseline?
    private let operations: RunningAppOperationCenter
    private let defaults: UserDefaults

    var quitAllTargetCount: Int {
        apps.filter { !RunningAppOperationCenter.isProtected(bundleID: $0.bundleID) }
            .count
    }

    func canQuit(_ row: RunningAppRow) -> Bool {
        !RunningAppOperationCenter.isProtected(bundleID: row.bundleID)
    }

    init(
        operations: RunningAppOperationCenter = RunningAppOperationCenter(),
        defaults: UserDefaults = SharedDefaults.store
    ) {
        self.operations = operations
        self.defaults = defaults
        let d = defaults
        if let raw = d.string(forKey: RunningAppsKeys.sort), let key = AppSortKey(rawValue: raw) {
            sortKey = key
        }
        if d.object(forKey: RunningAppsKeys.ascending) != nil {
            ascending = d.bool(forKey: RunningAppsKeys.ascending)
        }
    }

    convenience init(
        engineClient: ExtensionEngineClient, presentation: SystemPresentationState,
        defaults: UserDefaults
    ) {
        self.init(
            operations: RunningAppOperationCenter(
                snapshot: { [] }, perform: { _, _ in 0 },
                resource: { _ in .init(cpuNanoseconds: 0, memoryMB: 0) }), defaults: defaults)
        self.engineClient = engineClient
        self.presentation = presentation
    }

    func snapshot(presentation: SystemPresentationState) -> SystemAppsSnapshot {
        SystemAppsSnapshot(
            apps: apps.map {
                RunningAppSnapshot(
                    pid: $0.pid, name: $0.name, bundleID: $0.bundleID, active: false,
                    cpuPercent: $0.cpuPercent, memoryMB: $0.memoryMB)
            },
            icons: Dictionary(
                uniqueKeysWithValues: apps.compactMap { row in
                    row.icon?.tiffRepresentation.map { (String(row.pid), $0) }
                }),
            sortKey: sortKey.rawValue, ascending: ascending, hideApps: presentation.hideApps)
    }

    func restoreSort(_ sort: SystemAppsSort) {
        guard let key = AppSortKey(rawValue: sort.sortKey), !stopped else { return }
        sortKey = key; ascending = sort.ascending
        apps = sorted(apps)
    }

    func sort(by key: AppSortKey) {
        if sortKey == key {
            ascending.toggle()
        } else {
            sortKey = key
            ascending = key == .name
        }
        if let engineClient {
            let sortKey = sortKey.rawValue
            let ascending = ascending
            launchRemote {
                let payload = try JSONEncoder().encode(
                    SystemAppsSort(sortKey: sortKey, ascending: ascending))
                _ = try await engineClient.invoke("system.apps.sort", payload: payload)
            }
            apps = sorted(apps)
            return
        }
        let d = defaults
        d.set(sortKey.rawValue, forKey: RunningAppsKeys.sort)
        d.set(ascending, forKey: RunningAppsKeys.ascending)
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
        guard !stopped else { return }
        if let engineClient {
            await loading.perform(operation: {
                let data = try await engineClient.invoke("system.apps.snapshot")
                return try JSONDecoder().decode(SystemAppsSnapshot.self, from: data)
            }) { snapshot in
                guard !stopped else { return }
                sortKey = AppSortKey(rawValue: snapshot.sortKey) ?? .cpu
                ascending = snapshot.ascending
                presentation?.apply(hideApps: snapshot.hideApps)
                publish(
                    snapshot.apps,
                    icons: snapshot.icons.reduce(into: [:]) { result, pair in
                        if let pid = Int32(pair.key), let image = NSImage(data: pair.value) {
                            result[pid] = image
                        }
                    })
            }
            return
        }
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

    func shutdown() {
        stopped = true
        for task in remoteTasks.values { task.cancel() }
        remoteTasks.removeAll()
        loading.cancel()
        resourceBaseline = nil
        apps = []
        totalMemoryMB = 0
        actionStatus = nil
        scrolling = false
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
        guard !stopped else { return }
        if engineClient != nil {
            remoteQuit(
                input: ["pid": Int(row.pid), "force": force, "confirmed": true], name: row.name,
                force: force)
            return
        }
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
        guard !stopped else { return }
        if engineClient != nil {
            remoteQuit(
                input: ["all": true, "force": force, "confirmed": true], name: nil, force: force)
            return
        }
        do {
            let plan = try operations.plan(.all, force: force)
            record(operations.apply(plan, confirmed: true), name: nil)
        } catch let error as RunningAppResolutionError {
            actionStatus = .planRejected(error)
        } catch {
            actionStatus = .planningFailed(error.localizedDescription)
        }
    }

    private func remoteQuit(input: [String: Any], name: String?, force: Bool) {
        guard let engineClient, let payload = try? JSONSerialization.data(withJSONObject: input)
        else { return }
        launchRemote {
            let data = try await engineClient.invoke("apps.quit", payload: payload)
            let result = try JSONDecoder().decode(SystemAppsQuitReply.self, from: data)
            guard !self.stopped else { return }
            let plan = RunningAppQuitPlan(selection: .all, targets: result.targets, force: force)
            self.record(
                RunningAppQuitOutcome(plan: plan, applied: result.applied, changed: result.changed),
                name: name)
        }
    }

    private func launchRemote(_ operation: @escaping @MainActor () async throws -> Void) {
        let id = UUID()
        remoteTasks[id] = Task {
            defer { remoteTasks[id] = nil }
            do { try await operation() } catch is CancellationError {} catch {
                guard !stopped else { return }
                actionStatus = .planningFailed(error.localizedDescription)
            }
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
