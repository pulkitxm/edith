import EdithKit
import Foundation

struct AttentionTimelineDay: Identifiable, Equatable, Sendable {
    var id: Date { day }
    var day: Date
    var active: TimeInterval
    var ribbon: [AttentionRibbonBlock]
    var blocks: [AttentionTimelineBlock]
}

enum AttentionPageDerived {
    static func dayRibbon(_ summary: AttentionSummary) -> [AttentionRibbonBlock] {
        AttentionRibbonBlock.blocks(summary.spans)
    }

    static func timeline(
        _ summary: AttentionSummary, calendar: Calendar = .current
    ) -> [AttentionTimelineDay] {
        var byDay: [Date: [AttentionSpan]] = [:]
        for span in summary.spans {
            byDay[calendar.startOfDay(for: span.start), default: []].append(span)
        }
        return byDay.keys.sorted(by: >).map { day in
            let spans = byDay[day] ?? []
            return AttentionTimelineDay(
                day: day, active: spans.reduce(0) { $0 + $1.duration },
                ribbon: AttentionRibbonBlock.blocks(spans),
                blocks: Array(AttentionTimelineBlock.blocks(spans).reversed()))
        }
    }
}
