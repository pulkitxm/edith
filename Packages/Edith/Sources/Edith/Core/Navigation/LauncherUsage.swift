import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class LauncherUsage {
    static let shared = LauncherUsage()
    private static let storageKey = "launcherLastUsed"

    private let defaults: UserDefaults
    private(set) var history: LauncherUsageHistory

    init(defaults: UserDefaults = SharedDefaults.store) {
        self.defaults = defaults
        history = LauncherUsageHistory(
            timestamps: defaults.dictionary(forKey: Self.storageKey) as? [String: Date] ?? [:])
    }

    func record(_ keys: [[String]], at date: Date = Date()) {
        for key in keys { history.timestamps[LauncherUsageHistory.encoded(key)] = date }
        defaults.set(history.timestamps, forKey: Self.storageKey)
    }

    func lastUsed(_ key: [String]) -> Date {
        history.lastUsed(key)
    }

    func ordered<Item>(_ items: [Item], by key: (Item) -> [String]) -> [Item] {
        history.ordered(items, by: key)
    }

    func ordered<Item>(_ items: [Item], date: (Item) -> Date) -> [Item] {
        history.ordered(items, date: date)
    }

    func record(_ agent: HerdrAgent, at date: Date = Date()) {
        var keys = [["machine", agent.machineID]]
        if !agent.isTerminal {
            keys += [
                ["kind", agent.kind], ["agent", agent.id],
                ["space", agent.machineID, agent.workspace],
            ]
        }
        record(keys, at: date)
    }
}

struct LauncherUsageHistory: Sendable {
    fileprivate var timestamps: [String: Date]

    func lastUsed(_ key: [String]) -> Date {
        timestamps[Self.encoded(key)] ?? .distantPast
    }

    func ordered<Item>(_ items: [Item], by key: (Item) -> [String]) -> [Item] {
        ordered(items, date: { lastUsed(key($0)) })
    }

    func ordered<Item>(_ items: [Item], date: (Item) -> Date) -> [Item] {
        let ranked = items.enumerated().map { entry in
            (offset: entry.offset, item: entry.element, date: date(entry.element))
        }
        let ordered = ranked.sorted { lhs, rhs in
            if lhs.date == rhs.date { return lhs.offset < rhs.offset }
            return lhs.date > rhs.date
        }
        return ordered.map { $0.item }
    }

    func projects(_ projects: [QuinjetProject], machineID: String) -> [QuinjetProject] {
        let orderedProjects = projects.map { project in
            QuinjetProject(
                name: project.name, commonDir: project.commonDir,
                worktrees: ordered(project.worktrees) { ["worktree", machineID, $0.path] })
        }
        return ordered(
            orderedProjects,
            date: { project in
                project.worktrees.map { lastUsed(["worktree", machineID, $0.path]) }.max()
                    ?? .distantPast
            })
    }

    fileprivate static func encoded(_ key: [String]) -> String {
        key.map { "\($0.utf8.count):\($0)" }.joined()
    }
}
