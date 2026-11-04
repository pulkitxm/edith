import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation

@MainActor
@Observable
final class LauncherUsage {
    static let shared = LauncherUsage()
    private static let storageKey = "launcherLastUsed"

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var timestamps: [String: Date]
    @ObservationIgnored private var rankings: [String: LauncherUsageRanking] = [:]

    init(defaults: UserDefaults = SharedDefaults.store) {
        self.defaults = defaults
        timestamps = defaults.dictionary(forKey: Self.storageKey) as? [String: Date] ?? [:]
    }

    func record(_ keys: [[String]], at date: Date = Date()) {
        let stored = defaults.dictionary(forKey: Self.storageKey) as? [String: Date] ?? [:]
        timestamps.merge(stored) { current, other in max(current, other) }
        for key in keys { timestamps[LauncherUsageHistory.encoded(key)] = date }
        defaults.set(timestamps, forKey: Self.storageKey)
        for (prefix, ranking) in rankings {
            ranking.adopt(history(withPrefix: prefix))
        }
    }

    func ordered<Item>(_ items: [Item], by key: (Item) -> [String]) -> [Item] {
        guard let category = items.first.map(key)?.first else { return items }
        return ranking(category).history.ordered(items, by: key)
    }

    private func ranking(_ category: String) -> LauncherUsageRanking {
        let prefix = LauncherUsageHistory.encoded([category])
        if let ranking = rankings[prefix] { return ranking }
        let ranking = LauncherUsageRanking(history(withPrefix: prefix))
        rankings[prefix] = ranking
        return ranking
    }

    private func history(withPrefix prefix: String) -> LauncherUsageHistory {
        LauncherUsageHistory(timestamps: timestamps.filter { $0.key.hasPrefix(prefix) })
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

@MainActor
@Observable
final class LauncherUsageRanking {
    private(set) var history: LauncherUsageHistory

    init(_ history: LauncherUsageHistory) {
        self.history = history
    }

    func adopt(_ next: LauncherUsageHistory) {
        if next.rank != history.rank { history = next }
    }
}

struct LauncherUsageHistory: Sendable {
    fileprivate var timestamps: [String: Date]

    var rank: [String] {
        timestamps.sorted { lhs, rhs in
            lhs.value == rhs.value ? lhs.key < rhs.key : lhs.value > rhs.value
        }.map(\.key)
    }

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
