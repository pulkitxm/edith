import AppKit
import EdithExtensionUI
import Foundation
import SwiftUI
import Testing

@testable import AttentionNative

@Suite(.serialized) @MainActor struct AttentionTimelineListTests {
    @Test func rowsFlattenEveryDayIntoStableCardSlices() {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!
        let blocks = (0..<3).map { index in
            Self.block(at: today.addingTimeInterval(Double(index) * 600 + 3_600))
        }
        let days = [
            AttentionTimelineDay(day: today, active: 1_800, ribbon: [], blocks: blocks),
            AttentionTimelineDay(day: yesterday, active: 0, ribbon: [], blocks: []),
        ]
        let rows = AttentionPageDerived.timelineRows(days)

        #expect(rows.count == 1 + 3 + 1 + 1 + 1 + 1)
        #expect(Set(rows.map(\.id)).count == rows.count)
        guard case .day(let header) = rows[0].kind else {
            Issue.record("first row is not a day header")
            return
        }
        #expect(header.subtitle.hasSuffix("3 blocks"))
        guard case .block(let first) = rows[1].kind, case .block(let second) = rows[2].kind else {
            Issue.record("block rows are missing")
            return
        }
        #expect(first.first && !second.first)
        #expect(first.duration == AttentionFormat.duration(300))
        #expect(first.detail == nil && first.context == nil && first.inputs == nil)
        #expect(rows[4].kind == .end(last: false))
        #expect(rows[6].kind == .empty)
        #expect(rows[7].kind == .end(last: true))
    }

    @Test func rowEntriesCarryPrecomputedDisplayText() {
        var block = Self.block(at: Date())
        block.details = ["Quarterly plan": 200, "Inbox": 100]
        block.interactions = 1_250
        block.skipped = 2
        block.tags = [AttentionTag.project: "Atlas", AttentionTag.machine: "studio"]
        let rows = AttentionPageDerived.timelineRows([
            AttentionTimelineDay(
                day: Calendar.current.startOfDay(for: block.start), active: 300, ribbon: [],
                blocks: [block])
        ])
        guard case .block(let entry) = rows[1].kind else {
            Issue.record("block row is missing")
            return
        }
        #expect(entry.detail == "Quarterly plan")
        #expect(entry.context == "studio · Atlas · after 2 brief switches")
        #expect(entry.inputs == "\(AttentionFormat.count(1_250)) inputs")
    }

    @Test func singleBriefSwitchReadsInTheSingular() {
        var block = Self.block(at: Date())
        block.skipped = 1
        let rows = AttentionPageDerived.timelineRows([
            AttentionTimelineDay(
                day: Calendar.current.startOfDay(for: block.start), active: 300, ribbon: [],
                blocks: [block])
        ])
        guard case .block(let entry) = rows[1].kind else {
            Issue.record("block row is missing")
            return
        }
        #expect(entry.context == "after 1 brief switch")
    }

    @Test func rowHeightsAreWholePointsThatFollowContentAndZoom() {
        let plain = Self.entryRow(detail: nil, context: nil)
        let detailed = Self.entryRow(detail: "Detail", context: nil)
        let full = Self.entryRow(detail: "Detail", context: "Context")
        let scale = UIScale.current
        defer { UIScale.apply(scale) }
        for zoom in [1.0, 1.15, 1.5] {
            UIScale.apply(zoom)
            let heights = [plain, detailed, full].map(AttentionTimelineMetrics.height(of:))
            #expect(heights.sorted() == heights)
            #expect(Set(heights).count == 3)
            #expect(heights.allSatisfy { $0 == $0.rounded() && $0 > 0 })
        }
        UIScale.apply(1)
        let regular = AttentionTimelineMetrics.height(of: plain)
        UIScale.apply(1.5)
        #expect(AttentionTimelineMetrics.height(of: plain) > regular)
    }

    @Test func pageVirtualizesTheTimelineWithoutLosingRows() async throws {
        let fixture = try AttentionSyntheticHistory.make(days: 3, eventsPerDay: 200)
        defer { fixture.cleanup() }
        let counter = AttentionRequestCounter()
        let model = AttentionPageModel(
            repository: fixture.repository, uiClient: fixture.client(counter: counter))
        model.section = .timeline
        model.select(.last7)
        model.reload()
        await model.waitForReload()
        #expect(model.showsTimelineList)
        #expect(model.timelineRows.count > 300)

        let (window, host) = AttentionScrollHarness.host(
            AttentionPage(model: model)
                .environment(\.compactLayout, false)
                .environment(\.colorScheme, .dark),
            size: CGSize(width: 1280, height: 860))
        defer {
            window.orderOut(nil)
            window.contentView = nil
        }
        await AttentionScrollHarness.settle(host, for: .seconds(1))
        let scroll = try #require(AttentionScrollHarness.scrollView(in: host))
        let table = try #require(scroll.documentView as? NSTableView)
        #expect(table.numberOfRows == model.timelineRows.count + 1)
        let live = Self.descendants(of: table).filter { $0 is NSTableCellView }.count
        #expect(live > 0 && live < 60)

        let timing = await AttentionScrollHarness.scroll(host, frames: 120)
        #expect(timing.frames.count == 120)
        #expect(timing.median < 16)
        let afterScroll = Self.descendants(of: table).filter { $0 is NSTableCellView }.count
        #expect(afterScroll < 60)
        await model.shutdown()
    }

    private static func block(at start: Date) -> AttentionTimelineBlock {
        AttentionTimelineBlock(
            start: start, end: start.addingTimeInterval(300), entityID: "app.\(start)",
            name: "Sample App", categoryID: "work", details: [:], interactions: 0, tags: [:],
            skipped: 0, productivity: .neutral, sphere: .both)
    }

    private static func entryRow(detail: String?, context: String?) -> AttentionTimelineRow {
        let now = Date()
        return AttentionTimelineRow(
            id: .block(now),
            kind: .block(
                .init(
                    block: block(at: now), start: "9:00", end: "9:05", duration: "5m",
                    inputs: nil, detail: detail, context: context, first: false)))
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap { descendants(of: $0) }
    }
}
