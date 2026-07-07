import EdithKit
import Foundation
import Testing
@testable import EdithMenuBar

@Suite(.serialized) struct ClipboardPanelHeightTests {
    private func entry(ext: String) -> ClipboardEntry {
        ClipboardEntry(
            sha256: UUID().uuidString, types: ["public.utf8-plain-text"], ext: ext,
            sourceApp: nil, sourceBundleID: nil, size: 10, preview: "hello")
    }

    private func withFooter(_ show: Bool, _ body: () -> Void) {
        let key = "clipboardShowFooter"
        let saved = SharedDefaults.store.object(forKey: key)
        defer {
            if let saved {
                SharedDefaults.store.set(saved, forKey: key)
            } else {
                SharedDefaults.store.removeObject(forKey: key)
            }
        }
        SharedDefaults.store.set(show, forKey: key)
        body()
    }

    @Test func emptyHistoryStillReservesOneRow() {
        withFooter(false) {
            let headerPlusRowPlusPadding: CGFloat = 62
            #expect(ClipboardPanelView.estimatedHeight(entries: []) == headerPlusRowPlusPadding)
        }
    }

    @Test func textRowsAreShorterThanImageRows() {
        withFooter(false) {
            let text = ClipboardPanelView.estimatedHeight(entries: [entry(ext: "txt")])
            let image = ClipboardPanelView.estimatedHeight(entries: [entry(ext: "png")])
            #expect(image - text == 24)
        }
    }

    @Test func footerAddsFixedHeight() {
        var without: CGFloat = 0
        var with: CGFloat = 0
        withFooter(false) { without = ClipboardPanelView.estimatedHeight(entries: []) }
        withFooter(true) { with = ClipboardPanelView.estimatedHeight(entries: []) }
        #expect(with - without == 55)
    }

    @Test func heightGrowsPerEntry() {
        withFooter(false) {
            let one = ClipboardPanelView.estimatedHeight(entries: [entry(ext: "txt")])
            let three = ClipboardPanelView.estimatedHeight(
                entries: [entry(ext: "txt"), entry(ext: "txt"), entry(ext: "txt")])
            #expect(three - one == 48)
        }
    }
}
