import CoreGraphics
import EdithKit
import Foundation
import Observation

@MainActor
@Observable
final class BifrostPanelModel {
    private(set) var query = ""
    private(set) var results: [BifrostResult] = []
    private(set) var sections: [BifrostSection] = []
    private(set) var selectedID: String?

    @ObservationIgnored private let resolve: (String) -> [BifrostResult]

    init(resolve: @escaping (String) -> [BifrostResult]) {
        self.resolve = resolve
        refresh(resetSelection: true)
    }

    static let shortcutLimit = 9

    func shortcutNumber(for id: String) -> Int? {
        guard let index = index(of: id), index < Self.shortcutLimit else { return nil }
        return index + 1
    }

    func result(atShortcut number: Int) -> BifrostResult? {
        let index = number - 1
        guard index >= 0, index < results.count, index < Self.shortcutLimit else { return nil }
        return results[index]
    }

    var selected: BifrostResult? {
        guard let selectedID, let index = index(of: selectedID) else { return nil }
        return results[index]
    }

    var selectedIndex: Int? {
        guard let selectedID else { return nil }
        return index(of: selectedID)
    }

    func setQuery(_ value: String) {
        guard value != query else { return }
        query = value
        refresh(resetSelection: true)
    }

    func reset(query value: String = "") {
        query = value
        refresh(resetSelection: true)
    }

    var height: CGFloat { BifrostPanelMetrics.height(for: sections) }

    var listHeight: CGFloat {
        max(height - BifrostPanelMetrics.headerHeight - BifrostPanelMetrics.footerHeight, 0)
    }

    func refresh(resetSelection: Bool = false) {
        let previous = selectedID
        results = resolve(query)
        sections = BifrostSectionBuilder.sections(from: results, query: query)
        if resetSelection || previous == nil || index(of: previous ?? "") == nil {
            selectedID = results.first?.id
        } else {
            selectedID = previous
        }
    }

    func moveSelection(delta: Int) {
        guard !results.isEmpty else {
            selectedID = nil
            return
        }
        let current = selectedIndex ?? 0
        let next = min(max(current + delta, 0), results.count - 1)
        selectedID = results[next].id
    }

    func select(_ id: String) {
        guard index(of: id) != nil else { return }
        selectedID = id
    }

    private func index(of id: String) -> Int? {
        results.firstIndex { $0.id == id }
    }
}
