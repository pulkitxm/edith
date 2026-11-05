import EdithHostCore
import Foundation

struct HostMarketplaceSuite: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    var defaultsKey: String { "suite" + id.capitalized + "Enabled" }
}

enum HostMarketplaceCatalog {
    static let suites: [HostMarketplaceSuite] = [
        .init(
            id: "agents", title: "Agents & Terminal",
            subtitle: "Run and review coding agents, track their limits, and reach your machines.",
            symbol: "sparkles"),
        .init(
            id: "utilities", title: "Mac Utilities",
            subtitle: "Updates, disk cleanup, sleep control, menu bar stats and your calendar.",
            symbol: "switch.2"),
        .init(
            id: "desk", title: "Desk",
            subtitle: "Hotkey tools: the launcher, clipboard, pickers, the notch and focus.",
            symbol: "hand.tap"),
        .init(
            id: "media", title: "Media",
            subtitle: "Edit files, record your screen, style your camera, play and save media.",
            symbol: "play.rectangle.on.rectangle"),
        .init(
            id: "developer", title: "Developer & Data",
            subtitle: "Databases, code growth, site audits, LaTeX and where your time goes.",
            symbol: "cylinder.split.1x2"),
        .init(
            id: "labs", title: "Labs",
            subtitle: "Experiments and visual toys. Hidden from the main list.",
            symbol: "flask"),
    ]
    static let hiddenByDefault: Set<String> = ["labs"]
    static let featuredIDs = [
        "usage", "herdr", "bifrost", "clipboard", "studio", "timeLapse", "music", "appMaintenance",
    ]
    static let featuredLimit = 4

    static func suite(for entry: HostExtension) -> HostMarketplaceSuite? {
        suites.first { $0.id == entry.category }
    }

    static func tagline(_ entry: HostExtension) -> String {
        if let tagline = entry.guide?.tagline, !tagline.isEmpty { return tagline }
        return suite(for: entry).map { "Part of \($0.title)" } ?? entry.title
    }

    static func providers(_ entries: [HostExtension] = (try? HostIndex.bundled()) ?? []) -> [String:
        Set<
            String
        >]
    {
        Dictionary(grouping: entries, by: \.category).mapValues { Set($0.map(\.id)) }
    }
    static func matches(_ entry: HostExtension, query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return entry.title.localizedCaseInsensitiveContains(query)
            || tagline(entry).localizedCaseInsensitiveContains(query)
            || (entry.guide?.summary ?? "").localizedCaseInsensitiveContains(query)
    }

    static func filter(
        _ entries: [HostExtension], query: String, category: String,
        scope: HostMarketplaceScope = .all, installed: Set<String> = [],
        updatable: Set<String> = []
    ) -> [HostExtension] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let searching = !trimmed.isEmpty
        let matched = entries.filter { entry in
            let inCategory =
                searching
                || (category == "all"
                    ? (scope != .all || !hiddenByDefault.contains(entry.category))
                    : entry.category == category)
            let inScope =
                switch scope {
                case .all: true
                case .installed: installed.contains(entry.id)
                case .updates: updatable.contains(entry.id)
                }
            return inCategory && inScope && matches(entry, query: query)
        }
        guard searching else { return matched }
        return matched.enumerated().sorted { left, right in
            let leftRank = relevance(left.element, query: trimmed)
            let rightRank = relevance(right.element, query: trimmed)
            return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
        }.map(\.element)
    }

    static func relevance(_ entry: HostExtension, query: String) -> Int {
        if entry.title.compare(query, options: [.caseInsensitive, .diacriticInsensitive])
            == .orderedSame
        {
            return 0
        }
        if entry.title.localizedCaseInsensitiveContains(query) { return 1 }
        if tagline(entry).localizedCaseInsensitiveContains(query) { return 2 }
        return 3
    }

    static func featured(_ entries: [HostExtension], installed: Set<String>) -> [HostExtension] {
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        return Array(
            featuredIDs.compactMap { byID[$0] }.filter { !installed.contains($0.id) }
                .prefix(featuredLimit))
    }

    static func groups(_ entries: [HostExtension]) -> [(
        suite: HostMarketplaceSuite, entries: [HostExtension]
    )] {
        suites.compactMap { suite in
            let members = entries.filter { $0.category == suite.id }
            return members.isEmpty ? nil : (suite, members)
        }
    }
}

enum HostMarketplaceScope: String, CaseIterable, Hashable {
    case all, installed, updates

    var title: String {
        switch self {
        case .all: "Browse"
        case .installed: "Installed"
        case .updates: "Updates"
        }
    }
}
