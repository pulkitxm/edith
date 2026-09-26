import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardPaletteTests {
    private static let base = Date(timeIntervalSince1970: 1_790_000_000)

    private func entry(
        _ id: String, _ preview: String, age: Double = 0, ext: String = "txt",
        pinned: Bool = false, source: String? = "Notes"
    ) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: id, types: ["public.utf8-plain-text"], ext: ext, sourceApp: source,
            sourceBundleID: nil, createdAt: Self.base.addingTimeInterval(-age), size: 1,
            preview: preview, pinned: pinned)
    }

    private var history: [ClipboardEntry] {
        [
            entry("color", "#ff26a1", age: 1),
            entry("body", "CopyCat keeps your latest copies", age: 2),
            entry("link", "https://coprexlabs.com/copycat", age: 3),
            entry("title", "SHOW HN: Copy everything.", age: 4, source: "Safari"),
            entry("mail", "support@example.com", age: 5),
            entry("shot", "PNG image", age: 6, ext: "png"),
        ]
    }

    @Test func startsOnTheNewestClipWithEveryPresentCategory() {
        let palette = ClipboardPalette(entries: history)

        #expect(palette.rows.map(\.id) == ["color", "body", "link", "title", "mail", "shot"])
        #expect(palette.selectedID == "color")
        #expect(palette.categories == [.text, .link, .email, .color, .image])
        #expect(palette.category == nil)
        #expect(palette.countLabel == "6 clips")
        #expect(!palette.isFiltered)
    }

    @Test func emptyHistoryHasNoSelectionOrCategories() {
        var palette = ClipboardPalette()
        palette.move(by: 1)
        palette.cycleCategory(by: 1)
        palette.jump(toTop: false)

        #expect(palette.rows.isEmpty)
        #expect(palette.selectedID == nil)
        #expect(palette.selected == nil)
        #expect(palette.categories.isEmpty)
        #expect(palette.countLabel == "0 clips")
        #expect(palette.entry(forShortcut: 1) == nil)
    }

    @Test func arrowsWrapAroundTheList() {
        var palette = ClipboardPalette(entries: history)

        palette.move(by: -1)
        #expect(palette.selectedID == "shot")
        palette.move(by: 1)
        #expect(palette.selectedID == "color")
        palette.move(by: 2)
        #expect(palette.selectedID == "link")
        palette.jump(toTop: false)
        #expect(palette.selectedIndex == 5)
        palette.jump(toTop: true)
        #expect(palette.selectedIndex == 0)
        palette.move(by: 0)
        #expect(palette.selectedIndex == 0)
    }

    @Test func movingWithoutASelectionPicksTheNearestEdge() {
        var palette = ClipboardPalette(entries: history)
        palette.select(nil)
        palette.move(by: -1)
        #expect(palette.selectedID == "shot")

        palette.select(nil)
        palette.move(by: 1)
        #expect(palette.selectedID == "color")
    }

    @Test func selectingAnUnknownIDKeepsTheCurrentSelection() {
        var palette = ClipboardPalette(entries: history)
        palette.select("link")
        palette.select("missing")

        #expect(palette.selected?.id == "link")
    }

    @Test func categoriesCycleThroughAllAndWrapBothWays() {
        var palette = ClipboardPalette(entries: history)

        palette.cycleCategory(by: 1)
        #expect(palette.category == .text)
        #expect(palette.rows.map(\.id) == ["body", "title"])
        #expect(palette.selectedID == "body")
        #expect(palette.isFiltered)

        palette.cycleCategory(by: -1)
        #expect(palette.category == nil)
        palette.cycleCategory(by: -1)
        #expect(palette.category == .image)
        #expect(palette.rows.map(\.id) == ["shot"])
        palette.cycleCategory(by: 1)
        #expect(palette.category == nil)
        #expect(palette.rows.count == 6)
    }

    @Test func aSingleCategoryHasNothingToCycleThrough() {
        var palette = ClipboardPalette(entries: [
            entry("one", "first note"), entry("two", "second note", age: 1),
        ])

        palette.cycleCategory(by: 1)
        palette.cycleCategory(by: -1)

        #expect(palette.categories == [.text])
        #expect(palette.category == nil)
        #expect(!palette.isFiltered)
    }

    @Test func choosingAnAbsentCategoryShowsEverything() {
        var palette = ClipboardPalette(entries: history)
        palette.choose(.color)
        #expect(palette.rows.map(\.id) == ["color"])

        palette.choose(.media)
        #expect(palette.category == nil)
        #expect(palette.rows.count == 6)
    }

    @Test func searchCombinesWithTheCategoryAndSelectsTheFirstMatch() {
        var palette = ClipboardPalette(entries: history)
        palette.select("mail")
        palette.search("copy")
        #expect(palette.rows.map(\.id) == ["body", "link", "title"])
        #expect(palette.selectedID == "body")

        palette.choose(.link)
        #expect(palette.rows.map(\.id) == ["link"])

        palette.search("nothing matches")
        #expect(palette.rows.isEmpty)
        #expect(palette.selectedID == nil)
        #expect(palette.countLabel == "0 clips")
    }

    @Test func searchMatchesEveryWordAcrossPreviewAndSourceApp() {
        var palette = ClipboardPalette(entries: history)
        palette.search("  safari   show ")

        #expect(palette.rows.map(\.id) == ["title"])
        #expect(palette.countLabel == "1 clip")
    }

    @Test func resetClearsSearchAndCategory() {
        var palette = ClipboardPalette(entries: history)
        palette.search("copy")
        palette.choose(.link)
        palette.move(by: 1)
        palette.reset()

        #expect(palette.query.isEmpty)
        #expect(palette.category == nil)
        #expect(palette.rows.count == 6)
        #expect(palette.selectedID == "color")
    }

    @Test func refreshKeepsTheSelectedClipWhenItSurvives() {
        var palette = ClipboardPalette(entries: history)
        palette.select("link")
        palette.replace([entry("fresh", "new copy", age: 0)] + history)

        #expect(palette.selectedID == "link")
        #expect(palette.rows.first?.id == "fresh")
    }

    @Test func deletingTheSelectedClipSelectsItsNeighbour() {
        var palette = ClipboardPalette(entries: history)
        palette.select("link")
        palette.replace(history.filter { $0.id != "link" })
        #expect(palette.selectedID == "title")

        palette.jump(toTop: false)
        palette.replace(history.filter { $0.id != "link" && $0.id != "shot" })
        #expect(palette.selectedID == "mail")

        palette.replace([])
        #expect(palette.selectedID == nil)
    }

    @Test func refreshDropsACategoryThatDisappeared() {
        var palette = ClipboardPalette(entries: history)
        palette.choose(.color)
        palette.replace(history.filter { $0.id != "color" })

        #expect(palette.category == nil)
        #expect(!palette.categories.contains(.color))
        #expect(palette.rows.count == 5)
    }

    @Test func pinnedClipsLeadAndFollowThePreference() {
        var entries = history
        entries.append(entry("pin", "pinned note", age: 100, pinned: true))
        var palette = ClipboardPalette(entries: entries)
        #expect(palette.rows.first?.id == "pin")

        palette.setPinToTop(false)
        #expect(palette.rows.last?.id == "pin")
        #expect(palette.pinToTop == false)
        palette.setPinToTop(false)
        #expect(palette.rows.last?.id == "pin")
    }

    @Test func quickPickNumbersFollowTheVisibleRows() {
        let many = (0..<12).map { entry("e\($0)", "item \($0)", age: Double($0)) }
        var palette = ClipboardPalette(entries: many)

        #expect(palette.shortcut(for: "e0") == 1)
        #expect(palette.shortcut(for: "e8") == 9)
        #expect(palette.shortcut(for: "e9") == nil)
        #expect(palette.entry(forShortcut: 3)?.id == "e2")
        #expect(palette.entry(forShortcut: 0) == nil)
        #expect(palette.entry(forShortcut: 10) == nil)

        palette.search("item 1")
        #expect(palette.rows.map(\.id) == ["e1", "e10", "e11"])
        #expect(palette.shortcut(for: "e10") == 2)
        #expect(palette.entry(forShortcut: 4) == nil)
    }

    @Test func categoriesAreCachedPerEntry() {
        let palette = ClipboardPalette(entries: history)

        #expect(palette.category(of: history[0]) == .color)
        #expect(palette.category(of: history[2]) == .link)
        #expect(palette.category(of: entry("other", "www.example.com")) == .link)
    }

    @Test func duplicateIDsDoNotCrashTheCategoryIndex() {
        let twin = entry("color", "plain words", age: 50)
        let palette = ClipboardPalette(entries: history + [twin])

        #expect(palette.category(of: history[0]) == .color)
    }

    @Test func sectionsCoverTheRenderedPrefixOnly() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let palette = ClipboardPalette(entries: history)

        let all = palette.sections(now: Self.base, calendar: calendar)
        let limited = palette.sections(limit: 2, now: Self.base, calendar: calendar)
        let none = palette.sections(limit: -4, now: Self.base, calendar: calendar)

        #expect(all.flatMap(\.entries).count == 6)
        #expect(limited.flatMap(\.entries).map(\.id) == ["color", "body"])
        #expect(none.isEmpty)
    }
}
