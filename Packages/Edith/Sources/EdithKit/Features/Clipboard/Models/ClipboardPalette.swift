import Foundation

public struct ClipboardPalette: Equatable, Sendable {
    public static let shortcutLimit = 9

    public private(set) var entries: [ClipboardEntry] = []
    public private(set) var query = ""
    public private(set) var category: ClipboardCategory?
    public private(set) var selectedID: String?
    public private(set) var rows: [ClipboardEntry] = []
    public private(set) var categories: [ClipboardCategory] = []
    public private(set) var pinToTop: Bool
    private var categoryByID: [String: ClipboardCategory] = [:]

    public init(entries: [ClipboardEntry] = [], pinToTop: Bool = true) {
        self.pinToTop = pinToTop
        replace(entries)
    }

    public var selected: ClipboardEntry? {
        guard let selectedID else { return nil }
        return rows.first { $0.id == selectedID }
    }

    public var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return rows.firstIndex { $0.id == selectedID }
    }

    public var isFiltered: Bool {
        !ClipboardActions.normalized(query).isEmpty || category != nil
    }

    public var countLabel: String {
        rows.count == 1 ? "1 clip" : "\(rows.count) clips"
    }

    public func category(of entry: ClipboardEntry) -> ClipboardCategory {
        categoryByID[entry.id] ?? ClipboardCategory(entry)
    }

    public func shortcut(for id: String) -> Int? {
        guard let index = rows.prefix(Self.shortcutLimit).firstIndex(where: { $0.id == id })
        else { return nil }
        return index + 1
    }

    public func entry(forShortcut digit: Int) -> ClipboardEntry? {
        guard (1...Self.shortcutLimit).contains(digit), digit <= rows.count else { return nil }
        return rows[digit - 1]
    }

    public func sections(
        limit: Int? = nil, now: Date = Date(), calendar: Calendar = .autoupdatingCurrent
    ) -> [ClipboardSection] {
        let shown = limit.map { Array(rows.prefix(max(0, $0))) } ?? rows
        return ClipboardTimeline.sections(shown, now: now, calendar: calendar)
    }

    public mutating func replace(_ updated: [ClipboardEntry]) {
        let previousIndex = selectedIndex
        entries = updated
        categoryByID = Dictionary(
            updated.map { ($0.id, ClipboardCategory($0)) }, uniquingKeysWith: { first, _ in first })
        let present = Set(categoryByID.values)
        categories = ClipboardCategory.allCases.filter(present.contains)
        if let category, !present.contains(category) { self.category = nil }
        rebuild(keepingSelectionNear: previousIndex)
    }

    public mutating func search(_ text: String) {
        guard text != query else { return }
        query = text
        rebuild(keepingSelectionNear: nil)
    }

    public mutating func choose(_ category: ClipboardCategory?) {
        let target = category.flatMap { categories.contains($0) ? $0 : nil }
        guard target != self.category else { return }
        self.category = target
        rebuild(keepingSelectionNear: nil)
    }

    public mutating func cycleCategory(by delta: Int) {
        let options: [ClipboardCategory?] = [nil] + categories.map(Optional.some)
        guard options.count > 1 else { return }
        let current = options.firstIndex(of: category) ?? 0
        let next = ((current + delta) % options.count + options.count) % options.count
        choose(options[next])
    }

    public mutating func setPinToTop(_ value: Bool) {
        guard value != pinToTop else { return }
        pinToTop = value
        rebuild(keepingSelectionNear: selectedIndex)
    }

    public mutating func select(_ id: String?) {
        guard let id else { selectedID = nil; return }
        guard rows.contains(where: { $0.id == id }) else { return }
        selectedID = id
    }

    public mutating func move(by delta: Int) {
        guard !rows.isEmpty, delta != 0 else { return }
        guard let index = selectedIndex else {
            selectedID = (delta > 0 ? rows.first : rows.last)?.id
            return
        }
        let next = ((index + delta) % rows.count + rows.count) % rows.count
        selectedID = rows[next].id
    }

    public mutating func jump(toTop top: Bool) {
        selectedID = (top ? rows.first : rows.last)?.id
    }

    public mutating func reset() {
        query = ""
        category = nil
        rebuild(keepingSelectionNear: nil)
    }

    private mutating func rebuild(keepingSelectionNear previousIndex: Int?) {
        let arranged = ClipboardActions.arrange(entries, query: query, pinToTop: pinToTop)
        rows =
            category.map { wanted in arranged.filter { categoryByID[$0.id] == wanted } }
            ?? arranged
        guard let previousIndex else {
            selectedID = rows.first?.id
            return
        }
        if let selectedID, rows.contains(where: { $0.id == selectedID }) { return }
        selectedID = rows.isEmpty ? nil : rows[min(previousIndex, rows.count - 1)].id
    }
}
