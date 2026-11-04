import Foundation

struct CleanerCategoryRow: Equatable, Sendable {
    let id: String
    let name: String
    let detail: String
    let itemCount: Int
    let sizeText: String
    let selection: JunkSelection
    let selectedCount: Int
    let selectedBytes: Int64
    let expanded: Bool
}

struct CleanerItemRow: Equatable, Sendable {
    let id: String
    let categoryID: String
    let name: String
    let path: URL
    let selected: Bool
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

struct CleanerCategorySelection: Equatable, Sendable {
    var count = 0
    var bytes: Int64 = 0
}

struct CleanerListState: Equatable, Sendable {
    var visibleCategories: [JunkCategory] = []
    var rows: [CleanerRow] = []
    var matchesSearch = true
    var totalItemCount = 0
    var hiddenItemCount = 0
    var selectedItemCount = 0
    var selectedTotal: Int64 = 0
    var reclaimableTotal: Int64 = 0
    var selectionByCategory: [String: CleanerCategorySelection] = [:]

    var overallSelection: JunkSelection {
        guard totalItemCount > 0, selectedItemCount > 0 else { return .none }
        return selectedItemCount == totalItemCount ? .all : .some
    }

    static let itemFilterThreshold = 10

    init() {}

    init(
        categories: [JunkCategory], filters: CleanerFilters, search: String,
        expanded: Set<String>, itemFilters: [String: String], now: Date
    ) {
        reclaimableTotal = JunkScanner.uniqueBytes(categories.flatMap(\.items))
        visibleCategories = filters.apply(categories, now: now)
        let allCount = categories.reduce(0) { $0 + $1.items.count }
        totalItemCount = visibleCategories.reduce(0) { $0 + $1.items.count }
        hiddenItemCount = allCount - totalItemCount
        let selected = CleanerOperationExecution.selectedItems(in: visibleCategories)
        selectedItemCount = selected.count
        selectedTotal = selected.reduce(0) { $0 + $1.sizeBytes }
        for category in visibleCategories {
            let chosen = JunkScanner.outermost(category.items.filter(\.selected))
            selectionByCategory[category.id] = CleanerCategorySelection(
                count: chosen.count, bytes: chosen.reduce(0) { $0 + $1.sizeBytes })
        }
        let displayed = Self.searched(visibleCategories, query: search)
        matchesSearch = !displayed.isEmpty
        rows = Self.rows(
            displayed, selection: selectionByCategory, expanded: expanded,
            itemFilters: itemFilters, now: now)
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
        _ categories: [JunkCategory], selection: [String: CleanerCategorySelection],
        expanded: Set<String>, itemFilters: [String: String], now: Date
    ) -> [CleanerRow] {
        var rows: [CleanerRow] = []
        rows.reserveCapacity(categories.count * 2)
        for category in categories {
            let isExpanded = expanded.contains(category.id)
            let chosen = selection[category.id] ?? CleanerCategorySelection()
            rows.append(
                CleanerRow(
                    id: "category\u{0}" + category.id,
                    kind: .category(
                        CleanerCategoryRow(
                            id: category.id, name: category.name, detail: category.detail,
                            itemCount: category.items.count,
                            sizeText: JunkScanner.format(category.sizeBytes),
                            selection: category.selection, selectedCount: chosen.count,
                            selectedBytes: chosen.bytes, expanded: isExpanded))))
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
                            kind: .item(Self.item(item, categoryID: category.id, now: now))))
                }
            }
            rows.append(CleanerRow(id: "divider\u{0}" + category.id, kind: .divider))
        }
        return rows
    }

    private static func item(_ item: JunkItem, categoryID: String, now: Date) -> CleanerItemRow {
        CleanerItemRow(
            id: item.id, categoryID: categoryID, name: item.name, path: item.path,
            selected: item.selected, sizeText: JunkScanner.format(item.sizeBytes),
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
