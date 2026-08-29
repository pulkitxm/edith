import Foundation

public struct GitHubBrowserFindState: Codable, Equatable, Sendable {
    public var query: String
    public var selectedMatch: Int?
    public var isCaseSensitive: Bool

    public init(query: String, selectedMatch: Int? = nil, isCaseSensitive: Bool = false) {
        self.query = query
        self.selectedMatch = selectedMatch
        self.isCaseSensitive = isCaseSensitive
    }
}

public struct GitHubBrowserHistoryEntry: Codable, Equatable, Sendable {
    public var route: GitHubRoute
    public var scrollOffset: Double
    public var horizontalScrollOffset: Double
    public var lineSelection: GitHubLineSelection?
    public var wrapsLines: Bool
    public var find: GitHubBrowserFindState?

    public init(
        route: GitHubRoute, scrollOffset: Double = 0, horizontalScrollOffset: Double = 0,
        lineSelection: GitHubLineSelection? = nil, wrapsLines: Bool = false,
        find: GitHubBrowserFindState? = nil
    ) {
        self.route = route
        self.scrollOffset = scrollOffset
        self.horizontalScrollOffset = horizontalScrollOffset
        self.lineSelection = lineSelection
        self.wrapsLines = wrapsLines
        self.find = find
    }
}

public struct GitHubBrowserTab: Codable, Equatable, Identifiable, Sendable {
    public fileprivate(set) var id: UUID
    public var title: String?
    public fileprivate(set) var isPinned: Bool
    public private(set) var addressBarDraft: String
    public private(set) var backHistory: [GitHubBrowserHistoryEntry]
    public private(set) var currentEntry: GitHubBrowserHistoryEntry
    public private(set) var forwardHistory: [GitHubBrowserHistoryEntry]
    public private(set) var reloadRevision: UInt64

    public init(
        id: UUID = UUID(), entry: GitHubBrowserHistoryEntry, title: String? = nil,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.isPinned = isPinned
        self.addressBarDraft = entry.route.url.absoluteString
        self.backHistory = []
        self.currentEntry = entry
        self.forwardHistory = []
        self.reloadRevision = 0
    }

    public var historyEntries: [GitHubBrowserHistoryEntry] {
        backHistory + [currentEntry] + forwardHistory.reversed()
    }

    public var canGoBack: Bool { !backHistory.isEmpty }
    public var canGoForward: Bool { !forwardHistory.isEmpty }

    public mutating func navigate(to entry: GitHubBrowserHistoryEntry) {
        backHistory.append(currentEntry)
        currentEntry = entry
        forwardHistory.removeAll()
        addressBarDraft = entry.route.url.absoluteString
    }

    @discardableResult public mutating func goBack() -> Bool {
        guard let entry = backHistory.popLast() else { return false }
        forwardHistory.append(currentEntry)
        currentEntry = entry
        addressBarDraft = entry.route.url.absoluteString
        return true
    }

    @discardableResult public mutating func goForward() -> Bool {
        guard let entry = forwardHistory.popLast() else { return false }
        backHistory.append(currentEntry)
        currentEntry = entry
        addressBarDraft = entry.route.url.absoluteString
        return true
    }

    @discardableResult public mutating func reload() -> GitHubBrowserHistoryEntry {
        reloadRevision &+= 1
        return currentEntry
    }

    public mutating func updateCurrentPresentation(
        scrollOffset: Double, horizontalScrollOffset: Double, lineSelection: GitHubLineSelection?,
        wrapsLines: Bool, find: GitHubBrowserFindState?
    ) {
        currentEntry.scrollOffset = scrollOffset
        currentEntry.horizontalScrollOffset = horizontalScrollOffset
        currentEntry.lineSelection = lineSelection
        currentEntry.wrapsLines = wrapsLines
        currentEntry.find = find
    }

    public mutating func updateAddressBarDraft(_ text: String) {
        addressBarDraft = text
    }

    fileprivate func duplicated(as id: UUID) -> Self {
        var copy = self
        copy.id = id
        return copy
    }
}

public struct GitHubRecentlyClosedTab: Codable, Equatable, Sendable {
    public let tab: GitHubBrowserTab
    public let index: Int
}

public struct GitHubBrowserSession: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let recentlyClosedLimit = 10

    public let version: Int
    public private(set) var tabs: [GitHubBrowserTab]
    public private(set) var selectedTabID: UUID?
    public private(set) var recentlyClosed: [GitHubRecentlyClosedTab]

    public init(tabs: [GitHubBrowserTab] = [], selectedTabID: UUID? = nil) {
        self.version = Self.currentVersion
        self.tabs = tabs
        self.selectedTabID = selectedTabID
        self.recentlyClosed = []
        normalize()
    }

    public var selectedTab: GitHubBrowserTab? { selectedTabID.flatMap(tab(id:)) }
    public var pinnedCount: Int { tabs.prefix(while: \.isPinned).count }

    public func tab(id: UUID) -> GitHubBrowserTab? { tabs.first { $0.id == id } }

    @discardableResult public mutating func selectTab(_ id: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == id }) else { return false }
        selectedTabID = id
        return true
    }

    @discardableResult public mutating func openTab(
        entry: GitHubBrowserHistoryEntry, title: String? = nil, isPinned: Bool = false,
        id: UUID = UUID(), select: Bool = true
    ) -> UUID? {
        guard !tabs.contains(where: { $0.id == id }) else { return nil }
        let tab = GitHubBrowserTab(id: id, entry: entry, title: title, isPinned: isPinned)
        tabs.insert(tab, at: isPinned ? pinnedCount : tabs.count)
        if select { selectedTabID = id }
        return id
    }

    @discardableResult public mutating func duplicateTab(
        _ id: UUID, as duplicateID: UUID = UUID()
    ) -> UUID? {
        guard !tabs.contains(where: { $0.id == duplicateID }),
            let index = tabs.firstIndex(where: { $0.id == id })
        else { return nil }
        tabs.insert(tabs[index].duplicated(as: duplicateID), at: index + 1)
        selectedTabID = duplicateID
        return duplicateID
    }

    @discardableResult public mutating func reorderTab(_ id: UUID, to destination: Int) -> Bool {
        guard let source = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let tab = tabs.remove(at: source)
        let boundary = pinnedCount
        let lower = tab.isPinned ? 0 : boundary
        let upper = tab.isPinned ? boundary : tabs.count
        let target = min(max(destination, lower), upper)
        tabs.insert(tab, at: target)
        return source != target
    }

    @discardableResult public mutating func setPinned(_ isPinned: Bool, tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
            tabs[index].isPinned != isPinned
        else { return false }
        var tab = tabs.remove(at: index)
        tab.isPinned = isPinned
        tabs.insert(tab, at: pinnedCount)
        return true
    }

    @discardableResult public mutating func closeTab(_ id: UUID) -> GitHubBrowserTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs.remove(at: index)
        recentlyClosed.removeAll { $0.tab.id == id }
        recentlyClosed.insert(GitHubRecentlyClosedTab(tab: tab, index: index), at: 0)
        recentlyClosed = Array(recentlyClosed.prefix(Self.recentlyClosedLimit))
        if selectedTabID == id {
            selectedTabID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id
        }
        return tab
    }

    @discardableResult public mutating func reopenLastClosedTab() -> UUID? {
        while !recentlyClosed.isEmpty {
            let closed = recentlyClosed.removeFirst()
            guard !tabs.contains(where: { $0.id == closed.tab.id }) else { continue }
            let boundary = pinnedCount
            let lower = closed.tab.isPinned ? 0 : boundary
            let upper = closed.tab.isPinned ? boundary : tabs.count
            let index = min(max(closed.index, lower), upper)
            tabs.insert(closed.tab, at: index)
            selectedTabID = closed.tab.id
            return closed.tab.id
        }
        return nil
    }

    @discardableResult public mutating func navigate(
        tabID: UUID, to entry: GitHubBrowserHistoryEntry
    ) -> Bool {
        mutateTab(id: tabID) { tab in
            tab.navigate(to: entry)
            return true
        } ?? false
    }

    @discardableResult public mutating func goBack(tabID: UUID) -> Bool {
        mutateTab(id: tabID) { $0.goBack() } ?? false
    }

    @discardableResult public mutating func goForward(tabID: UUID) -> Bool {
        mutateTab(id: tabID) { $0.goForward() } ?? false
    }

    @discardableResult public mutating func reload(
        tabID: UUID
    ) -> GitHubBrowserHistoryEntry? {
        mutateTab(id: tabID) { $0.reload() }
    }

    @discardableResult public mutating func updateCurrentPresentation(
        tabID: UUID, scrollOffset: Double, horizontalScrollOffset: Double,
        lineSelection: GitHubLineSelection?, wrapsLines: Bool, find: GitHubBrowserFindState?
    ) -> Bool {
        mutateTab(id: tabID) { tab in
            tab.updateCurrentPresentation(
                scrollOffset: scrollOffset, horizontalScrollOffset: horizontalScrollOffset,
                lineSelection: lineSelection, wrapsLines: wrapsLines, find: find)
            return true
        } ?? false
    }

    @discardableResult public mutating func updateAddressBarDraft(
        tabID: UUID, text: String
    ) -> Bool {
        mutateTab(id: tabID) { tab in
            tab.updateAddressBarDraft(text)
            return true
        } ?? false
    }

    private enum CodingKeys: String, CodingKey { case version, tabs, selectedTabID, recentlyClosed }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let version = try values.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .version, in: values,
                debugDescription: "Unsupported GitHub browser session version \(version).")
        }
        self.version = version
        self.tabs = try values.decode([GitHubBrowserTab].self, forKey: .tabs)
        self.selectedTabID = try values.decodeIfPresent(UUID.self, forKey: .selectedTabID)
        self.recentlyClosed =
            try values.decodeIfPresent([GitHubRecentlyClosedTab].self, forKey: .recentlyClosed)
            ?? []
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(Self.currentVersion, forKey: .version)
        try values.encode(tabs, forKey: .tabs)
        try values.encodeIfPresent(selectedTabID, forKey: .selectedTabID)
        try values.encode(recentlyClosed, forKey: .recentlyClosed)
    }

    private mutating func mutateTab<Result>(
        id: UUID, _ mutation: (inout GitHubBrowserTab) -> Result
    ) -> Result? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        return mutation(&tabs[index])
    }

    private mutating func normalize() {
        var openIDs = Set<UUID>()
        tabs = tabs.filter { openIDs.insert($0.id).inserted }
        tabs = tabs.filter(\.isPinned) + tabs.filter { !$0.isPinned }
        if selectedTabID.map({ openIDs.contains($0) }) != true {
            selectedTabID = tabs.first?.id
        }
        var closedIDs = Set<UUID>()
        recentlyClosed = Array(
            recentlyClosed.filter {
                !openIDs.contains($0.tab.id) && closedIDs.insert($0.tab.id).inserted
            }.prefix(Self.recentlyClosedLimit))
    }
}
