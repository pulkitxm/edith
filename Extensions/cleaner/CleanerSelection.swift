import Foundation

struct CleanerCategoryChoice: Codable, Equatable, Sendable {
    var selected: Bool
    var exceptions: Set<String> = []

    func includes(_ itemID: String) -> Bool { selected != exceptions.contains(itemID) }

    mutating func set(_ itemID: String, to value: Bool) {
        if value == selected {
            exceptions.remove(itemID)
        } else {
            exceptions.insert(itemID)
        }
    }

    static func derived(from items: [JunkItem]) -> Self {
        let marked = items.reduce(0) { $1.selected ? $0 + 1 : $0 }
        let selected = marked * 2 > items.count
        return Self(
            selected: selected,
            exceptions: Set(items.lazy.filter { $0.selected != selected }.map(\.id)))
    }
}

struct CleanerSelection: Codable, Equatable, Sendable {
    var choices: [String: CleanerCategoryChoice] = [:]

    func includes(_ itemID: String, categoryID: String) -> Bool {
        choices[categoryID]?.includes(itemID) ?? false
    }

    static func resolve(
        _ categories: [JunkCategory], stored: [String: CleanerCategoryChoice]
    ) -> Self {
        var choices: [String: CleanerCategoryChoice] = [:]
        for category in categories {
            if var choice = stored[category.id] {
                if !choice.exceptions.isEmpty {
                    choice.exceptions.formIntersection(category.items.lazy.map(\.id))
                }
                choices[category.id] = choice
            } else {
                choices[category.id] = .derived(from: category.items)
            }
        }
        return Self(choices: choices)
    }

    func applied(to categories: [JunkCategory]) -> [JunkCategory] {
        categories.map { category in
            var marked = category
            let choice = choices[category.id]
            for position in marked.items.indices {
                marked.items[position].selected =
                    choice?.includes(marked.items[position].id) ?? false
            }
            return marked
        }
    }
}

struct CleanerCategoryStats: Equatable, Sendable {
    var itemCount = 0
    var markedCount = 0
    var selectedCount = 0
    var selectedBytes: Int64 = 0

    var selection: JunkSelection {
        if markedCount == 0 { return .none }
        return markedCount == itemCount ? .all : .some
    }
}

struct CleanerSelectionStats: Equatable, Sendable {
    var categories: [String: CleanerCategoryStats] = [:]
    var itemCount = 0
    var markedCount = 0
    var selectedCount = 0
    var selectedBytes: Int64 = 0

    var selection: JunkSelection {
        guard itemCount > 0, markedCount > 0 else { return .none }
        return markedCount == itemCount ? .all : .some
    }
}

struct CleanerSelectionScope {
    let categoryID: String
    let positions: [Int]
    let whole: Bool
}

struct CleanerSelectionIndex {
    private(set) var ids: [String] = []
    private(set) var marked: [Bool] = []
    private var totals = CleanerCategoryStats()
    private var perCategory: [CleanerCategoryStats] = []
    private var sizes: [Int64] = []
    private var owners: [Int] = []
    private var names: [String] = []
    private var branches: [String?] = []
    private var categoryIDs: [String] = []
    private var categoryNames: [String] = []
    private var ranges: [Range<Int>] = []
    private var narrowed: [Bool] = []
    private var positions: [[String: Int]] = []
    private var categoryPositions: [String: Int] = [:]
    private var outerAncestors: [[Int]] = []
    private var innerAncestors: [[Int]] = []
    private var descendants: [[Int]] = []
    private var scopedQuery: String?
    private var scoped: [CleanerSelectionScope] = []

    init() {}

    init(visible: [JunkCategory], all: [JunkCategory], selection: CleanerSelection) {
        let totals = Dictionary(all.map { ($0.id, $0.items.count) }, uniquingKeysWith: +)
        let count = visible.reduce(0) { $0 + $1.items.count }
        ids.reserveCapacity(count)
        sizes.reserveCapacity(count)
        owners.reserveCapacity(count)
        names.reserveCapacity(count)
        branches.reserveCapacity(count)
        var paths: [Substring: [Int]] = [:]
        var standardPaths: [Substring] = []
        standardPaths.reserveCapacity(count)
        for (owner, category) in visible.enumerated() {
            let start = ids.count
            var lookup: [String: Int] = [:]
            lookup.reserveCapacity(category.items.count)
            for item in category.items {
                let position = ids.count
                lookup[item.id] = position
                ids.append(item.id)
                sizes.append(item.sizeBytes)
                owners.append(owner)
                names.append(item.name.lowercased())
                branches.append(item.worktree?.branch?.lowercased())
                let path = Substring(item.standardPath)
                standardPaths.append(path)
                paths[path, default: []].append(position)
            }
            categoryPositions[category.id] = owner
            categoryIDs.append(category.id)
            categoryNames.append(category.name.lowercased())
            ranges.append(start..<ids.count)
            narrowed.append(totals[category.id, default: 0] > category.items.count)
            positions.append(lookup)
        }
        outerAncestors = Array(repeating: [], count: count)
        innerAncestors = Array(repeating: [], count: count)
        descendants = Array(repeating: [], count: count)
        for (position, path) in standardPaths.enumerated() {
            var current = path
            var outer: [Int] = []
            while let slash = current.lastIndex(of: "/"), slash != current.startIndex {
                current = current[..<slash]
                if let ancestors = paths[current] { outer.append(contentsOf: ancestors) }
            }
            guard !outer.isEmpty else { continue }
            outerAncestors[position] = outer
            innerAncestors[position] = outer.filter { owners[$0] == owners[position] }
            for ancestor in outer { descendants[ancestor].append(position) }
        }
        reload(selection)
    }

    mutating func reload(_ selection: CleanerSelection) {
        marked = ids.indices.map {
            selection.includes(ids[$0], categoryID: categoryIDs[owners[$0]])
        }
        recount()
    }

    var stats: CleanerSelectionStats {
        CleanerSelectionStats(
            categories: Dictionary(
                zip(categoryIDs, perCategory), uniquingKeysWith: { first, _ in first }),
            itemCount: totals.itemCount, markedCount: totals.markedCount,
            selectedCount: totals.selectedCount, selectedBytes: totals.selectedBytes)
    }

    func position(categoryID: String, itemID: String) -> Int? {
        categoryPositions[categoryID].flatMap { positions[$0][itemID] }
    }

    mutating func scope(categoryID: String, matching query: String) -> CleanerSelectionScope? {
        scopes(matching: query).first { $0.categoryID == categoryID }
    }

    mutating func scopes(matching query: String) -> [CleanerSelectionScope] {
        if query != scopedQuery {
            scoped = ranges.indices.compactMap { matchingScope(owner: $0, query: query) }
            scopedQuery = query
        }
        return scoped
    }

    private func matchingScope(owner: Int, query: String) -> CleanerSelectionScope? {
        let categoryID = categoryIDs[owner]
        let range = ranges[owner]
        if query.isEmpty || categoryNames[owner].contains(query) {
            return CleanerSelectionScope(
                categoryID: categoryID, positions: Array(range), whole: !narrowed[owner])
        }
        let matched = range.filter {
            names[$0].contains(query) || branches[$0]?.contains(query) == true
        }
        guard !matched.isEmpty else { return nil }
        return CleanerSelectionScope(categoryID: categoryID, positions: matched, whole: false)
    }

    func selection(of scopes: [CleanerSelectionScope]) -> JunkSelection {
        var total = 0
        var count = 0
        for scope in scopes {
            if scope.whole, let owner = categoryPositions[scope.categoryID] {
                total += perCategory[owner].itemCount
                count += perCategory[owner].markedCount
            } else {
                total += scope.positions.count
                count += scope.positions.reduce(0) { marked[$1] ? $0 + 1 : $0 }
            }
        }
        if count == 0 { return .none }
        return count == total ? .all : .some
    }

    mutating func set(_ changed: [Int], to value: Bool) {
        let flips = changed.filter { marked[$0] != value }
        guard !flips.isEmpty else { return }
        if flips.count * 4 > ids.count {
            for position in flips { marked[position] = value }
            recount()
            return
        }
        var affected = flips
        if flips.contains(where: { !descendants[$0].isEmpty }) {
            var seen = Set(flips)
            for position in flips {
                for child in descendants[position] where seen.insert(child).inserted {
                    affected.append(child)
                }
            }
        }
        adjust(affected, by: -1)
        for position in flips {
            marked[position] = value
            perCategory[owners[position]].markedCount += value ? 1 : -1
        }
        totals.markedCount += value ? flips.count : -flips.count
        adjust(affected, by: 1)
    }

    private func counts(_ position: Int, ancestors: [[Int]]) -> Bool {
        marked[position] && !ancestors[position].contains { marked[$0] }
    }

    private mutating func adjust(_ affected: [Int], by sign: Int) {
        for position in affected {
            let bytes = sizes[position] * Int64(sign)
            if counts(position, ancestors: outerAncestors) {
                totals.selectedCount += sign
                totals.selectedBytes += bytes
            }
            if counts(position, ancestors: innerAncestors) {
                perCategory[owners[position]].selectedCount += sign
                perCategory[owners[position]].selectedBytes += bytes
            }
        }
    }

    private mutating func recount() {
        var updated = CleanerCategoryStats(itemCount: ids.count)
        perCategory = []
        perCategory.reserveCapacity(ranges.count)
        for range in ranges {
            var category = CleanerCategoryStats(itemCount: range.count)
            for position in range {
                guard marked[position] else { continue }
                category.markedCount += 1
                if counts(position, ancestors: innerAncestors) {
                    category.selectedCount += 1
                    category.selectedBytes += sizes[position]
                }
                if counts(position, ancestors: outerAncestors) {
                    updated.selectedCount += 1
                    updated.selectedBytes += sizes[position]
                }
            }
            updated.markedCount += category.markedCount
            perCategory.append(category)
        }
        totals = updated
    }
}
