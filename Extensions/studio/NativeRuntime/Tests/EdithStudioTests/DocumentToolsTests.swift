import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct DocumentToolsTests {
    @Test func wordDocumentBecomesSearchablePDF() async throws {
        let space = try Workspace()
        let source = space.url("plan.docx")
        try DocumentFixtures.docx(at: source)
        let result = try await space.run("document.to-pdf", [source])
        let text = Fixtures.text(of: try result.url())
        #expect(text.contains("Project Plan"))
        #expect(text.contains("Paragraph 2 explains important details"))
        #expect(text.contains("Launch"))
        #expect(try result.url().lastPathComponent == "plan.pdf")
    }

    @Test func longDocumentsPaginate() async throws {
        let space = try Workspace()
        let source = space.url("long.txt")
        let body = (1...400).map { "Line number \($0) of a long plain text document." }
        try body.joined(separator: "\n").write(to: source, atomically: true, encoding: .utf8)
        let result = try await space.run(
            "document.word-to-pdf", [source], ["paper": .text("letter"), "margin": .text("72")])
        let document = try result.document()
        #expect(document.pageCount >= 5)
        let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 612) < 1 && abs(box.height - 792) < 1)
        #expect(
            document.page(at: document.pageCount - 1)?.string?.contains("Line number 400") == true)
        let landscape = try await space.run(
            "document.to-pdf", [source], ["paper": .text("a4"), "orientation": .text("landscape")])
        let wide = try #require(try landscape.document().page(at: 0)?.bounds(for: .mediaBox))
        #expect(wide.width > wide.height)
    }

    @Test func markdownRichTextAndHTMLRender() async throws {
        let space = try Workspace()
        let markdown = space.url("notes.md")
        try
            "# Release Notes\n\nSome **bold** text and a [link](https://example.com).\n\n- First item\n- Second item\n\n1. Alpha\n2. Beta\n"
            .write(to: markdown, atomically: true, encoding: .utf8)
        let markdownText = Fixtures.text(
            of: try await space.run("document.to-pdf", [markdown]).url())
        #expect(markdownText.contains("Release Notes"))
        #expect(markdownText.contains("Second item"))
        #expect(markdownText.contains("•"))

        let rich = space.url("memo.rtf")
        let attributed = NSAttributedString(
            string: "Confidential memo body", attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let rtf = try attributed.data(
            from: NSRange(location: 0, length: attributed.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtf.write(to: rich)
        #expect(
            Fixtures.text(of: try await space.run("document.to-pdf", [rich]).url()).contains(
                "Confidential memo"))

        let html = space.url("page.html")
        try "<html><body><h1>Status Page</h1><p>All systems operational.</p></body></html>"
            .write(to: html, atomically: true, encoding: .utf8)
        let htmlResult = try await space.run("document.to-pdf", [html])
        #expect(Fixtures.text(of: try htmlResult.url()).contains("All systems operational"))
    }

    @Test func spreadsheetsBecomeTables() async throws {
        let space = try Workspace()
        let workbook = space.url("book.xlsx")
        try DocumentFixtures.xlsx(at: workbook, rows: 120)
        let result = try await space.run("document.excel-to-pdf", [workbook])
        let document = try result.document()
        #expect(document.pageCount >= 3)
        let first = document.page(at: 0)?.string ?? ""
        #expect(first.contains("Sales"))
        #expect(first.contains("Region 1"))
        #expect(first.contains("1000"))
        let second = document.page(at: 1)?.string ?? ""
        #expect(second.contains("Revenue"))
        let all = Fixtures.text(of: try result.url())
        #expect(all.contains("Maya Chen"))

        let csv = space.url("people.csv")
        try "name,city\n\"Doe, Jane\",Berlin\nSam,\"New\nYork\"\n".write(
            to: csv, atomically: true, encoding: .utf8)
        let csvText = Fixtures.text(of: try await space.run("document.to-pdf", [csv]).url())
        #expect(csvText.contains("Doe, Jane"))
        #expect(csvText.contains("Berlin"))
    }

    @Test func xlsxReaderHandlesSharedStringsDatesAndBooleans() throws {
        let space = try Workspace()
        let url = space.url("shared.xlsx")
        try DocumentFixtures.sharedStringsXLSX(at: url)
        let sheets = try SpreadsheetReader.read(url)
        #expect(sheets.count == 1)
        #expect(sheets[0].name == "Data")
        #expect(sheets[0].rows[0] == ["Item", "", "Due date"])
        #expect(sheets[0].rows[1] == ["Widget", "2.5", "2023-03-15", "FALSE"])
    }

    @Test func csvParserHandlesQuotesAndDelimiters() {
        #expect(
            CSVParser.parse("a,b\n1,\"x, y\"\n", delimiter: nil) == [["a", "b"], ["1", "x, y"]])
        #expect(
            CSVParser.parse("a;b\n\"say \"\"hi\"\"\";2", delimiter: nil) == [
                ["a", "b"], ["say \"hi\"", "2"],
            ])
        #expect(CSVParser.parse("a\tb\n1\t2", delimiter: "\t") == [["a", "b"], ["1", "2"]])
    }

    @Test func presentationsRenderOneSlidePerPage() async throws {
        let space = try Workspace()
        let deck = space.url("review.pptx")
        try DocumentFixtures.pptx(at: deck)
        let result = try await space.run("document.powerpoint-to-pdf", [deck])
        let document = try result.document()
        #expect(document.pageCount == 2)
        let box = try #require(document.page(at: 0)?.bounds(for: .mediaBox))
        #expect(abs(box.width - 720) < 1 && abs(box.height - 405) < 1)
        let first = document.page(at: 0)?.string ?? ""
        #expect(first.contains("Quarterly Review"))
        #expect(first.contains("Revenue up 12 percent"))
        #expect(document.page(at: 1)?.string?.contains("Hire two engineers") == true)
        let page = try #require(document.page(at: 1))
        let image = try StudioPDF.render(page, dpi: 36)
        let corner = Fixtures.pixel(image, x: 2, y: 2)
        #expect(corner.r > 235 && corner.g > 230 && corner.b > 220 && corner.b < 240)

        let slides = try PresentationRenderer.text(deck)
        #expect(slides.first?.title == "Quarterly Review")
        #expect(slides.first?.lines == ["Revenue up 12 percent", "Two launches shipped"])
    }

    @Test func titleUsesLayoutPlaceholderPosition() async throws {
        let space = try Workspace()
        let deck = space.url("layout.pptx")
        try DocumentFixtures.pptx(at: deck)
        let result = try await space.run("document.to-pdf", [deck])
        let page = try #require(try result.document().page(at: 0))
        let selection = try #require(page.selection(for: NSRange(location: 0, length: 9)))
        let bounds = selection.bounds(for: page)
        #expect(bounds.midY > 405 - 180)
        #expect(bounds.midY < 405 - 120)
    }

    @Test func markdownAndTextExtraction() async throws {
        let space = try Workspace()
        let source = space.url("plan.docx")
        try DocumentFixtures.docx(at: source)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [source]).url())
        #expect(markdown.contains("# Project Plan"))
        #expect(markdown.contains("**important**"))
        #expect(markdown.contains("| Name | Owner |"))

        let html = space.url("list.html")
        try
            "<h2>Agenda</h2><ul><li>Intro</li><li>Demo <a href=\"https://example.com\">site</a></li></ul><ol><li>One</li><li>Two</li></ol>"
            .write(to: html, atomically: true, encoding: .utf8)
        let htmlMarkdown = try String(
            contentsOf: try await space.run("document.to-markdown", [html]).url())
        #expect(htmlMarkdown.contains("Agenda"))
        #expect(htmlMarkdown.contains("- Intro"))
        #expect(htmlMarkdown.contains("[site](https://example.com"))
        #expect(htmlMarkdown.contains("2. Two"))

        let deck = space.url("deck.pptx")
        try DocumentFixtures.pptx(at: deck)
        let deckMarkdown = try String(
            contentsOf: try await space.run("document.to-markdown", [deck]).url())
        #expect(deckMarkdown.contains("## Slide 1: Quarterly Review"))
        #expect(deckMarkdown.contains("- Two launches shipped"))

        let workbook = space.url("book.xlsx")
        try DocumentFixtures.xlsx(at: workbook)
        let sheetMarkdown = try String(
            contentsOf: try await space.run("document.to-markdown", [workbook]).url())
        #expect(sheetMarkdown.contains("## Sales"))
        #expect(sheetMarkdown.contains("| Region | Revenue | Active |"))

        let text = try String(contentsOf: try await space.run("document.to-text", [deck]).url())
        #expect(text.contains("Slide 2: Next Steps"))
    }

    @Test func legacyWordAndOpenDocumentFormats() async throws {
        let space = try Workspace()
        let attributed = NSAttributedString(
            string: "Legacy format body text", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let range = NSRange(location: 0, length: attributed.length)
        for (name, type) in [
            ("old.doc", NSAttributedString.DocumentType.docFormat),
            ("open.odt", NSAttributedString.DocumentType.openDocument),
        ] {
            let url = space.url(name)
            try attributed.data(from: range, documentAttributes: [.documentType: type]).write(
                to: url)
            let result = try await space.run("document.to-pdf", [url])
            #expect(Fixtures.text(of: try result.url()).contains("Legacy format body text"))
        }
    }

    @Test func appPackagesExplainHowToExport() async throws {
        let space = try Workspace()
        let pages = space.url("letter.pages")
        try Data("x".utf8).write(to: pages)
        await #expect(throws: StudioError.self) {
            try await space.run("document.to-pdf", [pages])
        }
        do {
            _ = try await space.run("document.to-pdf", [pages])
        } catch {
            #expect(error.localizedDescription.contains("Pages"))
        }
    }
}
