import Foundation
import Testing

@testable import EdithStudio

@Suite struct DocsAuditWritersTests {
    static func validate(_ url: URL) throws -> [String: Data] {
        let parts = try OOXMLPackage.read(url)
        let types = String(decoding: try #require(parts["[Content_Types].xml"]), as: UTF8.self)
        for (path, data) in parts {
            let ext = path.hasSuffix(".rels") ? "rels" : (path as NSString).pathExtension
            if ext == "xml" || ext == "rels" {
                #expect(XMLTree.parse(data, strict: true) != nil, "\(path) is not valid XML")
            }
            let covered =
                types.contains("PartName=\"/\(path)\"") || types.contains("Extension=\"\(ext)\"")
            #expect(covered, "\(path) has no content type")
        }
        for (path, data) in parts where path.hasSuffix(".rels") {
            let collector = ElementCollector(names: ["Relationship"])
            collector.run(data)
            let source = path.replacingOccurrences(of: "_rels/", with: "")
                .replacingOccurrences(of: ".rels", with: "")
            for relationship in collector.elements where relationship["TargetMode"] != "External" {
                let target = try #require(relationship["Target"])
                let resolved =
                    target.hasPrefix("/")
                    ? String(target.dropFirst()) : OOXMLRelationships.resolve(target, from: source)
                #expect(parts[resolved] != nil, "\(path) points at missing \(resolved)")
            }
        }
        return parts
    }

    @Test func writersProduceValidPackagesThatReadBack() async throws {
        let space = try Workspace()
        let docx = space.url("out.docx")
        let image = try DocsAuditFixtures.solidPNG(width: 20, height: 10, red: 1, green: 0, blue: 0)
        try DOCXWriter.write(
            [
                .paragraph(
                    [DOCXWriter.Run(text: "Title & <Heading>", size: 20, bold: true)], heading: 1),
                .paragraph(
                    [DOCXWriter.Run(text: "Tab\there\nnext line", color: "#FF0000")], heading: 5),
                .table([["A", "B", "C", "D", "E", "F", "G", "H"], ["1", "2"]]),
                .image(image, ext: "jpeg", width: 200, height: 100), .pageBreak,
                .paragraph([DOCXWriter.Run(text: "Fin")], heading: nil),
            ], title: "Out", pageSize: CGSize(width: 842, height: 595), to: docx)
        let docxParts = try Self.validate(docx)
        let document = String(decoding: try #require(docxParts["word/document.xml"]), as: UTF8.self)
        #expect(document.contains(#"w:orient="landscape""#))
        #expect(document.contains(#"<w:color w:val="FF0000"/>"#))
        #expect(document.contains("<w:tab/>"))
        let gridWidth = document.components(separatedBy: #"<w:gridCol w:w=""#).dropFirst()
            .compactMap {
                Int($0.prefix { $0.isNumber })
            }.reduce(0, +)
        #expect(gridWidth <= (842 - 108) * 20)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [docx]).url(), encoding: .utf8)
        #expect(markdown.hasPrefix("# Title & <Heading>"))
        #expect(markdown.contains("| A | B | C | D | E | F | G | H |"))

        let xlsx = space.url("out.xlsx")
        try XLSXWriter.write(
            [
                XLSXWriter.Sheet(
                    name: "'Q1: Sales'",
                    rows: [
                        ["Item", "Total", "Code", "Ratio"], ["A", "1,234", "007", "1,2"],
                        ["B", "-5.5", "12,34,56", "3"],
                    ]),
                XLSXWriter.Sheet(name: "History", rows: [["x"]]),
            ], title: "Out", to: xlsx)
        let xlsxParts = try Self.validate(xlsx)
        let sheet = String(
            decoding: try #require(xlsxParts["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        #expect(sheet.contains(#"<c r="B2"><v>1234</v></c>"#))
        #expect(sheet.contains(#"<c r="B3"><v>-5.5</v></c>"#))
        #expect(sheet.contains(#"<c r="D3"><v>3</v></c>"#))
        for text in ["007", "1,2", "12,34,56"] {
            #expect(sheet.contains(">\(text)</t>"), "\(text) should stay text")
        }
        let workbook = String(decoding: try #require(xlsxParts["xl/workbook.xml"]), as: UTF8.self)
        #expect(workbook.contains(#"name="Q1 Sales""#))
        let reserved = workbook.contains(#"name="History""#)
        #expect(reserved == false)
        #expect(try SpreadsheetReader.read(xlsx).first?.rows[1] == ["A", "1234", "007", "1,2"])

        let pptx = space.url("out.pptx")
        try PPTXWriter.write(
            [
                PPTXWriter.Slide(
                    image: image, imageExtension: "png", notes: "Speaker note one\nLine two"),
                PPTXWriter.Slide(image: image, imageExtension: "jpeg", notes: nil),
            ], size: CGSize(width: 5000, height: 3000), title: "Deck", to: pptx)
        let pptxParts = try Self.validate(pptx)
        let presentation = String(
            decoding: try #require(pptxParts["ppt/presentation.xml"]), as: UTF8.self)
        #expect(presentation.contains(#"<p:sldSz cx="51206400" cy="30723840"/>"#))
        #expect(presentation.contains("notesMasterIdLst"))
        let slides = try PresentationRenderer.text(pptx)
        #expect(slides.map(\.notes) == ["Speaker note one\nLine two", nil])
        let text = try String(
            contentsOf: try await space.run("document.to-text", [pptx]).url(), encoding: .utf8)
        #expect(text.contains("Notes: Speaker note one Line two"))
    }

    @Test func presentationsSkipHiddenSlidesAndKeepNotes() async throws {
        let space = try Workspace()
        let url = space.url("deck.pptx")
        typealias F = DocsAuditFixtures
        try F.deck(
            at: url,
            slides: [
                .init(
                    shapes: F.textBox(
                        id: 2, name: "Title 1", placeholder: "title", paragraphs: ["Roadmap"])
                        + F.textBox(
                            id: 3, name: "Body", placeholder: nil, index: 1,
                            paragraphs: ["Ship beta", "Grow"]),
                    notes: "Mention the budget."),
                .init(
                    shapes: F.textBox(
                        id: 2, name: "Title 1", placeholder: "title", paragraphs: ["Appendix"]),
                    notes: nil, hidden: true),
                .init(
                    shapes: F.textBox(
                        id: 2, name: "Title 1", placeholder: "title", paragraphs: ["Results"])
                        + F.picture(
                            id: 5, relationship: "rId2",
                            frame: (1_000_000, 3_000_000, 2_000_000, 2_000_000)),
                    notes: nil,
                    image: try F.solidPNG(width: 20, height: 20, red: 1, green: 0, blue: 0)),
            ])
        let pdf = try await space.run("document.powerpoint-to-pdf", [url])
        let document = try pdf.document()
        #expect(document.pageCount == 2)
        let pages = try F.pages(try pdf.url())
        #expect(pages[0].contains("Roadmap") && pages[0].contains("Ship beta"))
        #expect(pages[1].contains("Results"))
        let hidden = pages.joined().contains("Appendix")
        #expect(hidden == false)
        #expect(
            F.redPixels(try StudioPDF.render(try #require(document.page(at: 1)), dpi: 36)) > 500)
        let markdown = try String(
            contentsOf: try await space.run("document.to-markdown", [url]).url(), encoding: .utf8)
        #expect(
            markdown.hasPrefix(
                "## Slide 1: Roadmap\n\n- Ship beta\n- Grow\n\n**Notes:** Mention the budget.\n\n## Slide 2 (hidden): Appendix\n\n## Slide 3: Results\n"
            ))
        for broken in try F.damagedFiles(named: "deck", ext: "pptx", in: space) {
            await #expect(throws: StudioError.self) {
                try await space.run("document.powerpoint-to-pdf", [broken])
            }
        }
    }
}
