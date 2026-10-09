import AppKit
import Foundation
import Testing
@testable import EdithExtensionDocuments

@Suite struct DocumentRenderingTests {
    @Test func privateDocumentResourcesLoadThemesAndLanguages() throws {
        let renderer = try #require(Highlighter())
        #expect(renderer.setTheme("atom-one-dark"))
        #expect(renderer.supportedLanguages().contains("markdown"))
        #expect(renderer.highlight("let value = 17", as: "swift")?.string == "let value = 17")
        #expect(renderer.availableThemes().contains("atom-one-light"))
    }

    @Test func highlightingUsesContentAndRejectsExcessiveInput() async throws {
        let renderer = SyntaxHighlighting()
        let first = await renderer.highlight(text: "let value = 17", language: "swift", dark: true)
        let second = await renderer.highlight(text: "let value = 23", language: "swift", dark: true)
        #expect(first?.string == "let value = 17")
        #expect(second?.string == "let value = 23")
        #expect(
            await renderer.highlight(
                text: String(repeating: "a", count: 400_000), language: "swift", dark: true) == nil)
        #expect(await SyntaxHighlighting.languageName(for: "md") == "markdown")
    }

    @Test func textZoomScalesFontWithoutChangingSource() {
        let source = NSAttributedString(
            string: "synthetic code",
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)])
        let scaled = PreviewTextScale.attributed(source, scale: 1.5)
        #expect(scaled.string == source.string)
        #expect((scaled.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 18)
    }
}
