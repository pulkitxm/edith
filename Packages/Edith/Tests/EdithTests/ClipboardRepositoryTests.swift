import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardRepositoryTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func entry(_ id: String, age: TimeInterval, pinned: Bool = false) -> ClipboardEntry {
        ClipboardEntry(
            id: id, sha256: "sha-\(id)", types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: "TextEdit", sourceBundleID: "com.apple.TextEdit",
            createdAt: now.addingTimeInterval(-age), size: 10, preview: "hello", pinned: pinned)
    }

    @Test func sha256HexMatchesKnownVectorForAbc() {
        let digest = ClipboardRepository.sha256Hex(Data("abc".utf8))
        #expect(digest == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func sha256HexMatchesKnownVectorForEmptyData() {
        let digest = ClipboardRepository.sha256Hex(Data())
        #expect(digest == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    }

    @Test func encodedEntriesRoundTripWithFullFieldFidelity() {
        let entries = [entry("a", age: 10), entry("b", age: 5, pinned: true)]
        let decoded = ClipboardIndex.decode(ClipboardIndex.encode(entries))
        #expect(decoded == entries)
    }

    @Test func appendedLineRoundTripsWithFullFieldFidelity() throws {
        let base = ClipboardIndex.encode([entry("a", age: 10)])
        let line = try #require(ClipboardIndex.encodeLine(entry("b", age: 5)))
        let decoded = ClipboardIndex.decode(base + line)
        #expect(decoded == [entry("a", age: 10), entry("b", age: 5)])
    }

    @Test func garbageLineAmongValidLinesIsSkippedNotFatal() throws {
        let good = [entry("a", age: 10), entry("b", age: 5)]
        let first = try #require(ClipboardIndex.encodeLine(good[0]))
        let second = try #require(ClipboardIndex.encodeLine(good[1]))
        let text = first + "{\"broken\n" + "not json at all\n" + second
        let decoded = ClipboardIndex.decode(text)
        #expect(decoded == good)
    }

    @Test func blankLinesAreIgnored() throws {
        let line = try #require(ClipboardIndex.encodeLine(entry("a", age: 10)))
        let decoded = ClipboardIndex.decode("\n\n" + line + "\n\n")
        #expect(decoded == [entry("a", age: 10)])
    }
}
