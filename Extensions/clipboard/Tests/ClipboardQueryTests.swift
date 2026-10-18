import Foundation
import Testing

@testable import ClipboardExtension

@Suite struct ClipboardQueryTests {
    @MainActor
    @Test func latestGenerationWinsAndWorkLeavesTheMainActor() async {
        let thread = ClipboardQueryThreadFlag()
        ClipboardQuery.recordThread = { thread.main = Thread.isMainThread }
        defer { ClipboardQuery.recordThread = nil }
        let entries = (0..<20).map { index in
            ClipboardEntry(
                sha256: "sha-\(index)", types: ["public.utf8-plain-text"], ext: "txt",
                sourceApp: "Notes", sourceBundleID: nil, size: 1, preview: "item \(index)")
        }
        async let older = ClipboardQuery.shared.clipboardRows(
            entries: entries, query: "item 1", category: nil, pinToTop: true, generation: 1)
        async let newer = ClipboardQuery.shared.clipboardRows(
            entries: entries, query: "item 12", category: nil, pinToTop: true, generation: 2)
        let first = await older
        let second = await newer
        #expect(thread.main == false)
        #expect(
            !ClipboardQuery.shouldApply(generation: first.generation, current: second.generation))
        #expect(ClipboardQuery.shouldApply(generation: second.generation, current: 2))
        #expect(second.rows.map(\.preview) == ["item 12"])
    }

}

private final class ClipboardQueryThreadFlag: @unchecked Sendable {
    var main = true
}
