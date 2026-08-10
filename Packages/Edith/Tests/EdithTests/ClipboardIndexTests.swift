import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardIndexTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func entry(_ id: String, age: TimeInterval, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: "sha-\(id)", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: "TextEdit", sourceBundleID: "com.apple.TextEdit",
            createdAt: now.addingTimeInterval(-age), size: 10, preview: "hello", pinned: pinned)
    }

    @Test func encodeDecodeRoundTrips() throws {
        let entries = [entry("a", age: 10), entry("b", age: 5, pinned: true)]
        let text = ClipboardIndex.encode(entries)
        #expect(text.hasSuffix("\n"))
        let decoded = ClipboardIndex.decode(text)
        #expect(decoded.count == 2)
        #expect(decoded.contains { $0.id == "a" && !$0.pinned })
        #expect(decoded.contains { $0.id == "b" && $0.pinned })
    }

    @Test func encodeLineAppendsToExistingIndex() {
        let base = ClipboardIndex.encode([entry("a", age: 10)])
        let line = ClipboardIndex.encodeLine(entry("b", age: 5))
        #expect(line != nil)
        let decoded = ClipboardIndex.decode(base + (line ?? ""))
        #expect(decoded.map(\.id) == ["a", "b"])
    }

    @Test func decodeSkipsGarbageLines() {
        let text = "not json\n{\"broken\n"
        #expect(ClipboardIndex.decode(text).isEmpty)
    }

    @Test func retentionTrimsOldestUnpinnedBeyondMaxItems() {
        let entries = (0..<5).map { entry("\($0)", age: TimeInterval($0)) }
        let kept = ClipboardIndex.applyRetention(entries, maxItems: 3, maxAge: nil, now: now)
        #expect(kept.count == 3)
        #expect(kept.map(\.id).sorted() == ["0", "1", "2"])
    }

    @Test func retentionNeverDropsPinnedItemsForCount() {
        var entries = (0..<5).map { entry("\($0)", age: TimeInterval($0)) }
        entries[4].pinned = true
        let kept = ClipboardIndex.applyRetention(entries, maxItems: 2, maxAge: nil, now: now)
        #expect(kept.contains { $0.id == "4" })
        #expect(kept.filter { !$0.pinned }.count == 2)
    }

    @Test func retentionExpiresOldUnpinnedButKeepsPinned() {
        let entries = [
            entry("fresh", age: 10),
            entry("old", age: 100_000),
            entry("oldPinned", age: 100_000, pinned: true),
        ]
        let kept = ClipboardIndex.applyRetention(
            entries, maxItems: 200, maxAge: 86400, now: now)
        #expect(kept.contains { $0.id == "fresh" })
        #expect(kept.contains { $0.id == "oldPinned" })
        #expect(!kept.contains { $0.id == "old" })
    }
}
