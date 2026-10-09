import AppKit
import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct DocsAuditWordTests {
    typealias F = DocsAuditFixtures

    static func report(at url: URL) throws {
        let body =
            F.text("Annual Report", style: "Title")
            + F.text("Introduction", style: "Heading1")
            + F.paragraph(
                F.run("The quar") + F.run("terly", bold: true) + F.run(" results were ")
                    + F.run("strong", italic: true) + F.run("."))
            + F.text("Details", style: "Heading2")
            + F.text("Deeper", style: "Heading3")
            + F.paragraph(F.run("First step"), style: "ListParagraph", list: (1, 0))
            + F.paragraph(F.run("Nested step"), style: "ListParagraph", list: (1, 1))
            + F.paragraph(F.run("Second step"), style: "ListParagraph", list: (1, 0))
            + F.paragraph(F.run("Bullet one"), style: "ListParagraph", list: (2, 0))
            + F.paragraph(F.run("Bullet two"), style: "ListParagraph", list: (2, 0))
            + F.paragraph(F.run("Visit ") + F.hyperlink("our site") + F.run(" today."))
            + F.table(
                [
                    F.cell("Merged header", width: 6000, properties: #"<w:gridSpan w:val="2"/>"#)
                        + F.cell("Q3"),
                    F.cell("North") + F.cell("120") + F.cell("140"),
                    F.cell("South") + F.cell("95") + F.cell("101"),
                ], columns: 3)
            + F.paragraph(F.run("Chart below:") + F.inlineImage(width: 144, height: 72))
            + F.pageBreak
            + F.text("After the page break.")
            + F.sectionBreak(landscape: false, headers: true)
            + F.text("Wide section text.")
        try F.wordDOCX(
            at: url, body: body,
            finalSection: F.sectionProperties(landscape: true, headers: true),
            headerText: "Confidential Header", footerText: "Footer text",
            image: try F.solidPNG(width: 40, height: 20, red: 1, green: 0, blue: 0))
    }

    @Test func wordStylesListsLinksAndTablesBecomeMarkdown() async throws {
        let space = try Workspace()
        let url = space.url("report.docx")
        try Self.report(at: url)
        let original = try Data(contentsOf: url)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(
            markdown.hasPrefix(
                "# Annual Report\n\n# Introduction\n\nThe quar**terly** results were *strong*.\n\n## Details\n\n### Deeper\n\n"
            ))
        #expect(
            markdown.contains(
                "1. First step\n   1. Nested step\n2. Second step\n- Bullet one\n- Bullet two\n\n"))
        #expect(
            markdown.contains("Visit [our site](https://example.com/report?id=7&view=full) today."))
        #expect(
            markdown.contains(
                "| Merged header |  | Q3 |\n| --- | --- | --- |\n| North | 120 | 140 |\n| South | 95 | 101 |"
            ))
        #expect(markdown.contains("Chart below:\n\nAfter the page break.\n\nWide section text.\n"))
        let leaks = markdown.contains("\u{FFFC}") || markdown.contains("\u{0C}")
        #expect(leaks == false)
        let headerLeak = markdown.contains("Confidential Header")
        #expect(headerLeak == false)

        let text = try String(
            contentsOf: try await space.run("document.to-text", [url]).url(), encoding: .utf8)
        #expect(
            text.contains(
                "1.\tFirst step\na.\tNested step\n2.\tSecond step\n\u{2022}\tBullet one\n\u{2022}\tBullet two\n"
            ))
        #expect(text.contains("Merged header\t\tQ3\nNorth\t120\t140\nSouth\t95\t101\n"))
        let textLeaks = text.contains("\u{FFFC}") || text.contains("\u{0C}")
        #expect(textLeaks == false)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func wordToPDFKeepsStylesImagesTablesSectionsHeadersAndFooters() async throws {
        let space = try Workspace()
        let url = space.url("report.docx")
        try Self.report(at: url)
        let original = try Data(contentsOf: url)
        let result = try await space.run("document.word-to-pdf", [url])
        let document = try result.document()
        #expect(document.pageCount == 3)
        let sizes = (0..<document.pageCount).compactMap {
            document.page(at: $0)?.bounds(for: .mediaBox).size
        }
        #expect(
            sizes == [
                CGSize(width: 612, height: 792), CGSize(width: 612, height: 792),
                CGSize(width: 792, height: 612),
            ])
        let pages = try F.pages(try result.url())
        for (index, page) in pages.enumerated() {
            #expect(page.contains("Confidential Header"), "header missing on page \(index + 1)")
            #expect(
                page.contains("Footer text \(index + 1)"), "footer missing on page \(index + 1)")
        }
        #expect(
            F.order(
                [
                    "Annual Report", "Introduction", "The quarterly results were strong.",
                    "Details",
                    "Deeper", "1. First step", "a. Nested step", "2. Second step",
                    "\u{2022} Bullet one", "Visit our site today.",
                ], in: pages[0]))
        #expect(pages[1].contains("After the page break."))
        let early = pages[0].contains("After the page break.")
        #expect(early == false)
        #expect(pages[2].contains("Wide section text."))

        let title = try #require(F.fontSize(of: "Annual Report", in: document))
        let heading = try #require(F.fontSize(of: "Introduction", in: document))
        let body = try #require(F.fontSize(of: "results were", in: document))
        #expect(abs(title - 28) < 0.5)
        #expect(abs(heading - 16) < 0.5)
        #expect(abs(body - 11) < 0.5)

        func row(_ name: String) throws -> CGRect {
            try #require(F.find(name, in: document).first?.rect)
        }
        #expect(abs(try row("Q3").midY - row("Merged header").midY) < 2)
        #expect(abs(try row("140").midY - row("North").midY) < 2)
        #expect(abs(try row("101").midY - row("South").midY) < 2)
        #expect(try row("North").midY > row("South").midY)
        #expect(try row("120").minX > row("North").maxX)
        #expect(try row("140").minX > row("120").maxX)

        let page = try #require(document.page(at: 0))
        let image = try StudioPDF.render(page, dpi: 36)
        #expect(F.redPixels(image) > 1500)
        let link = page.annotations.contains { $0.url?.host == "example.com" }
        let linkedText = (page.attributedString?.string ?? "").contains("our site")
        #expect(link || linkedText)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func pageSettingsOverrideEverySection() async throws {
        let space = try Workspace()
        let url = space.url("report.docx")
        try Self.report(at: url)
        let result = try await space.run(
            "document.to-pdf", [url], ["paper": .text("a4"), "orientation": .text("landscape")])
        let document = try result.document()
        #expect(document.pageCount >= 3)
        for index in 0..<document.pageCount {
            let size = try #require(document.page(at: index)?.bounds(for: .mediaBox).size)
            #expect(abs(size.width - 841.89) < 1 && abs(size.height - 595.28) < 1)
        }
    }

    @Test func numberingRestartsContinuesAndFormatsEveryLevel() async throws {
        let space = try Workspace()
        let url = space.url("numbers.docx")
        let numbering =
            F.header
            + #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
            + #"<w:abstractNum w:abstractNumId="7"><w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl><w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2"/></w:lvl></w:abstractNum>"#
            + #"<w:abstractNum w:abstractNumId="8"><w:lvl w:ilvl="0"><w:start w:val="3"/><w:numFmt w:val="decimal"/><w:lvlText w:val="(%1)"/></w:lvl></w:abstractNum>"#
            + #"<w:num w:numId="1"><w:abstractNumId w:val="7"/></w:num>"#
            + #"<w:num w:numId="2"><w:abstractNumId w:val="8"/></w:num>"#
            + #"<w:num w:numId="3"><w:abstractNumId w:val="8"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="1"/></w:lvlOverride></w:num>"#
            + "</w:numbering>"
        let body =
            F.paragraph(F.run("Scope"), list: (1, 0))
            + F.paragraph(F.run("Inside scope"), list: (1, 1))
            + F.paragraph(F.run("Also inside"), list: (1, 1))
            + F.paragraph(F.run("Budget"), list: (1, 0))
            + F.paragraph(F.run("Budget detail"), list: (1, 1))
            + F.text("Interlude paragraph.")
            + F.paragraph(F.run("Third item"), list: (2, 0))
            + F.paragraph(F.run("Fourth item"), list: (2, 0))
            + F.paragraph(F.run("Restarted item"), list: (3, 0))
        try F.wordDOCX(at: url, body: body, numberingXML: numbering)
        let text = try String(
            contentsOf: try await space.run("document.to-text", [url]).url(), encoding: .utf8)
        #expect(
            text
                == "I.\tScope\nI.1\tInside scope\nI.2\tAlso inside\nII.\tBudget\nII.1\tBudget detail\nInterlude paragraph.\n(3)\tThird item\n(4)\tFourth item\n(1)\tRestarted item\n"
        )
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(
            markdown.hasPrefix(
                "1. Scope\n   1. Inside scope\n   2. Also inside\n2. Budget\n   1. Budget detail\n\nInterlude paragraph.\n\n1. Third item\n2. Fourth item\n"
            ))
    }

    @Test func textutilMinimalAndRenamedWordFilesConvert() async throws {
        let space = try Workspace()
        let rich = NSMutableAttributedString(
            string: "Minutes\n",
            attributes: [.font: NSFont.boldSystemFont(ofSize: 22)])
        rich.append(
            NSAttributedString(
                string: "Attendees agreed on the plan.\n",
                attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let textutil = space.url("textutil.docx")
        try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]
        ).write(to: textutil)
        let textutilPDF = try await space.run("document.to-pdf", [textutil])
        #expect(Fixtures.text(of: try textutilPDF.url()).contains("Attendees agreed on the plan."))
        let textutilMarkdown = try String(
            contentsOf: try await space.run("document.to-markdown", [textutil]).url(),
            encoding: .utf8)
        #expect(textutilMarkdown.hasPrefix("# Minutes\n\nAttendees agreed on the plan."))

        let minimal = space.url("minimal.docx")
        try F.minimalDOCX(
            at: minimal, body: F.text("Bare document body.") + F.text("Second paragraph."))
        let minimalPDF = try await space.run("document.to-pdf", [minimal])
        let minimalDocument = try minimalPDF.document()
        #expect(minimalDocument.pageCount == 1)
        #expect(
            minimalDocument.page(at: 0)?.bounds(for: .mediaBox).size
                == CGSize(width: 612, height: 792))
        #expect(
            F.order(
                ["Bare document body.", "Second paragraph."],
                in: Fixtures.text(of: try minimalPDF.url())))

        let renamedRTF = space.url("letter.doc")
        let rtf = try rich.data(
            from: NSRange(location: 0, length: rich.length),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtf.write(to: renamedRTF)
        let rtfPDF = try await space.run("document.to-pdf", [renamedRTF])
        #expect(Fixtures.text(of: try rtfPDF.url()).contains("Attendees agreed"))

        let renamedDOCX = space.url("modern.doc")
        try F.minimalDOCX(at: renamedDOCX, body: F.text("Zip based despite the name."))
        let modernPDF = try await space.run("document.to-pdf", [renamedDOCX])
        #expect(Fixtures.text(of: try modernPDF.url()).contains("Zip based despite the name."))
    }

    @Test func unicodeLongParagraphsAndManyPagesKeepEveryLine() async throws {
        let space = try Workspace()
        let url = space.url("long.docx")
        var body =
            F.text("Café crème brûlée à la française")
            + F.text("東京都の天気は晴れです")
            + F.paragraph(F.run("مرحبا بالعالم"), properties: #"<w:bidi/><w:jc w:val="right"/>"#)
            + F.text("Party time 🎉🚀")
        let words = (1...900).map { "w\($0)" }.joined(separator: " ")
        body += F.text("Opening " + words + " closing.")
        for index in 1...120 {
            body += F.text(
                "Sentence \(String(format: "%04d", index)) keeps the document flowing across pages."
            )
        }
        try F.wordDOCX(at: url, body: body)
        let result = try await space.run("document.to-pdf", [url])
        let pages = try F.pages(try result.url())
        #expect(pages.count >= 4 && pages.count <= 8)
        let all = pages.joined(separator: "\n")
        #expect(all.contains("Café crème brûlée à la française"))
        #expect(all.contains("東京都の天気は晴れです"))
        #expect(all.contains("w1 w2 w3"))
        #expect(all.contains("w899 w900 closing."))
        var lastPage = 0
        for index in 1...120 {
            let marker = "Sentence \(String(format: "%04d", index))"
            let hits = pages.enumerated().filter { $0.element.contains(marker) }.map(\.offset)
            #expect(hits.count == 1, "\(marker) appears on \(hits)")
            if let page = hits.first {
                #expect(page >= lastPage)
                lastPage = page
            }
        }
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(markdown.contains("مرحبا بالعالم"))
        #expect(markdown.contains("Party time 🎉🚀"))
    }

    @Test func trackedChangesFieldsHiddenTextTextBoxesAndFootnotes() async throws {
        let space = try Workspace()
        let url = space.url("changes.docx")
        let field =
            #"<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> DATE \@ "yyyy" </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>2026</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>"#
        let box =
            #"<w:r><mc:AlternateContent><mc:Choice Requires="wps"><w:drawing><wp:anchor distT="0" distB="0" distL="0" distR="0" simplePos="0" relativeHeight="1" behindDoc="0" locked="0" layoutInCell="1" allowOverlap="1"><wp:simplePos x="0" y="0"/><wp:extent cx="1270000" cy="635000"/><wp:docPr id="9" name="Text Box 9"/><a:graphic><a:graphicData uri="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:wsp xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"><wps:txbx><w:txbxContent><w:p><w:r><w:t>Boxed callout</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></a:graphicData></a:graphic></wp:anchor></w:drawing></mc:Choice><mc:Fallback><w:pict><v:shape xmlns:v="urn:schemas-microsoft-com:vml"><v:textbox><w:txbxContent><w:p><w:r><w:t>Boxed callout</w:t></w:r></w:p></w:txbxContent></v:textbox></v:shape></w:pict></mc:Fallback></mc:AlternateContent></w:r>"#
        let body =
            F.paragraph(
                F.run("Kept ")
                    + #"<w:ins w:id="1" w:author="A"><w:r><w:t>inserted </w:t></w:r></w:ins>"#
                    + #"<w:del w:id="2" w:author="A"><w:r><w:delText>deleted </w:delText></w:r></w:del>"#
                    + F.run("text."))
            + F.paragraph(F.run("Year ") + field + F.run(" closes."))
            + F.paragraph(
                F.run("Visible ")
                    + #"<w:r><w:rPr><w:vanish/></w:rPr><w:t>secret </w:t></w:r>"# + F.run("end."))
            + F.paragraph(F.run("Anchor paragraph.") + box)
            + F.paragraph(
                F.run("Claim needs a source")
                    + #"<w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteReference w:id="1"/></w:r>"#
                    + F.run("."))
        try F.wordDOCX(at: url, body: body, footnotes: ["1": "Source: the 2025 survey."])
        let text = try String(
            contentsOf: try await space.run("document.to-text", [url]).url(), encoding: .utf8)
        #expect(text.contains("Kept inserted text."))
        #expect(text.contains("Year 2026 closes."))
        #expect(text.contains("Visible end."))
        #expect(text.components(separatedBy: "Boxed callout").count == 2)
        #expect(text.contains("Claim needs a source1."))
        #expect(text.contains("1 Source: the 2025 survey."))
        for leaked in ["deleted", "secret", "DATE", "yyyy"] {
            let found = text.contains(leaked)
            #expect(found == false, "\(leaked) leaked into the text")
        }
        let pdf = try await space.run("document.to-pdf", [url])
        let pdfText = Fixtures.text(of: try pdf.url())
        #expect(
            F.order(
                ["Kept inserted text.", "Boxed callout", "Source: the 2025 survey."], in: pdfText))
        let deleted = pdfText.contains("deleted")
        #expect(deleted == false)
    }

    @Test func damagedEncryptedAndEmptyWordFilesFailClearly() async throws {
        let space = try Workspace()
        for url in try F.damagedFiles(named: "memo", ext: "docx", in: space) {
            let original = try Data(contentsOf: url)
            for tool in ["document.to-pdf", "document.to-markdown", "document.to-text"] {
                do {
                    _ = try await space.run(tool, [url])
                    Issue.record("\(tool) accepted \(url.lastPathComponent)")
                } catch let error as StudioError {
                    let message = error.localizedDescription
                    #expect(message.contains(url.lastPathComponent))
                    if url.lastPathComponent.contains("locked") {
                        #expect(message.contains("password"))
                    }
                    if url.lastPathComponent.contains("empty") {
                        #expect(message.contains("empty"))
                    }
                } catch {
                    Issue.record("\(tool) threw a non Studio error: \(error)")
                }
            }
            #expect(try Data(contentsOf: url) == original)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: space.output.path)
        #expect(leftovers.isEmpty)
    }
}
