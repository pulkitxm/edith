import Foundation
import Testing

@testable import Edith
@testable import EdithDocs

@Suite @MainActor struct DocsBrowserCacheTests {
    @Test func cachedLibraryIsReadyWithoutAnotherParse() {
        _ = DocsLibrary.bundled()
        #expect(DocsLibrary.cached() != nil)
        let reads = DocsLibrary.bundleReads
        let browser = DocsBrowser()
        #expect(browser.library != nil)
        #expect(DocsLibrary.bundleReads == reads)
    }

    @Test func sidebarFilterWaitsUntilTypingPauses() async {
        let library = DocsLibrary(sources: [
            DocsSource(path: "README.md", markdown: "# Overview\n\nStart"),
            DocsSource(path: "herdr/ls.md", markdown: "# `ed herdr ls`\n\nLists panes"),
        ])
        let calls = FilterCalls()
        let browser = DocsBrowser(
            library: library,
            matchPages: { groups, filter in
                #expect(!Thread.isMainThread)
                calls.count += 1
                return DocsNavigation.visibleGroups(groups, filter: filter)
            }, filterDelay: .milliseconds(80))

        browser.noteFilter("h")
        browser.noteFilter("he")
        browser.noteFilter("her")
        #expect(calls.count == 0)
        await browser.settleFilter()
        #expect(calls.count == 1)
        #expect(browser.sidebarGroups.count == 1)
    }

    @Test func sameCodeBlockHighlightsOnce() async {
        let calls = FilterCalls()
        let cache = DocsCodeHighlight { _, _, _ in
            calls.count += 1
            return AttributedString("highlighted")
        }
        let first = await cache.highlight(
            text: "echo unique-docs-fence", language: "bash", dark: true)
        let second = await cache.highlight(
            text: "echo unique-docs-fence", language: "bash", dark: true)
        #expect(first == AttributedString("highlighted"))
        #expect(second == first)
        #expect(calls.count == 1)
    }
}

private final class FilterCalls: @unchecked Sendable {
    var count = 0
}
