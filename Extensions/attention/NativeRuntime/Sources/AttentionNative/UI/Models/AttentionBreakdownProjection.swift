internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI_attention_native
import Foundation

struct AttentionBreakdownItem: Identifiable, Sendable {
    var id: String { key }
    var key: String
    var label: String
    var duration: TimeInterval
    var categories: [String: TimeInterval]
    var names: [String]
    var entity: AttentionEntity? = nil

    var subtitle: String? {
        let candidates = names + [entity?.domain, entity?.category.name].compactMap { $0 }
        var seen = Set([label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()])
        let distinct = candidates.compactMap { value -> String? in
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { return nil }
            return text
        }
        return distinct.isEmpty ? nil : distinct.joined(separator: ", ")
    }
    var interactions: Int
}

enum AttentionBreakdownSort: String, CaseIterable, Identifiable, Sendable {
    case time = "Most time"
    case name = "Name"
    case inputs = "Most inputs"
    var id: String { rawValue }

    func sorted(_ rows: [AttentionBreakdownItem]) -> [AttentionBreakdownItem] {
        rows.sorted {
            switch self {
            case .time: $0.duration == $1.duration ? $0.key < $1.key : $0.duration > $1.duration
            case .name: $0.label.localizedStandardCompare($1.label) == .orderedAscending
            case .inputs:
                $0.interactions == $1.interactions
                    ? $0.duration > $1.duration : $0.interactions > $1.interactions
            }
        }
    }
}

struct AttentionBreakdownProjection: Sendable {
    var rows: [AttentionBreakdownItem] = []
    var top: [AttentionBreakdownItem] = []
    var total: TimeInterval = 0

    init() {}

    init(summary: AttentionSummary, dimension key: String, sort: AttentionBreakdownSort) {
        guard
            let dimension = summary.dimensions.first(where: { $0.key == key })
                ?? summary.dimensions.first
        else { return }
        let entities = Dictionary(
            summary.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let matching = dimension.rows.compactMap { row -> AttentionBreakdownItem? in
            let duration = row.categories.values.reduce(0, +)
            guard duration > 0 else { return nil }
            return AttentionBreakdownItem(
                key: row.key,
                label: dimension.key == AttentionTag.page
                    ? (SurfaceWidget(rawValue: row.key)?.title ?? row.key) : row.key,
                duration: duration, categories: row.categories, names: row.entityNames,
                entity: row.entityIDs.compactMap { entities[$0] }.first,
                interactions: row.interactions)
        }
        rows = sort.sorted(matching)
        top = Array(AttentionBreakdownSort.time.sorted(matching).prefix(8))
        total = matching.reduce(0) { $0 + $1.duration }
    }
}
