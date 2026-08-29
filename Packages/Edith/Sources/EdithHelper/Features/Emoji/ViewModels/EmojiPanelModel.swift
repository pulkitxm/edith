import EdithKit
import Foundation
import Observation

struct EmojiPanelCell: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let sectionID: String
        let emojiID: String
    }

    let id: ID
    let emoji: Emoji
}

struct EmojiPanelRow: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
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

    static let rowsPerPage = 16
    static let pageSize = rowsPerPage * EmojiPanelView.columns

    private(set) var query = ""
    private(set) var sections: [EmojiSection] = []
    private(set) var renderedSections: [EmojiSection] = []
    private(set) var selectedID: EmojiPanelCell.ID?
    private(set) var isSearching = false

    private let catalog: EmojiCatalog
    private let search: Search
    @ObservationIgnored private var baseSections: [EmojiSection] = []
    @ObservationIgnored private var baseProjection = Projection()
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
        let searchService = EmojiSearchService(catalog.emoji)
        self.search =
            search ?? { query in
                await searchService.results(query: query)
            }
        baseSections = Self.baseSections(catalog: catalog, frequent: frequent)
        baseProjection = Self.projection(for: baseSections)
        apply(baseProjection, resetSelection: true)
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
            apply(baseProjection, resetSelection: true)
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
        let updated = Self.baseSections(catalog: catalog, frequent: frequent)
        guard updated != baseSections else { return }
        baseSections = updated
        baseProjection = Self.projection(for: updated)
        if EmojiSearch.normalize(query).isEmpty {
            apply(baseProjection, resetSelection: false)
        }
    }

    func reset(frequent: [Emoji]) {
        cancelSearch()
        query = ""
        let updated = Self.baseSections(catalog: catalog, frequent: frequent)
        if updated != baseSections {
            baseSections = updated
            baseProjection = Self.projection(for: updated)
        }
        apply(baseProjection, resetSelection: true)
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
        var rows: [EmojiPanelRow] = []
        for start in stride(from: 0, to: count, by: EmojiPanelView.columns) {
            let end = min(start + EmojiPanelView.columns, count)
            let row = start / EmojiPanelView.columns
            var rowCells: [EmojiPanelCell] = []
            for emoji in section.emoji[start..<end] {
                rowCells.append(
                    EmojiPanelCell(
                        id: EmojiPanelCell.ID(sectionID: section.id, emojiID: emoji.id),
                        emoji: emoji))
            }
            rows.append(
                EmojiPanelRow(
                    id: EmojiPanelRow.ID(sectionID: section.id, rowIndex: row),
                    sectionID: section.id, cells: rowCells, isRenderBoundary: end == count))
        }
        return rows
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
        apply(Self.projection(for: resultSections), resetSelection: true)
    }

    private func apply(_ projection: Projection, resetSelection: Bool) {
        let previousSelection = selectedID
        sections = projection.sections
        cells = projection.cells
        cellIndexByID = projection.cellIndexByID
        cellPositionByID = projection.cellPositionByID
        sectionIndexByID = projection.sectionIndexByID
        sectionOffsetByID = projection.sectionOffsetByID
        renderedCounts = Dictionary(
            uniqueKeysWithValues: sections.enumerated().map { index, section in
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

    private static func projection(for sections: [EmojiSection]) -> Projection {
        var projection = Projection(sections: sections)
        let cellCount = sections.reduce(0) { $0 + $1.emoji.count }
        projection.cells.reserveCapacity(cellCount)
        projection.cellIndexByID.reserveCapacity(cellCount)
        projection.cellPositionByID.reserveCapacity(cellCount)
        projection.sectionIndexByID.reserveCapacity(sections.count)
        projection.sectionOffsetByID.reserveCapacity(sections.count)
        for (sectionIndex, section) in sections.enumerated() {
            projection.sectionIndexByID[section.id] = sectionIndex
            projection.sectionOffsetByID[section.id] = projection.cells.count
            for (itemIndex, emoji) in section.emoji.enumerated() {
                let id = EmojiPanelCell.ID(sectionID: section.id, emojiID: emoji.id)
                let globalIndex = projection.cells.count
                projection.cells.append(EmojiPanelCell(id: id, emoji: emoji))
                projection.cellIndexByID[id] = globalIndex
                projection.cellPositionByID[id] = CellPosition(
                    sectionIndex: sectionIndex, itemIndex: itemIndex)
            }
        }
        return projection
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

    private struct Projection {
        var sections: [EmojiSection] = []
        var cells: [EmojiPanelCell] = []
        var cellIndexByID: [EmojiPanelCell.ID: Int] = [:]
        var cellPositionByID: [EmojiPanelCell.ID: CellPosition] = [:]
        var sectionIndexByID: [String: Int] = [:]
        var sectionOffsetByID: [String: Int] = [:]
    }

    private struct CellPosition: Sendable {
        let sectionIndex: Int
        let itemIndex: Int
    }
}
