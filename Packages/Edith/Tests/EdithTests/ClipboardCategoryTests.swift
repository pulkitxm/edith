import Foundation
import Testing

@testable import EdithKit

@Suite struct ClipboardCategoryTests {
    private func entry(_ preview: String?, ext: String = "txt", types: [String] = [])
        -> ClipboardEntry
    {
        ClipboardEntry(
            sha256: UUID().uuidString, types: types.isEmpty ? ["public.utf8-plain-text"] : types,
            ext: ext, sourceApp: nil, sourceBundleID: nil, size: 1, preview: preview)
    }

    @Test(arguments: [
        "https://coprexlabs.com/copycat", "http://localhost:3000/health", "HTTPS://Example.COM",
        "www.apple.com", "www.apple.com/mac", "ssh://git@github.com/org/repo",
        "  https://example.com/path?q=1#frag\n", "ftp://files.example.org",
    ])
    func linksAreRecognised(text: String) {
        #expect(ClipboardCategory.classify(text: text) == .link)
    }

    @Test(arguments: [
        "support@example.com", "first.last+tag@mail.co.uk", "mailto:team@example.com",
        "MAILTO:team@example.com?subject=hi",
    ])
    func emailsAreRecognised(text: String) {
        #expect(ClipboardCategory.classify(text: text) == .email)
    }

    @Test(arguments: ["#ff26a1", "#FFF", "rgb(10, 20, 30)", "hsl(200 50% 40%)"])
    func colorsAreRecognised(text: String) {
        #expect(ClipboardCategory.classify(text: text) == .color)
    }

    @Test(arguments: [
        "", "   ", "SHOW HN: Copy everything. Choose when you paste.",
        "visit https://example.com today", "hello@", "@handle", "a@b", "user@@example.com",
        ".user@example.com", "user@-example.com", "user@example.c0m", "www.", "www.localhost",
        "javascript:alert(1)", "file:///Users/me/notes.txt", "https://", "#hashtag", "ff26a1",
        "/Users/me/Desktop/report.pdf", "user name@example.com",
    ])
    func everythingElseIsText(text: String) {
        #expect(ClipboardCategory.classify(text: text) == .text)
    }

    @Test func oversizedTextIsNeverParsed() {
        let long = "https://example.com/" + String(repeating: "a", count: 3000)
        #expect(ClipboardCategory.classify(text: long) == .text)
    }

    @Test func entryKindsMapOntoCategories() {
        #expect(ClipboardCategory(entry("PNG image", ext: "png")) == .image)
        #expect(ClipboardCategory(entry("clip.mov", ext: "mov")) == .media)
        #expect(ClipboardCategory(entry("report.pdf", ext: "url")) == .file)
        #expect(ClipboardCategory(entry("3 files", ext: "files")) == .file)
        #expect(ClipboardCategory(entry("Document", ext: "pdf")) == .file)
        #expect(ClipboardCategory(entry("archive", ext: "zip")) == .file)
        #expect(ClipboardCategory(entry("https://example.com", ext: "rtf")) == .link)
        #expect(ClipboardCategory(entry("#123456", ext: "html")) == .color)
        #expect(ClipboardCategory(entry(nil)) == .text)
    }

    @Test func imageLookingPreviewDoesNotOverrideTheStoredKind() {
        #expect(ClipboardCategory(entry("https://example.com/a.png", ext: "png")) == .image)
    }

    @Test func everyCategoryHasATitleAndSymbol() {
        let titles = ClipboardCategory.allCases.map(\.title)
        let symbols = ClipboardCategory.allCases.map(\.symbol)
        #expect(Set(titles).count == ClipboardCategory.allCases.count)
        #expect(Set(symbols).count == ClipboardCategory.allCases.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(ClipboardCategory.allCases.map(\.id) == ClipboardCategory.allCases.map(\.rawValue))
    }
}
