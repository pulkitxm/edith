import AppKit
import EdithCore
import Foundation

public struct RunningAppSnapshot: Equatable, Sendable {
    public let pid: pid_t
    public let name: String
    public let bundleID: String?
    public let active: Bool

    public init(pid: pid_t, name: String, bundleID: String?, active: Bool) {
        self.pid = pid
        self.name = name
        self.bundleID = bundleID
        self.active = active
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
    public let changed: Int

    public init(plan: RunningAppQuitPlan, applied: Bool, changed: Int) {
        self.plan = plan
        self.applied = applied
        self.changed = changed
    }
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

public struct RunningAppOperationCenter {
    public typealias Snapshot = () -> [RunningAppSnapshot]
    public typealias Perform = ([RunningAppSnapshot], Bool) -> Int

    public static let protectedBundleIDs: Set<String> = [
        "com.apple.finder", MainApp.bundleIdentifier, MainApp.statusBarBundleIdentifier,
    ]

    private let snapshot: Snapshot
    private let perform: Perform

    public init(
        snapshot: @escaping Snapshot = Self.liveSnapshots,
        perform: @escaping Perform = Self.terminate
    ) {
        self.snapshot = snapshot
        self.perform = perform
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
