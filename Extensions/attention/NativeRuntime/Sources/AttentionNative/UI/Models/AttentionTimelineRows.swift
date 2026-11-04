internal import EdithExtensionSupport_attention_native
internal import EdithExtensionUI
import Foundation

struct AttentionTimelineRow: Identifiable, Equatable, Sendable {
    enum ID: Hashable, Sendable {
        case day(Date)
        case empty(Date)
        case block(Date)
        case end(Date)
    }

    struct Header: Equatable, Sendable {
        var title: String
        var subtitle: String
        var interval: DateInterval
        var ribbon: [AttentionRibbonBlock]
    }

    struct Entry: Equatable, Sendable {
        var block: AttentionTimelineBlock
        var start: String
        var end: String
        var duration: String
        var inputs: String?
        var detail: String?
        var context: String?
        var first: Bool
    }

    enum Kind: Equatable, Sendable {
        case day(Header)
        case empty
        case block(Entry)
        case end(last: Bool)
    }

    var id: ID
    var kind: Kind
}

extension AttentionPageDerived {
    static func timelineRows(_ days: [AttentionTimelineDay]) -> [AttentionTimelineRow] {
        var rows: [AttentionTimelineRow] = []
        rows.reserveCapacity(days.reduce(days.count * 2) { $0 + $1.blocks.count })
        for (index, day) in days.enumerated() {
            rows.append(
                AttentionTimelineRow(
                    id: .day(day.day),
                    kind: .day(
                        .init(
                            title: day.day.formatted(
                                .dateTime.weekday(.wide).month(.abbreviated).day()),
                            subtitle:
                                "\(AttentionFormat.duration(day.active)) observed · \(day.blocks.count) blocks",
                            interval: DateInterval(start: day.day, duration: 86_400),
                            ribbon: day.ribbon))))
            if day.blocks.isEmpty {
                rows.append(AttentionTimelineRow(id: .empty(day.day), kind: .empty))
            }
            for (offset, block) in day.blocks.enumerated() {
                rows.append(
                    AttentionTimelineRow(
                        id: .block(block.start), kind: .block(entry(block, first: offset == 0))))
            }
            rows.append(
                AttentionTimelineRow(
                    id: .end(day.day), kind: .end(last: index == days.count - 1)))
        }
        return rows
    }

    private static func entry(_ block: AttentionTimelineBlock, first: Bool)
        -> AttentionTimelineRow.Entry
    {
        let context =
            [
                block.tags[AttentionTag.machine], block.tags[AttentionTag.agent],
                block.tags[AttentionTag.project], block.tags[AttentionTag.repository],
                block.tags[AttentionTag.channel],
            ].compactMap { $0 }
            + (block.skipped > 0 ? ["after \(block.skipped) brief switches"] : [])
        let detail = block.detail.flatMap { $0 == block.name ? nil : $0 }
        return AttentionTimelineRow.Entry(
            block: block, start: AttentionFormat.time(block.start),
            end: AttentionFormat.time(block.end),
            duration: AttentionFormat.duration(block.duration),
            inputs: block.interactions > 0
                ? "\(AttentionFormat.count(block.interactions)) inputs" : nil,
            detail: detail, context: context.isEmpty ? nil : context.joined(separator: " · "),
            first: first)
    }
}
