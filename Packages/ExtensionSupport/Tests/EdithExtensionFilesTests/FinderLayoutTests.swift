import Testing

@testable import EdithExtensionFiles
import EdithExtensionSupport

@Suite struct FinderLayoutTests {
    private func layout(_ width: Double, sidebar: Bool = true) -> FinderLayout {
        FinderLayout(width: width, sidebarRequested: sidebar, point: { $0 })
    }

    @Test func aWideBrowserShowsEverything() {
        let wide = layout(1100)
        #expect(wide.showsSidebar)
        #expect(wide.fitsSidebar)
        #expect(!wide.compactToolbar)
        #expect(wide.columns == [.modified, .size, .kind])
    }

    @Test func aNarrowPaneDropsTheSidebarAndCompactsTheToolbar() {
        let narrow = layout(520)
        #expect(!narrow.showsSidebar)
        #expect(!narrow.fitsSidebar)
        #expect(narrow.compactToolbar)
        #expect(narrow.columns == [.modified, .size])
    }

    @Test func columnsDropKindFirstThenSizeThenDate() {
        #expect(layout(600, sidebar: false).columns == [.modified, .size, .kind])
        #expect(layout(520, sidebar: false).columns == [.modified, .size])
        #expect(layout(430, sidebar: false).columns == [.modified])
        #expect(layout(360, sidebar: false).columns.isEmpty)
    }

    @Test func theSidebarTakesItsWidthFromTheColumns() {
        #expect(layout(700).showsSidebar)
        #expect(layout(700).columns == [.modified, .size])
        #expect(layout(700, sidebar: false).columns == [.modified, .size, .kind])
    }

    @Test func anUnmeasuredBrowserKeepsTheFullLayout() {
        let unmeasured = layout(0, sidebar: false)
        #expect(!unmeasured.showsSidebar)
        #expect(unmeasured.fitsSidebar)
        #expect(!unmeasured.compactToolbar)
        #expect(unmeasured.columns == FinderListColumn.allCases)
    }

    @Test func zoomScalesEveryThreshold() {
        let zoomed = FinderLayout(width: 700, sidebarRequested: true, point: { $0 * 1.3 })
        #expect(!zoomed.showsSidebar)
        #expect(zoomed.compactToolbar)
    }
}
