import Foundation

struct HerdrSidebarOrder {
    private(set) var ids: [String]

    init(_ ids: [String] = []) {
        var seen = Set<String>()
        self.ids = ids.filter { seen.insert($0).inserted }
    }

    mutating func remember(_ incoming: [String]) {
        var seen = Set(ids)
        ids.append(contentsOf: incoming.filter { seen.insert($0).inserted })
    }

    func ordered<Item: Identifiable>(_ items: [Item]) -> [Item] where Item.ID == String {
        let ranks = Dictionary(
            uniqueKeysWithValues: ids.enumerated().map { ($0.element, $0.offset) })
        return items.enumerated().sorted {
            let left = ranks[$0.element.id] ?? ids.count + $0.offset
            let right = ranks[$1.element.id] ?? ids.count + $1.offset
            return left < right
        }.map(\.element)
    }

    mutating func move(_ id: String, relativeTo target: String, after: Bool) {
        guard id != target, ids.contains(id), ids.contains(target) else { return }
        ids.removeAll { $0 == id }
        guard let index = ids.firstIndex(of: target) else { return }
        ids.insert(id, at: index + (after ? 1 : 0))
    }
}
