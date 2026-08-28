import EdithKit
import Foundation
import Observation

struct EmojiPanelCell: Identifiable, Hashable {
    struct ID: Hashable {
        let sectionID: String
        let emojiID: String
    }

    let id: ID
    let emoji: Emoji
}

struct EmojiPanelRow: Identifiable, Hashable {
    struct ID: Hashable {
        let sectionID: String
        let rowIndex: Int
    }

    let id: ID
    let sectionID: String
    let cells: [EmojiPanelCell]
    let isRenderBoundary: Bool
}

@MainActor
@Observable
final class EmojiPanelModel {
    typealias Search = @Sendable (String) async -> [Emoji]

    static let rowsPerPage = 8
    static let pageSize = rowsPerPage * EmojiPanelView.columns

    private(set) var query = ""
    private(set) var sections: [EmojiSection] = []
    private(set) var renderedSections: [EmojiSection] = []
    private(set) var selectedID: EmojiPanelCell.ID?
    private(set) var isSearching = false

    private let catalog: EmojiCatalog
    private let search: Search
    @ObservationIgnored private var baseSections: [EmojiSection] = []
    @ObservationIgnored private var cells: [EmojiPanelCell] = []
    @ObservationIgnored private var cellIndexByID: [EmojiPanelCell.ID: Int] = [:]
    @ObservationIgnored private var cellPositionByID: [EmojiPanelCell.ID: CellPosition] = [:]
    @ObservationIgnored private var sectionIndexByID: [String: Int] = [:]
    @ObservationIgnored private var sectionOffsetByID: [String: Int] = [:]
    @ObservationIgnored private var renderedCounts: [String: Int] = [:]
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(catalog: EmojiCatalog, frequent: [Emoji], search: Search? = nil) {
        self.catalog = catalog
        let index = EmojiSearchIndex(catalog.emoji)
        self.search =
            search ?? { query in
                await Task.detached(priority: .userInitiated) {
                    index.results(query: query)
                }.value
            }
        baseSections = Self.baseSections(catalog: catalog, frequent: frequent)
        publish(baseSections, resetSelection: true)
    }

    var selected: Emoji? {
        guard let selectedID, let index = cellIndexByID[selectedID] else { return nil }
        return cells[index].emoji
    }

    var renderedCellCount: Int {
        renderedSections.reduce(0) { $0 + $1.emoji.count }
    }

    func setQuery(_ value: String) {
        query = value
        generation &+= 1
        let requestedGeneration = generation
        searchTask?.cancel()
        let normalized = EmojiSearch.normalize(value)
        guard !normalized.isEmpty else {
            isSearching = false
            searchTask = nil
            publish(baseSections, resetSelection: true)
            return
        }
        isSearching = true
        let search = search
        searchTask = Task { [weak self] in
            let result = await search(normalized)
            guard !Task.isCancelled else { return }
            self?.publishSearch(
                result, normalizedQuery: normalized, generation: requestedGeneration)
        }
    }

    func updateFrequent(_ frequent: [Emoji]) {
        baseSections = Self.baseSections(catalog: catalog, frequent: frequent)
        if EmojiSearch.normalize(query).isEmpty {
            publish(baseSections, resetSelection: false)
        }
    }

    func reset(frequent: [Emoji]) {
        cancelSearch()
        query = ""
        baseSections = Self.baseSections(catalog: catalog, frequent: frequent)
        publish(baseSections, resetSelection: true)
    }

    func cancelSearch() {
        generation &+= 1
        searchTask?.cancel()
        searchTask = nil
        isSearching = false
    }

    func moveSelection(delta: Int) -> EmojiPanelCell.ID? {
        guard !cells.isEmpty else {
            selectedID = nil
            return nil
        }
        let current = selectedID.flatMap { cellIndexByID[$0] } ?? 0
        let next = EmojiPanelView.nextSelection(from: current, delta: delta, count: cells.count)
        let cell = cells[next]
        ensureRendered(cell.id)
        selectedID = cell.id
        return cell.id
    }

    func revealSection(_ sectionID: String) -> String? {
        guard let sectionIndex = sectionIndexByID[sectionID] else { return nil }
        let section = sections[sectionIndex]
        guard !section.emoji.isEmpty else { return nil }
        ensureRendered(sectionID: sectionID, through: 0)
        return sectionID
    }

    func sectionOffset(for sectionID: String) -> Int? {
        sectionOffsetByID[sectionID]
    }

    func extend(sectionID: String) {
        guard let sectionIndex = sectionIndexByID[sectionID] else { return }
        let section = sections[sectionIndex]
        let current = renderedCounts[sectionID, default: 0]
        guard current < section.emoji.count else { return }
        renderedCounts[sectionID] = min(section.emoji.count, current + Self.pageSize)
        syncRenderedSections()
    }

    func rows(for section: EmojiSection) -> [EmojiPanelRow] {
        let count = section.emoji.count
        guard count > 0 else { return [] }
        return stride(from: 0, to: count, by: EmojiPanelView.columns).map { start in
            let end = min(start + EmojiPanelView.columns, count)
            let row = start / EmojiPanelView.columns
            return EmojiPanelRow(
                id: EmojiPanelRow.ID(sectionID: section.id, rowIndex: row),
                sectionID: section.id,
                cells: section.emoji[start..<end].map {
                    EmojiPanelCell(
                        id: EmojiPanelCell.ID(sectionID: section.id, emojiID: $0.id), emoji: $0)
                }, isRenderBoundary: end == count)
        }
    }

    static func baseSections(catalog: EmojiCatalog, frequent: [Emoji]) -> [EmojiSection] {
        var built: [EmojiSection] = []
        if !frequent.isEmpty {
            built.append(
                EmojiSection(
                    id: EmojiPanelView.frequentSectionID, title: "Frequently used",
                    symbolName: "clock", emoji: frequent))
        }
        for (index, group) in catalog.groups.enumerated() {
            let emoji = catalog.emoji(inGroup: index)
            guard !emoji.isEmpty else { continue }
            built.append(
                EmojiSection(
                    id: group.id, title: group.name, symbolName: group.symbolName, emoji: emoji))
        }
        return built
    }

    private func publishSearch(
        _ result: [Emoji], normalizedQuery: String, generation requestedGeneration: UInt64
    ) {
        guard requestedGeneration == generation, normalizedQuery == EmojiSearch.normalize(query)
        else { return }
        let resultSections =
            result.isEmpty
            ? []
            : [
                EmojiSection(
                    id: EmojiPanelView.resultsSectionID, title: "Results",
                    symbolName: "magnifyingglass", emoji: result)
            ]
        isSearching = false
        searchTask = nil
        publish(resultSections, resetSelection: true)
    }

    private func publish(_ newSections: [EmojiSection], resetSelection: Bool) {
        let previousSelection = selectedID
        sections = newSections
        cells = []
        cellIndexByID = [:]
        cellPositionByID = [:]
        sectionIndexByID = [:]
        sectionOffsetByID = [:]
        for (sectionIndex, section) in newSections.enumerated() {
            sectionIndexByID[section.id] = sectionIndex
            sectionOffsetByID[section.id] = cells.count
            for (itemIndex, emoji) in section.emoji.enumerated() {
                let id = EmojiPanelCell.ID(sectionID: section.id, emojiID: emoji.id)
                let globalIndex = cells.count
                cells.append(EmojiPanelCell(id: id, emoji: emoji))
                cellIndexByID[id] = globalIndex
                cellPositionByID[id] = CellPosition(
                    sectionIndex: sectionIndex, itemIndex: itemIndex)
            }
        }
        renderedCounts = Dictionary(
            uniqueKeysWithValues: newSections.enumerated().map { index, section in
                let initial = index == 0 ? Self.pageSize : EmojiPanelView.columns
                return (section.id, min(section.emoji.count, initial))
            })
        let selectionStillExists = previousSelection.flatMap { cellIndexByID[$0] } != nil
        if resetSelection || !selectionStillExists {
            selectedID = cells.first?.id
        } else {
            selectedID = previousSelection
        }
        if let selectedID { ensureRendered(selectedID) } else { syncRenderedSections() }
    }

    private func ensureRendered(_ cellID: EmojiPanelCell.ID) {
        guard let position = cellPositionByID[cellID] else { return }
        ensureRendered(
            sectionID: sections[position.sectionIndex].id, through: position.itemIndex)
    }

    private func ensureRendered(sectionID: String, through index: Int) {
        guard let sectionIndex = sectionIndexByID[sectionID] else { return }
        let section = sections[sectionIndex]
        let required = min(
            section.emoji.count, ((max(index, 0) / Self.pageSize) + 1) * Self.pageSize)
        if required > renderedCounts[sectionID, default: 0] {
            renderedCounts[sectionID] = required
        }
        syncRenderedSections()
    }

    private func syncRenderedSections() {
        renderedSections = sections.map { section in
            EmojiSection(
                id: section.id, title: section.title, symbolName: section.symbolName,
                emoji: Array(section.emoji.prefix(renderedCounts[section.id, default: 0])))
        }
    }

    private struct CellPosition {
        let sectionIndex: Int
        let itemIndex: Int
    }
}
