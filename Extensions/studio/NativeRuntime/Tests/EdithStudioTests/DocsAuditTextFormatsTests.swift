import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct DocsAuditTextFormatsTests {
    typealias F = DocsAuditFixtures

    static let markdown = """
        # Release Plan

        Intro with **bold**, *italic*, `inline code` and a [link](https://example.com/docs?a=1).

        ## Tasks

        - Design
        - Build
          - Backend
          - Frontend
        - Ship

        1. Draft
        2. Review
           1. Legal review
        3. Publish

        ```swift
        let total = items.count
        print(total)
        ```

        | Item | Owner | Due |
        | --- | :---: | ---: |
        | Launch | Maya | May 1 |
        | Docs |  | May 9 |

        > Quoted remark.

        ![swatch](swatch.png)

        Closing line with Café, 東京 and 🎉.
        """

    @Test func markdownRendersHeadingsListsCodeTablesAndImages() async throws {
        let space = try Workspace()
        let url = space.url("plan.md")
        try Self.markdown.write(to: url, atomically: true, encoding: .utf8)
        try F.solidPNG(width: 60, height: 30, red: 1, green: 0, blue: 0).write(
            to: space.url("swatch.png"))
        let original = try Data(contentsOf: url)
        let result = try await space.run("document.to-pdf", [url])
        let document = try result.document()
        #expect(document.pageCount == 1)
        let text = Fixtures.text(of: try result.url())
        #expect(
            F.order(
                [
                    "Release Plan", "Intro with bold, italic, inline code and a link.", "Tasks",
                    "Design", "Build", "Backend", "Frontend", "Ship", "1. Draft", "2. Review",
                    "1. Legal review", "3. Publish", "let total = items.count", "print(total)",
                ], in: text))
        #expect(text.contains("Quoted remark."))
        #expect(text.contains("Closing line with Café, 東京"))
        func rect(_ needle: String) throws -> CGRect {
            try #require(F.find(needle, in: document).first?.rect)
        }
        #expect(abs(try rect("Owner").midY - rect("Item").midY) < 2)
        #expect(abs(try rect("Due").midY - rect("Item").midY) < 2)
        #expect(abs(try rect("Maya").midY - rect("Launch").midY) < 2)
        #expect(abs(try rect("May 9").midY - rect("Docs").midY) < 2)
        #expect(try rect("May 9").minX > rect("Maya").maxX)
        #expect(try rect("Launch").midY > rect("Docs").midY)
        let heading = try #require(F.fontSize(of: "Release Plan", in: document))
        let body = try #require(F.fontSize(of: "Intro with", in: document))
        #expect(heading > body * 1.8)
        let page = try #require(document.page(at: 0))
        #expect(F.redPixels(try StudioPDF.render(page, dpi: 72)) > 1000)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func htmlBecomesMarkdownWithNestedListsCodeAndTables() async throws {
        let space = try Workspace()
        let url = space.url("page.html")
        try """
        <html><head><style>h1{color:#c00}</style></head><body>
        <h1>Main Heading</h1><p>Para with <b>bold</b> and <a href="https://example.com/x">a link</a>.</p>
        <h2>Steps</h2>
        <ol><li>One<ol><li>One A</li><li>One B</li></ol></li><li>Two<ol><li>Two A</li></ol></li></ol>
        <ul><li>Loose</li></ul>
        <table border="1"><tr><th>Name</th><th>City</th></tr><tr><td><p>Ann</p><p>Lee</p></td><td>Oslo</td></tr></table>
        <pre>line one
          indented two</pre>
        <p>Image next <img src="swatch.png" width="40" height="20"></p>
        </body></html>
        """.write(to: url, atomically: true, encoding: .utf8)
        try F.solidPNG(width: 40, height: 20, red: 1, green: 0, blue: 0).write(
            to: space.url("swatch.png"))
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(
            markdown.contains(
                "# Main Heading\n\nPara with **bold** and [a link](https://example.com/x)."))
        #expect(markdown.contains("## Steps"))
        #expect(
            markdown.contains(
                "1. One\n   1. One A\n   2. One B\n2. Two\n   1. Two A\n- Loose"))
        #expect(markdown.contains("| Name | City |\n| --- | --- |\n| Ann Lee | Oslo |"))
        #expect(markdown.contains("```\nline one\n  indented two\n```"))
        #expect(markdown.contains("Image next"))
        let leak = markdown.contains("\u{FFFC}")
        #expect(leak == false)
        let text = try String(
            contentsOf: try await space.run("document.to-text", [url]).url(), encoding: .utf8)
        #expect(text.contains("Name\tCity\nAnn Lee\tOslo\n"))
        let textLeak = text.contains("\u{FFFC}")
        #expect(textLeak == false)

        let pdf = try await space.run("document.to-pdf", [url])
        let page = try #require(try pdf.document().page(at: 0))
        #expect(F.redPixels(try StudioPDF.render(page, dpi: 72)) > 300)
        #expect(Fixtures.text(of: try pdf.url()).contains("Main Heading"))
    }

    @Test func longHTMLAndPlainTextPaginateWithoutLosingLines() async throws {
        let space = try Workspace()
        let html = space.url("long.html")
        let rows = (1...400).map {
            "<p style=\"margin:0;font:14px/18px Helvetica\">Row \(String(format: "%04d", $0)) of the report</p>"
        }.joined()
        try "<html><body style=\"margin:0\">\(rows)</body></html>".write(
            to: html, atomically: true, encoding: .utf8)
        let htmlResult = try await space.run("document.to-pdf", [html], ["paper": .text("a4")])
        let htmlPages = try F.pages(try htmlResult.url())
        #expect(htmlPages.count >= 3)
        var last = 0
        for index in 1...400 {
            let marker = "Row \(String(format: "%04d", index)) of"
            let hits = htmlPages.enumerated().filter { $0.element.contains(marker) }.map(\.offset)
            #expect(hits.count == 1, "\(marker) appears on pages \(hits)")
            if let page = hits.first {
                #expect(page >= last)
                last = page
            }
        }
        let landscape = try await space.run(
            "document.to-pdf", [html], ["paper": .text("a4"), "orientation": .text("landscape")])
        let wide = try #require(try landscape.document().page(at: 0)?.bounds(for: .mediaBox))
        #expect(wide.width > wide.height)

        let text = space.url("log.txt")
        let lines = (1...700).map { "Entry \(String(format: "%04d", $0)) \u{2502} status ok" }
        try lines.joined(separator: "\n").write(to: text, atomically: true, encoding: .utf8)
        let textResult = try await space.run("document.to-pdf", [text])
        let textPages = try F.pages(try textResult.url())
        #expect(textPages.count >= 8)
        for index in stride(from: 1, through: 700, by: 7) {
            let marker = "Entry \(String(format: "%04d", index))"
            #expect(textPages.filter { $0.contains(marker) }.count == 1, "\(marker)")
        }
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [text]).url(), encoding: .utf8)
        #expect(markdown == lines.joined(separator: "\n") + "\n")
    }

    @Test func richTextKeepsStructure() async throws {
        let space = try Workspace()
        let rich = NSMutableAttributedString(
            string: "Memo Title\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 20)])
        rich.append(
            NSAttributedString(
                string: "Body text that is long enough to be a paragraph of the memo.\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let url = space.url("memo.rtf")
        try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        ).write(to: url)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(
            markdown
                == "# Memo Title\n\nBody text that is long enough to be a paragraph of the memo.\n")
        let pdf = try await space.run("document.to-pdf", [url])
        #expect(
            F.order(["Memo Title", "Body text that is long"], in: Fixtures.text(of: try pdf.url())))
    }

    @Test func emptyAndUnreadableTextDocumentsFailClearly() async throws {
        let space = try Workspace()
        for name in ["blank.txt", "blank.md", "blank.rtf", "blank.html", "blank.doc"] {
            let url = space.url(name)
            try Data().write(to: url)
            do {
                _ = try await space.run("document.to-pdf", [url])
                Issue.record("\(name) produced a PDF")
            } catch let error as StudioError {
                #expect(error.localizedDescription.contains(name))
            }
        }
        let whitespace = space.url("spaces.md")
        try "   \n\n  \n".write(to: whitespace, atomically: true, encoding: .utf8)
        await #expect(throws: StudioError.self) {
            try await space.run("document.to-pdf", [whitespace])
        }
        let broken = space.url("broken.rtf")
        try Data("{\\rtf1 unterminated {{{".utf8).write(to: broken)
        do {
            let result = try await space.run("document.to-pdf", [broken])
            #expect(Fixtures.text(of: try result.url()).contains("unterminated"))
        } catch let error as StudioError {
            #expect(error.localizedDescription.contains("broken.rtf"))
        }
    }
}
