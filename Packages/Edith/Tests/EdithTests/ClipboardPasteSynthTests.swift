import AppKit
import Testing

@testable import EdithHelper

@Suite @MainActor struct ClipboardPasteSynthTests {
    @Test func snapshotRestoresEveryItemAndRepresentation() throws {
        let pasteboard = NSPasteboard(name: .init("test.text-utilities.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(Data([1, 2, 3]), forType: .rtf)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .init("public.url"))
        pasteboard.writeObjects([first, second])

        let snapshot = ClipboardPasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary", forType: .string)
        snapshot.restore(to: pasteboard)

        let items = try #require(pasteboard.pasteboardItems)
        #expect(items.count == 2)
        #expect(items[0].string(forType: .string) == "hello")
        #expect(items[0].data(forType: .rtf) == Data([1, 2, 3]))
        #expect(items[1].string(forType: .init("public.url")) == "https://example.com")
    }
}
