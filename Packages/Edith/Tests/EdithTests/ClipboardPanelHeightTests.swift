import EdithKit
import Foundation
import Testing

@testable import EdithHelper

@Suite struct ClipboardPanelHeightTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func entry(
        _ preview: String = "hello", ext: String = "txt", hoursAgo: Double = 0,
        pinned: Bool = false
    ) -> ClipboardEntry {
        ClipboardEntry(
            sha256: UUID().uuidString, types: ["public.utf8-plain-text"], ext: ext,
            sourceApp: "Notes", sourceBundleID: nil,
            createdAt: Self.now.addingTimeInterval(-hoursAgo * 3600), size: 10, preview: preview,
            pinned: pinned)
    }

    private func height(_ entries: [ClipboardEntry], footer: Bool = false) -> CGFloat {
        ClipboardPanelLayout.estimatedHeight(
            for: entries, pinToTop: true, showsFooter: footer, now: Self.now,
            calendar: Self.calendar)
    }

    private var chrome: CGFloat {
        ClipboardPanelLayout.chrome(showsChips: false, showsFooter: false)
    }

    @Test func emptyHistoryReservesTheEmptyState() {
        #expect(height([]) == chrome + ClipboardPanelLayout.emptyHeight)
    }

    @Test func oneSectionAddsAHeaderAndItsRows() {
        let single = height([entry()])
        let three = height([entry(), entry(), entry()])

        #expect(
            single == chrome + ClipboardPanelLayout.sectionHeaderHeight
                + ClipboardPanelLayout.rowHeight)
        #expect(three - single == 2 * ClipboardPanelLayout.rowHeight)
    }

    @Test func imageRowsAreTallerThanTextRows() {
        let text = height([entry(ext: "txt"), entry(ext: "txt")])
        let image = height([entry(ext: "png"), entry(ext: "png")])

        #expect(
            image - text == 2
                * (ClipboardPanelLayout.imageRowHeight - ClipboardPanelLayout.rowHeight))
    }

    @Test func mixedCategoriesAddTheChipRow() {
        let plain = height([entry("one"), entry("two")])
        let mixed = height([entry("one"), entry("https://example.com")])

        #expect(mixed - plain == ClipboardPanelLayout.chipsHeight)
        #expect(!ClipboardPanelLayout.showsChips(for: []))
        #expect(!ClipboardPanelLayout.showsChips(for: [entry("a"), entry("b")]))
        #expect(ClipboardPanelLayout.showsChips(for: [entry("a"), entry("#fff")]))
    }

    @Test func everyDaySectionAddsAHeader() {
        let today = height([entry(), entry()])
        let split = height([entry(), entry(hoursAgo: 72)])
        let pinned = height([entry(pinned: true), entry()])

        #expect(split - today == ClipboardPanelLayout.sectionHeaderHeight)
        #expect(pinned - today == ClipboardPanelLayout.sectionHeaderHeight)
    }

    @Test func footerAddsFixedHeight() {
        #expect(height([], footer: true) - height([]) == ClipboardPanelLayout.footerHeight)
        #expect(
            height([entry()], footer: true) - height([entry()])
                == ClipboardPanelLayout.footerHeight)
    }

    @Test func heightStopsAtThePanelCap() {
        let many = (0..<500).map { entry("item \($0)", hoursAgo: Double($0)) }

        #expect(height(many) == ClipboardPanelLayout.maxHeight)
        #expect(height(many, footer: true) == ClipboardPanelLayout.maxHeight)
    }

    @Test func sectionsWithoutRowsCountAsEmpty() {
        let hollow = [ClipboardSection(id: "x", title: "Today", entries: [])]

        #expect(
            ClipboardPanelLayout.height(sections: hollow, showsChips: false, showsFooter: false)
                == chrome + ClipboardPanelLayout.emptyHeight)
    }

    @Test func panelFitsTheKeyboardHintsAndStaysCompact() {
        #expect(ClipboardPanelLayout.width >= 480)
        #expect(ClipboardPanelLayout.maxHeight <= 600)
        #expect(
            ClipboardPanelLayout.chrome(showsChips: true, showsFooter: true)
                + ClipboardPanelLayout.emptyHeight < ClipboardPanelLayout.maxHeight)
    }
}
