import Foundation

struct CleanerCategoryRow: Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let itemCount: Int
    let sizeText: String
    let expanded: Bool
}

struct CleanerItemRow: Equatable, Sendable {
    let id: String
    let categoryID: String
    let name: String
    let path: URL
    let sizeText: String
    let ageText: String?
    let branch: String?
    let badges: [String]
}

struct CleanerRow: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case category(CleanerCategoryRow)
        case itemFilter(categoryID: String, count: Int)
        case item(CleanerItemRow)
        case divider
    }

    let id: String
    let kind: Kind
}

final class CleanerSizeText {
    private var cache: [Int64: String] = [:]

    func callAsFunction(_ bytes: Int64) -> String {
        if let cached = cache[bytes] { return cached }
        if cache.count >= 50_000 { cache.removeAll(keepingCapacity: true) }
        let text = JunkScanner.format(bytes)
        cache[bytes] = text
        return text
    }
}

struct CleanerListState: Equatable, Sendable {
    var visibleCategories: [JunkCategory] = []
    var rows: [CleanerRow] = []
    var matchesSearch = true
    var totalItemCount = 0
    var hiddenItemCount = 0
    var reclaimableTotal: Int64 = 0

    static let itemFilterThreshold = 10

    init() {}

    init(
        categories: [JunkCategory], filters: CleanerFilters, search: String,
        expanded: Set<String>, itemFilters: [String: String], now: Date,
        sizeText: CleanerSizeText = CleanerSizeText()
    ) {
        reclaimableTotal = JunkScanner.uniqueBytes(categories.flatMap(\.items))
        visibleCategories = filters.apply(categories, now: now)
        let allCount = categories.reduce(0) { $0 + $1.items.count }
        totalItemCount = visibleCategories.reduce(0) { $0 + $1.items.count }
        hiddenItemCount = allCount - totalItemCount
        let displayed = Self.searched(visibleCategories, query: search)
        matchesSearch = !displayed.isEmpty
        rows = Self.rows(
            displayed, expanded: expanded,
            itemFilters: itemFilters, now: now, sizeText: sizeText)
    }

    static func searched(_ categories: [JunkCategory], query raw: String) -> [JunkCategory] {
        guard !raw.isEmpty else { return categories }
        let query = raw.lowercased()
        return categories.compactMap { category in
            if category.name.lowercased().contains(query) { return category }
            let items = category.items.filter {
                $0.name.lowercased().contains(query)
                    || $0.worktree?.branch?.lowercased().contains(query) == true
            }
            guard !items.isEmpty else { return nil }
            var trimmed = category
            trimmed.items = items
            return trimmed
        }
    }

    private static func rows(
        _ categories: [JunkCategory], expanded: Set<String>, itemFilters: [String: String],
        now: Date,
        sizeText: CleanerSizeText
    ) -> [CleanerRow] {
        var rows: [CleanerRow] = []
        rows.reserveCapacity(categories.count * 2)
        for category in categories {
            let isExpanded = expanded.contains(category.id)
            rows.append(
                CleanerRow(
                    id: "category\u{0}" + category.id,
                    kind: .category(
                        CleanerCategoryRow(
                            id: category.id, name: category.name, detail: category.detail,
                            itemCount: category.items.count,
                            sizeText: sizeText(category.sizeBytes), expanded: isExpanded))))
            if isExpanded {
                if category.items.count > itemFilterThreshold {
                    rows.append(
                        CleanerRow(
                            id: "filter\u{0}" + category.id,
                            kind: .itemFilter(
                                categoryID: category.id, count: category.items.count)))
                }
                let query = itemFilters[category.id]?.lowercased() ?? ""
                for item in category.items
                where query.isEmpty || item.name.lowercased().contains(query) {
                    rows.append(
                        CleanerRow(
                            id: "item\u{0}" + category.id + "\u{0}" + item.id,
                            kind: .item(
                                Self.item(
                                    item, categoryID: category.id, now: now,
                                    sizeText: sizeText))))
                }
            }
            rows.append(CleanerRow(id: "divider\u{0}" + category.id, kind: .divider))
        }
        return rows
    }

    private static func item(
        _ item: JunkItem, categoryID: String, now: Date, sizeText: CleanerSizeText
    ) -> CleanerItemRow {
        CleanerItemRow(
            id: item.id, categoryID: categoryID, name: item.name, path: item.path,
            sizeText: sizeText(item.sizeBytes),
            ageText: CleanerAgeText.since(item.lastModified, now: now),
            branch: item.worktree.map { $0.branch ?? "detached" },
            badges: item.worktree.map(badges) ?? [])
    }

    static func badges(_ worktree: WorktreeInfo) -> [String] {
        var badges: [String] = []
        if worktree.dirty == true { badges.append("UNCOMMITTED") }
        if let unpushed = worktree.unpushed, unpushed > 0 { badges.append("\(unpushed) UNPUSHED") }
        if worktree.merged {
            badges.append("MERGED")
        } else if worktree.upstreamGone {
            badges.append("UPSTREAM GONE")
        }
        if worktree.locked { badges.append("LOCKED") }
        return badges
    }
}
