import AppKit
import Foundation
import ImageIO
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PDFAuditConvertTests {
    static let mixed: [AuditPage] = [
        .cornered("Letter page"), .cornered("Wide page", media: AuditPage.a4Landscape),
        .cornered("Turned page", rotation: 90),
        .cornered("Shifted page", media: CGRect(x: -40, y: 70, width: 612, height: 792)),
        .cornered(
            "Cropped page", crop: CGRect(x: 30, y: 50, width: 540, height: 680), rotation: 270),
        .cornered("Card", media: AuditPage.businessCard),
    ]

    static func report(at url: URL) throws {
        var first = AuditPage()
        first.texts = [
            AuditText(text: "Quarterly Report", x: 54, y: 720, size: 28, font: "Helvetica-Bold"),
            AuditText(
                text: "Revenue grew across every region this quarter.", x: 54, y: 680, size: 12),
            AuditText(text: "Costs stayed flat while hiring continued.", x: 54, y: 664, size: 12),
            AuditText(
                text: "Crème brûlée, naïve café and Ångström units.", x: 54, y: 640, size: 12),
            AuditText(text: "Highlights", x: 54, y: 600, size: 18, font: "Helvetica-Bold"),
            AuditText(text: "• Launched two products", x: 54, y: 576, size: 12),
            AuditText(text: "• Opened the Berlin office", x: 54, y: 560, size: 12),
        ]
        let rows = [
            ["Region", "Units", "Revenue"], ["North", "1,200", "98,450"], ["South", "95", "7,100"],
            ["West", "18,040", "1,250,000"],
        ]
        for (index, row) in rows.enumerated() {
            let y = 500 - CGFloat(index) * 20
            first.texts.append(AuditText(text: row[0], x: 54, y: y, size: 12))
            for (column, cell) in row.dropFirst().enumerated() {
                let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
                let line = CTLineCreateWithAttributedString(
                    NSAttributedString(string: cell, attributes: [.font: font]))
                let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
                let right = 300 + CGFloat(column) * 150
                first.texts.append(AuditText(text: cell, x: right - width, y: y, size: 12))
            }
        }
        var second = AuditPage()
        second.texts = [
            AuditText(text: "Appendix", x: 54, y: 720, size: 28, font: "Helvetica-Bold"),
            AuditText(text: "東京タワーの見学ツアー", x: 54, y: 680, size: 14),
            AuditText(text: "שלום עולם", x: 54, y: 650, size: 14),
            AuditText(
                text: "Scaled body text keeps its size.", x: 54, y: 620, size: 12, unitFont: true),
        ]
        try AuditPDF.write([first, second], to: url)
    }

    static func words(ofWord url: URL) throws -> [String] {
        let parts = try OOXMLPackage.read(url)
        let xml = String(decoding: try requireFixture(parts["word/document.xml"]), as: UTF8.self)
        let expression = try NSRegularExpression(pattern: "<w:t[^>]*>([^<]*)</w:t>")
        return expression.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
            Range($0.range(at: 1), in: xml).map { String(xml[$0]) }
        }
    }

    @Test func pagesBecomeUprightImagesOfTheExactSize() async throws {
        let space = try Workspace()
        let source = space.url("mixed.pdf")
        try AuditPDF.write(Self.mixed, to: source)
        let document = try #require(PDFDocument(url: source))
        let result = try await space.audited(
            "pdf.to-images", [source], ["dpi": .text("150"), "format": .text("png")])
        #expect(result.outputs.count == Self.mixed.count)
        #expect(
            result.outputs.map(\.url.lastPathComponent) == (1...6).map { "mixed-page-\($0).png" })
        for (index, output) in result.outputs.enumerated() {
            let page = try #require(document.page(at: index))
            let size = StudioPDF.displaySize(page)
            let image = try StudioImageIO.load(output.url)
            #expect(image.width == Int((size.width * 150 / 72).rounded()))
            #expect(image.height == Int((size.height * 150 / 72).rounded()))
            let mark = try #require(AuditInk.box(image, below: 60))
            #expect(mark.minX < 3 && mark.minY < 3, "page \(index + 1) is not upright")
            let dpi = StudioImageIO.info(output.url)?.dpi ?? 0
            #expect(abs(dpi - 150) < 0.5)
        }
        let jpegs = try await space.audited(
            "pdf.to-images", [source], ["dpi": .number(72), "pages": .text("2, 6")])
        #expect(jpegs.outputs.map(\.url.pathExtension) == ["jpg", "jpg"])
        #expect(StudioImageIO.info(try jpegs.url(1))?.width == 252)
    }

    @Test func extractedImagesKeepTheirPixelsAndTransparency() async throws {
        let space = try Workspace()
        let source = space.url("pictures.pdf")
        var page = AuditPage.titled("Pictures", rotation: 90)
        page.images = [
            AuditImage(kind: .jpeg, rect: CGRect(x: 60, y: 300, width: 240, height: 180)),
            AuditImage(kind: .alphaPNG, rect: CGRect(x: 320, y: 300, width: 200, height: 200)),
        ]
        try AuditPDF.write([page], to: source)
        let result = try await space.audited("pdf.to-images", [source], ["mode": .text("extract")])
        let byType = Dictionary(grouping: result.outputs, by: \.url.pathExtension)
        let jpeg = try #require(byType["jpg"]?.first)
        let png = try #require(byType["png"]?.first)
        #expect(StudioImageIO.info(jpeg.url)?.width == 480)
        let alpha = try StudioImageIO.load(png.url)
        #expect(alpha.width == 400 && alpha.height == 400)
        #expect(Fixtures.pixel(alpha, x: 5, y: 5).a == 0)
        let center = Fixtures.pixel(alpha, x: 200, y: 200)
        #expect(center.a == 255 && center.g > 150 && center.r < 80)
    }

    @Test(arguments: [1, 3, 6, 8])
    func imagesToPDFRespectExifOrientation(_ orientation: Int) async throws {
        let space = try Workspace()
        let photo = space.url("photo-\(orientation).jpg")
        try Fixtures.image(
            at: photo, width: 400, height: 300, format: .jpeg, orientation: orientation)
        let result = try await space.audited("pdf.from-images", [photo], ["paper": .text("fit")])
        let page = try #require(try result.document().page(at: 0))
        let size = StudioPDF.displaySize(page)
        let turned = orientation >= 5
        #expect(
            size == (turned ? CGSize(width: 300, height: 400) : CGSize(width: 400, height: 300)))
        let reference = try StudioImageIO.load(photo)
        let rendered = try AuditInk.render(page)
        #expect(rendered.width == reference.width && rendered.height == reference.height)
        for (x, y) in [(0.25, 0.25), (0.75, 0.25), (0.25, 0.75), (0.75, 0.75)] {
            let a = Fixtures.pixel(
                rendered, x: Int(Double(rendered.width) * x), y: Int(Double(rendered.height) * y))
            let b = Fixtures.pixel(
                reference, x: Int(Double(reference.width) * x), y: Int(Double(reference.height) * y)
            )
            #expect(abs(a.r - b.r) < 40 && abs(a.g - b.g) < 40 && abs(a.b - b.b) < 40)
        }
    }

    @Test func imagesToPDFKeepsOrderPaperAndMargins() async throws {
        let space = try Workspace()
        let wide = space.url("a-wide.png")
        let tall = space.url("b-tall.jpg")
        try Fixtures.image(at: wide, width: 800, height: 400)
        try Fixtures.image(at: tall, width: 300, height: 600, format: .jpeg)
        let result = try await space.audited(
            "pdf.from-images", [tall, wide], ["paper": .text("letter"), "margin": .text("48")])
        let document = try result.document()
        #expect(document.pageCount == 2)
        let first = try #require(document.page(at: 0))
        let second = try #require(document.page(at: 1))
        #expect(StudioPDF.displaySize(first) == CGSize(width: 612, height: 792))
        #expect(StudioPDF.displaySize(second) == CGSize(width: 792, height: 612))
        let ink = try #require(AuditInk.box(try AuditInk.render(second), below: 250))
        #expect(abs(ink.minX - 48) <= 1.5 && abs(ink.maxX - (792 - 48)) <= 1.5)
        #expect(abs(ink.midY - 306) <= 1.5)
        let forced = try await space.audited(
            "pdf.from-images", [tall], ["orientation": .text("landscape"), "paper": .text("a4")])
        let forcedSize = StudioPDF.displaySize(try #require(try forced.document().page(at: 0)))
        #expect(forcedSize.width > forcedSize.height)
    }

    @Test func wordKeepsAllTextInReadingOrderWithTablesAndSizes() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Self.report(at: source)
        let result = try await space.audited("pdf.to-word", [source])
        let words = try Self.words(ofWord: try result.url())
        let joined = words.joined(separator: "\n")
        let order = [
            "Quarterly Report", "Revenue grew", "Crème brûlée, naïve café and Ångström units.",
            "Highlights", "Launched two products", "Region", "West", "1,250,000", "Appendix",
            "東京タワーの見学ツアー", "שלום עולם", "Scaled body text keeps its size.",
        ]
        var cursor = joined.startIndex
        for item in order {
            let found = joined.range(of: item, range: cursor..<joined.endIndex)
            #expect(found != nil, "\(item) is missing or out of order")
            if let found { cursor = found.upperBound }
        }
        let parts = try OOXMLPackage.read(try result.url())
        let xml = String(decoding: try #require(parts["word/document.xml"]), as: UTF8.self)
        #expect(xml.contains("<w:tbl>"))
        let table = try #require(xml.range(of: "<w:tbl>").map { String(xml[$0.lowerBound...]) })
        let tableXML = String(table[..<(table.range(of: "</w:tbl>")?.upperBound ?? table.endIndex)])
        let cells = try NSRegularExpression(pattern: "<w:tc>").numberOfMatches(
            in: tableXML, range: NSRange(tableXML.startIndex..., in: tableXML))
        #expect(cells == 12)
        let sizes = try NSRegularExpression(pattern: #"<w:sz w:val="(\d+)"/>"#)
            .matches(in: xml, range: NSRange(xml.startIndex..., in: xml))
            .compactMap { Range($0.range(at: 1), in: xml).flatMap { Int(xml[$0]) } }
        #expect(sizes.allSatisfy { $0 >= 16 })
    }

    @Test func markdownHasHeadingsListsTablesAndUnicode() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Self.report(at: source)
        let markdown = try String(
            contentsOf: try await space.audited("pdf.to-markdown", [source]).url(), encoding: .utf8)
        #expect(markdown.contains("# Quarterly Report"))
        #expect(markdown.contains("- Launched two products\n- Opened the Berlin office"))
        #expect(markdown.contains("| Region | Units | Revenue |"))
        #expect(markdown.contains("| West | 18,040 | 1,250,000 |"))
        #expect(markdown.contains("Crème brûlée, naïve café and Ångström units."))
        #expect(markdown.contains("東京タワーの見学ツアー"))
        #expect(markdown.contains("שלום עולם"))
        #expect(markdown.contains("# Appendix"))
        #expect(markdown.contains("Scaled body text keeps its size.\n"))
        #expect(markdown.contains("# Scaled") == false)
    }

    @Test func textKeepsEveryLineAndPageMarkers() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Self.report(at: source)
        let result = try await space.audited("pdf.to-text", [source], ["pageMarkers": .bool(true)])
        let text = try String(contentsOf: try result.url(), encoding: .utf8)
        for item in [
            "--- Page 1 ---", "Quarterly Report", "Crème brûlée", "1,250,000", "--- Page 2 ---",
            "東京タワーの見学ツアー", "שלום עולם",
        ] {
            #expect(text.contains(item), "\(item) is missing")
        }
        let plain = try await space.audited("pdf.to-text", [source])
        let pages = try String(contentsOf: try plain.url(), encoding: .utf8).components(
            separatedBy: "\u{0C}")
        #expect(pages.count == 2)
    }

    @Test func excelPutsRightAlignedNumbersInTheirColumns() async throws {
        let space = try Workspace()
        let source = space.url("report.pdf")
        try Self.report(at: source)
        let result = try await space.audited("pdf.to-excel", [source])
        let parts = try OOXMLPackage.read(try result.url())
        let sheet = String(decoding: try #require(parts["xl/worksheets/sheet1.xml"]), as: UTF8.self)
        let regionRow = try #require(
            sheet.components(separatedBy: "<row ").first { $0.contains(">Region<") })
        let columnOfRegion = try #require(
            regionRow.range(
                of: #"r="([A-Z]+)\d+" t="inlineStr"><is><t xml:space="preserve">Region"#,
                options: .regularExpression))
        _ = columnOfRegion
        let rows = sheet.components(separatedBy: "<row ").filter {
            $0.contains(">North<") || $0.contains(">South<") || $0.contains(">West<")
        }
        #expect(rows.count == 3)
        func column(_ row: String, value: String) -> String? {
            let pattern =
                #"<c r="([A-Z]+)\d+"><v>"# + NSRegularExpression.escapedPattern(for: value) + "</v>"
            guard let expression = try? NSRegularExpression(pattern: pattern),
                let match = expression.firstMatch(
                    in: row, range: NSRange(row.startIndex..., in: row)),
                let range = Range(match.range(at: 1), in: row)
            else { return nil }
            return String(row[range])
        }
        #expect(column(rows[0], value: "1200") == column(rows[2], value: "18040"))
        #expect(column(rows[1], value: "95") == column(rows[2], value: "18040"))
        #expect(column(rows[0], value: "98450") == column(rows[2], value: "1250000"))
        #expect(column(rows[1], value: "7100") == column(rows[2], value: "1250000"))
        #expect(column(rows[2], value: "18040") != nil)
    }

    @Test func powerPointSlidesKeepEveryPageUndistorted() async throws {
        let space = try Workspace()
        let source = space.url("deck.pdf")
        try AuditPDF.write(
            [
                .cornered("Portrait slide"), .cornered("Wide slide", media: AuditPage.a4Landscape),
                .cornered("Turned slide", rotation: 90),
            ], to: source)
        let result = try await space.audited("pdf.to-powerpoint", [source], ["dpi": .text("110")])
        let parts = try OOXMLPackage.read(try result.url())
        let presentation = String(
            decoding: try #require(parts["ppt/presentation.xml"]), as: UTF8.self)
        #expect(presentation.contains(#"<p:sldSz cx="\#(612 * 12700)" cy="\#(792 * 12700)"/>"#))
        for index in 1...3 {
            let data = try #require(parts["ppt/media/image\(index).jpg"])
            let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
            let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
            let ratio = Double(image.width) / Double(image.height)
            #expect(abs(ratio - 612.0 / 792.0) < 0.01, "slide \(index) is stretched")
            let mark = try #require(AuditInk.box(image, below: 60))
            let content = try #require(AuditInk.box(image, below: 250))
            #expect(abs(mark.minX - content.minX) < 3 && abs(mark.minY - content.minY) < 3)
        }
    }

    @Test(arguments: ["vector", "flatten"])
    func pdfaKeepsPagesTextNavigationAndAnnotations(_ mode: String) async throws {
        let space = try Workspace()
        let source = space.url("archive.pdf")
        var pages = Self.mixed
        pages[0].link("Letter page", page: 2)
        try AuditPDF.write(pages, to: source, outline: [("Turned", 2)]) { document in
            let page = try requireFixture(document.page(at: 3))
            let square = PDFAnnotation(
                bounds: CGRect(x: 260, y: 370, width: 100, height: 100), forType: .square,
                withProperties: nil)
            square.color = .blue
            square.interiorColor = .blue
            page.addAnnotation(square)
        }
        let original = try #require(PDFDocument(url: source))
        let result = try await space.audited("pdf.to-pdfa", [source], ["mode": .text(mode)])
        let document = try result.document()
        #expect(document.pageCount == original.pageCount)
        for index in 0..<original.pageCount {
            let before = StudioPDF.displaySize(try #require(original.page(at: index)))
            let page = try #require(document.page(at: index))
            let after = StudioPDF.displaySize(page)
            #expect(
                abs(before.width - after.width) < 0.5 && abs(before.height - after.height) < 0.5)
            let image = try AuditInk.render(page)
            let mark = try #require(AuditInk.box(image, below: 60))
            #expect(mark.minX < 3 && mark.minY < 3)
        }
        #expect(AuditPDF.texts(document).first?.contains("Letter page") == true)
        #expect(document.page(at: 2)?.string?.contains("Turned page") == true)
        #expect(AuditPDF.linkTargets(document, page: 0) == [2])
        #expect(AuditPDF.outlineTargets(document).map(\.1) == [2])
        let annotated = try AuditInk.render(try #require(document.page(at: 3)))
        #expect(AuditInk.coloredBox(annotated) != nil)
        let archived = try #require(CGPDFDocument(try result.url() as CFURL))
        let catalog = try #require(archived.catalog)
        var intents: CGPDFArrayRef?
        #expect(CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents))
    }

    @Test func scanKeepsPageOrderAndReadsEachPage() async throws {
        let space = try Workspace()
        var photos: [URL] = []
        for (index, label) in ["PAGE ONE", "PAGE TWO", "PAGE THREE"].enumerated() {
            let url = space.url("scan-\(index).jpg")
            let image = AuditPDF.scan(label, size: CGSize(width: 400, height: 520), scale: 2)
            try StudioImageIO.write(image, to: url, format: .jpeg, options: .init(quality: 0.9))
            photos.append(url)
        }
        let result = try await space.audited(
            "pdf.scan", photos, ["straighten": .bool(false), "paper": .text("fit")])
        let texts = AuditPDF.texts(try result.url())
        #expect(texts.count == 3)
        #expect(texts[0].contains("ONE") && texts[1].contains("TWO") && texts[2].contains("THREE"))
    }
}
