import EdithKit
import Foundation

enum ClipboardPanelLayout {
    static let width: CGFloat = 520
    static let maxHeight: CGFloat = 560
    static let headerHeight: CGFloat = 46
    static let chipsHeight: CGFloat = 34
    static let sectionHeaderHeight: CGFloat = 24
    static let rowHeight: CGFloat = 44
    static let imageRowHeight: CGFloat = 56
    static let emptyHeight: CGFloat = 72
    static let footerHeight: CGFloat = 34
    static let listPadding: CGFloat = 8
    static let sizingRowLimit = 24

    static func rowHeight(for entry: ClipboardEntry) -> CGFloat {
        entry.kind == .image ? imageRowHeight : rowHeight
    }

    static func chrome(showsChips: Bool, showsFooter: Bool) -> CGFloat {
        headerHeight + (showsChips ? chipsHeight : 0) + (showsFooter ? footerHeight : 0)
            + listPadding
    }

    static func height(sections: [ClipboardSection], showsChips: Bool, showsFooter: Bool)
        -> CGFloat
    {
        let frame = chrome(showsChips: showsChips, showsFooter: showsFooter)
        guard sections.contains(where: { !$0.entries.isEmpty }) else {
            return min(maxHeight, frame + emptyHeight)
        }
        var content: CGFloat = 0
        for section in sections where !section.entries.isEmpty {
            content += sectionHeaderHeight
            for entry in section.entries {
                content += rowHeight(for: entry)
                if frame + content >= maxHeight { return maxHeight }
            }
        }
        return frame + content
    }

    static func showsChips(for entries: [ClipboardEntry]) -> Bool {
        var first: ClipboardCategory?
        for entry in entries {
            let category = ClipboardCategory(entry)
            if let first, first != category { return true }
            first = category
        }
        return false
    }

    static func estimatedHeight(
        for entries: [ClipboardEntry], pinToTop: Bool, showsFooter: Bool, now: Date = Date(),
        calendar: Calendar = .autoupdatingCurrent
    ) -> CGFloat {
        let arranged = ClipboardActions.arrange(entries, pinToTop: pinToTop)
        let sections = ClipboardTimeline.sections(
            Array(arranged.prefix(sizingRowLimit)), now: now, calendar: calendar)
        return height(
            sections: sections, showsChips: showsChips(for: entries), showsFooter: showsFooter)
    }
}
