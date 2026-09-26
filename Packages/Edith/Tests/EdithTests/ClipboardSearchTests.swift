import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardSearchTests {
    private func entry(_ preview: String?, source: String?) -> ClipboardEntry {
        ClipboardEntry(
            sha256: UUID().uuidString, types: ["public.utf8-plain-text"], ext: "txt",
            sourceApp: source, sourceBundleID: nil, size: 1, preview: preview)
    }

    @Test func emptyOrBlankQueriesMatchEverything() {
        let clip = entry(nil, source: nil)

        #expect(ClipboardActions.matches(clip, query: ""))
        #expect(ClipboardActions.matches(clip, query: "   "))
    }

    @Test func everyWordMustAppearInThePreviewOrTheSourceApp() {
        let clip = entry("SHOW HN: Copy everything", source: "Safari")

        #expect(ClipboardActions.matches(clip, query: "copy"))
        #expect(ClipboardActions.matches(clip, query: "safari copy"))
        #expect(ClipboardActions.matches(clip, query: "hn everything"))
        #expect(!ClipboardActions.matches(clip, query: "copy notes"))
        #expect(!ClipboardActions.matches(clip, query: "paste"))
    }

    @Test func missingPreviewStillMatchesOnTheSourceApp() {
        let clip = entry(nil, source: "Preview")

        #expect(ClipboardActions.matches(clip, query: "preview"))
        #expect(!ClipboardActions.matches(entry(nil, source: nil), query: "preview"))
    }

    @Test func arrangeNormalisesTheQueryBeforeMatching() {
        let hit = entry("Deploy Notes", source: "Notes")
        let miss = entry("groceries", source: "Reminders")

        let result = ClipboardActions.arrange([hit, miss], query: "  DEPLOY  notes ")

        #expect(result == [hit])
    }
}
