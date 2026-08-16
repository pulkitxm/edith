import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardPasteQueueTests {
    private func entry(_ id: String, copiedAt: Date = Date()) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: id, types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: "Tests", sourceBundleID: "test.app", lastCopiedAt: copiedAt, size: id.count,
            preview: id)
    }

    @Test func entriesLeaveInFirstInFirstOutOrder() {
        var queue = ClipboardPasteQueue()
        queue.add(entry("first"), at: Date(timeIntervalSince1970: 1))
        queue.add(entry("second"), at: Date(timeIntervalSince1970: 2))

        #expect(queue.removeNext()?.id == "first")
        #expect(queue.removeNext()?.id == "second")
        #expect(queue.removeNext() == nil)
    }

    @Test func addingAnExistingEntryMovesItToTheBack() {
        var queue = ClipboardPasteQueue()
        queue.add(entry("first"), at: Date(timeIntervalSince1970: 1))
        queue.add(entry("second"), at: Date(timeIntervalSince1970: 2))
        queue.add(entry("first"), at: Date(timeIntervalSince1970: 3))

        #expect(queue.items.map(\.id) == ["second", "first"])
        #expect(queue.items.last?.queuedAt == Date(timeIntervalSince1970: 3))
    }

    @Test func removingByEntryIDReturnsTheRemovedItem() {
        var queue = ClipboardPasteQueue()
        queue.add(entry("first"))
        queue.add(entry("second"))

        #expect(queue.remove(id: "first")?.id == "first")
        #expect(queue.items.map(\.id) == ["second"])
        #expect(queue.remove(id: "missing") == nil)
    }

    @Test func clearingReturnsEveryRemovedItem() {
        var queue = ClipboardPasteQueue()
        queue.add(entry("first"))
        queue.add(entry("second"))

        #expect(queue.clear().map(\.id) == ["first", "second"])
        #expect(queue.items.isEmpty)
    }

    @Test func retainingDropsEntriesMissingFromHistory() {
        var queue = ClipboardPasteQueue()
        queue.add(entry("first"))
        queue.add(entry("second"))

        queue.retain(entryIDs: ["second"])

        #expect(queue.items.map(\.id) == ["second"])
    }

    @Test func bridgeRoundTripsResponsesAndUsesPerRequestNames() throws {
        let item = ClipboardQueueItem(
            entry: entry("first"), queuedAt: Date(timeIntervalSince1970: 5))
        let response = ClipboardQueueResponse(
            status: .ok, items: [item], item: item, changed: 1)

        #expect(ClipboardQueueBridge.decode(ClipboardQueueBridge.encode(response)) == response)
        #expect(
            ClipboardQueueBridge.responseName(requestID: "abc").rawValue
                == "com.pulkit.edith.clipboardQueueResponse.abc")
    }
}
