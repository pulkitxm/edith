import Foundation
import PDFKit
import Testing

#if canImport(Translation)
import Translation
#endif

@testable import EdithStudio

@Suite struct LayoutTranslationTests {
    @Test func blocksGroupLinesIntoParagraphs() throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Fixtures.structuredPDF(at: source)
        let document = try #require(PDFDocument(url: source))
        let blocks = LayoutTranslation.blocks(of: document)
        let texts = blocks.map(\.text)
        #expect(texts.contains("Quarterly Report"))
        #expect(
            texts.contains(
                "Revenue grew across every region this quarter. Costs stayed flat while hiring continued."
            ))
        #expect(blocks.allSatisfy { $0.rect.width > 0 && $0.rect.height > 0 })
        let cells = blocks.filter(\.isCell).map(\.text)
        #expect(cells.contains("Region") && cells.contains("140"))
        #expect(blocks.first { $0.text == "Q1" }?.translatable == false)
        #expect(blocks.first { $0.text == "140" }?.translatable == false)
        #expect(blocks.first { $0.text == "Highlights" }?.translatable == true)
        #expect(blocks.filter { $0.text.hasPrefix("•") }.count == 2)
    }

    @Test func layoutTranslationDrawsOverTheOriginalPage() async throws {
        let space = try Workspace()
        let source = space.url("letter.pdf")
        try Fixtures.pdf(
            at: source, pages: ["The meeting starts at noon.\n\nPlease bring your laptop."],
            fontSize: 18)
        let document = try #require(PDFDocument(url: source))
        let blocks = LayoutTranslation.blocks(of: document)
        let output = space.url("translated.pdf")
        try LayoutTranslation.write(
            document, blocks: blocks, translations: blocks.map { "ES " + $0.text }, to: output
        ) { _ in }
        let text = Fixtures.text(of: output)
        #expect(text.contains("ES The meeting starts at noon."))
        #expect(PDFDocument(url: output)?.pageCount == 1)
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            let status = await LanguageAvailability().status(
                from: Locale.Language(identifier: "en"), to: Locale.Language(identifier: "es"))
            guard status == .installed else { return }
            let result = try await space.run(
                "ai.translate", [source], ["target": .text("es"), "format": .text("pdf")])
            let translated = Fixtures.text(of: try result.url())
            #expect(try result.url().pathExtension == "pdf")
            #expect(translated.count > text.count / 2)
        }
        #endif
    }
}
