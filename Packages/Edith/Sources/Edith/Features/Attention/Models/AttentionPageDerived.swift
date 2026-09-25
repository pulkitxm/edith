import EdithKit
import Foundation

struct AttentionTimelineDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    var day: Date
    var active: TimeInterval
    var ribbon: [AttentionRibbonBlock]
    var blocks: [AttentionTimelineBlock]
}

struct AttentionSpanFilter: Equatable, Sendable {
    var level: AttentionProductivity?
    var sphere: AttentionSphere?
    var category: String?
    var search: String

    var isEmpty: Bool {
        level == nil && sphere == nil && category == nil
            && search.trimmingCharacters(in: .whitespaces).isEmpty
    }

    func matches(_ span: AttentionSpan) -> Bool {
        if let category, span.categoryID != category { return false }
        if let level, span.productivity != level { return false }
        if let sphere, span.sphere != sphere { return false }
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return true }
        return span.name.lowercased().contains(query)
            || span.detail?.lowercased().contains(query) == true
    }
}

enum AttentionPageDerived {
    static func dayRibbon(_ summary: AttentionSummary) -> [AttentionRibbonBlock] {
        AttentionRibbonBlock.blocks(summary.spans)
    }

    static func timeline(
        _ summary: AttentionSummary, filter: AttentionSpanFilter, calendar: Calendar = .current
    ) -> [AttentionTimelineDay] {
        var byDay: [Date: [AttentionSpan]] = [:]
        for span in summary.spans {
            byDay[calendar.startOfDay(for: span.start), default: []].append(span)
        }
        return byDay.keys.sorted(by: >).map { day in
            let spans = byDay[day] ?? []
            let active = spans.reduce(0) { $0 + $1.duration }
            let kept = filter.isEmpty ? spans : spans.filter(filter.matches)
            return AttentionTimelineDay(
                day: day, active: active, ribbon: AttentionRibbonBlock.blocks(kept),
                blocks: Array(AttentionTimelineBlock.blocks(kept).reversed()))
        }
    }
}
