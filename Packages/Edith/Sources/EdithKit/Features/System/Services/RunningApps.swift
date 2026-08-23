import AppKit
import Darwin
import EdithCore
import Foundation

public struct RunningAppSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let active: Bool
    public let cpuPercent: Double
    public let memoryMB: Double

    public init(
        pid: pid_t, name: String, bundleID: String?, active: Bool,
        cpuPercent: Double = 0, memoryMB: Double = 0
    ) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.active = active
        self.cpuPercent = cpuPercent
        self.memoryMB = memoryMB
    }
}

public struct RunningAppResourceSample: Equatable, Sendable {
    public let cpuNanoseconds: UInt64
    public let memoryMB: Double

    public init(cpuNanoseconds: UInt64, memoryMB: Double) {
        self.cpuNanoseconds = cpuNanoseconds
        self.memoryMB = memoryMB
    }
}

public struct RunningAppResourceBaseline: Equatable, Sendable {
    public let samples: [pid_t: RunningAppResourceSample]
    public let capturedAt: Date

    public init(samples: [pid_t: RunningAppResourceSample], capturedAt: Date) {
        self.samples = samples
        self.capturedAt = capturedAt
    }
}

public struct RunningAppResourceMeasurement: Equatable, Sendable {
    public let apps: [RunningAppSnapshot]
    public let baseline: RunningAppResourceBaseline

    public init(apps: [RunningAppSnapshot], baseline: RunningAppResourceBaseline) {
        self.apps = apps
        self.baseline = baseline
    }
}

public enum RunningAppSelection: Equatable, Sendable {
    case query(String)
    case pid(pid_t)
    case all
}

public enum RunningAppResolutionError: Error, Equatable, Sendable {
    case notFound(String)
    case ambiguous(String, [String])
    case protected(String)
}

public struct RunningAppQuitPlan: Equatable, Sendable {
    public let selection: RunningAppSelection
    public let targets: [RunningAppSnapshot]
    public let force: Bool

    public init(
        selection: RunningAppSelection, targets: [RunningAppSnapshot], force: Bool
    ) {
        self.selection = selection
        self.targets = targets
        self.force = force
    }
}

public struct RunningAppQuitOutcome: Equatable, Sendable {
    public let plan: RunningAppQuitPlan
    public let applied: Bool
    public let acknowledged: Bool
    public let changed: Int

    public init(
        plan: RunningAppQuitPlan, applied: Bool, acknowledged: Bool? = nil, changed: Int
    ) {
        self.plan = plan
        self.applied = applied
        self.acknowledged = acknowledged ?? applied
        self.changed = changed
    }
}

public enum RunningAppIPC {
    public static let requestIDKey = "requestID"
    public static let pidsKey = "pids"
    public static let forceKey = "force"
    public static let changedKey = "changed"
}

public enum RunningAppOperation: String, CaseIterable, Equatable, Sendable {
    case list
    case quit

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "apps.list"),
                summary: "List the applications running on this Mac.",
                cli: ["apps", "ls"], effect: .read)
        case .quit:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "apps.quit"),
                summary: "Quit one or more running applications.",
                cli: ["apps", "quit"], effect: .destructive, requiresPreview: true)
        }
    }
}

public struct RunningAppOperationCenter: @unchecked Sendable {
    public typealias Snapshot = () -> [RunningAppSnapshot]
    public typealias Perform = ([RunningAppSnapshot], Bool) -> Int
    public typealias Resource = (pid_t) -> RunningAppResourceSample

    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", MainApp.bundleIdentifier, MainApp.statusBarBundleIdentifier,
    ]

    private let snapshot: Snapshot
    private let perform: Perform
    private let resource: Resource

    public init(
        snapshot: @escaping Snapshot = Self.liveSnapshots,
        perform: @escaping Perform = Self.terminate,
        resource: @escaping Resource = Self.liveResource
    ) {
        self.snapshot = snapshot
        self.perform = perform
        self.resource = resource
    }

    public func list() -> [RunningAppSnapshot] {
        snapshot().sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    public func completionValues() -> [String] {
        var seen = Set<String>()
        return list().flatMap { [$0.name, $0.bundleID].compactMap { $0 } }
            .filter { seen.insert($0).inserted }
    }

    public func resourceBaseline(
        for apps: [RunningAppSnapshot], at date: Date = Date()
    ) -> RunningAppResourceBaseline {
        RunningAppResourceBaseline(
            samples: Dictionary(uniqueKeysWithValues: apps.map { ($0.pid, resource($0.pid)) }),
            capturedAt: date)
    }

    public func measureResources(
        for apps: [RunningAppSnapshot], from previous: RunningAppResourceBaseline,
        at date: Date = Date()
    ) -> RunningAppResourceMeasurement {
        let elapsed = max(0, date.timeIntervalSince(previous.capturedAt))
        let current = resourceBaseline(for: apps, at: date)
        let measured = apps.map { app in
            let sample =
                current.samples[app.pid]
                ?? RunningAppResourceSample(cpuNanoseconds: 0, memoryMB: 0)
            let earlier = previous.samples[app.pid]?.cpuNanoseconds ?? sample.cpuNanoseconds
            let delta = sample.cpuNanoseconds >= earlier ? sample.cpuNanoseconds - earlier : 0
            let cpu = elapsed > 0 ? Double(delta) / (elapsed * 1e9) * 100 : 0
            return RunningAppSnapshot(
                pid: app.pid, name: app.name, bundleID: app.bundleID, active: app.active,
                cpuPercent: max(0, cpu), memoryMB: sample.memoryMB)
        }
        return RunningAppResourceMeasurement(apps: measured, baseline: current)
    }

    public func plan(
        _ selection: RunningAppSelection, force: Bool = false
    ) throws -> RunningAppQuitPlan {
        let apps = list()
        let targets: [RunningAppSnapshot]
        switch selection {
        case .all:
            targets = apps.filter { !Self.isProtected($0) }
        case let .pid(pid):
            guard let app = apps.first(where: { $0.pid == pid }) else {
                throw RunningAppResolutionError.notFound(String(pid))
            }
            guard !Self.isProtected(app) else {
                throw RunningAppResolutionError.protected(app.name)
            }
            targets = [app]
        case let .query(query):
            let app = try resolve(query, in: apps)
            guard !Self.isProtected(app) else {
                throw RunningAppResolutionError.protected(app.name)
            }
            targets = [app]
        }
        return RunningAppQuitPlan(selection: selection, targets: targets, force: force)
    }

    public func apply(
        _ plan: RunningAppQuitPlan, confirmed: Bool
    ) -> RunningAppQuitOutcome {
        guard confirmed else {
            return RunningAppQuitOutcome(plan: plan, applied: false, changed: 0)
        }
        let changed = perform(plan.targets, plan.force)
        return RunningAppQuitOutcome(plan: plan, applied: true, changed: changed)
    }

    public func apply(pids: [pid_t], force: Bool) -> RunningAppQuitOutcome {
        let requested = Set(pids)
        let targets = list().filter { requested.contains($0.pid) && !Self.isProtected($0) }
        let plan = RunningAppQuitPlan(selection: .all, targets: targets, force: force)
        return apply(plan, confirmed: true)
    }

    public static func isProtected(_ app: RunningAppSnapshot) -> Bool {
        protectedBundleIDs.contains(app.bundleID ?? "")
    }

    public static func liveSnapshots() -> [RunningAppSnapshot] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular, app.processIdentifier > 0 else { return nil }
            return RunningAppSnapshot(
                pid: app.processIdentifier, name: app.localizedName ?? "Unknown",
                bundleID: app.bundleIdentifier, active: app.isActive)
        }
    }

    public static func liveResource(pid: pid_t) -> RunningAppResourceSample {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard result == 0 else {
            return RunningAppResourceSample(cpuNanoseconds: 0, memoryMB: 0)
        }
        let ticks = info.ri_user_time &+ info.ri_system_time
        let nanos = ticks &* UInt64(timebase.numer) / UInt64(timebase.denom)
        return RunningAppResourceSample(
            cpuNanoseconds: nanos,
            memoryMB: Double(info.ri_phys_footprint) / 1_048_576)
    }

    private static let timebase: mach_timebase_info_data_t = {
        var value = mach_timebase_info_data_t()
        mach_timebase_info(&value)
        return value
    }()

    public static func terminate(_ targets: [RunningAppSnapshot], force: Bool) -> Int {
        targets.reduce(into: 0) { count, target in
            guard !isProtected(target),
                let app = NSRunningApplication(processIdentifier: target.pid)
            else { return }
            let accepted = force ? app.forceTerminate() : app.terminate()
            if accepted { count += 1 }
        }
    }

    private func resolve(
        _ query: String, in apps: [RunningAppSnapshot]
    ) throws -> RunningAppSnapshot {
        let needle = query.lowercased()
        if let exact = apps.first(where: { $0.name.lowercased() == needle }) {
            return exact
        }
        if let bundle = apps.first(where: { ($0.bundleID ?? "").lowercased() == needle }) {
            return bundle
        }
        let prefixed = apps.filter { $0.name.lowercased().hasPrefix(needle) }
        if prefixed.count == 1, let only = prefixed.first { return only }
        if prefixed.count > 1 {
            throw RunningAppResolutionError.ambiguous(query, prefixed.map(\.name))
        }
        throw RunningAppResolutionError.notFound(query)
    }
}
