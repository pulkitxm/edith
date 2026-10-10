import AppKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

@testable import EdithStudio

enum DocsAuditFixtures {
    static let header = OOXMLPackage.xmlHeader
    static let relationshipsNamespace =
        "http://schemas.openxmlformats.org/package/2006/relationships"
    static let officeRelationships =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
    static let wordNamespaces =
        #"xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" mc:Ignorable="w14""#

    static func run(
        _ text: String, bold: Bool = false, italic: Bool = false, style: String? = nil
    ) -> String {
        var properties = ""
        if let style { properties += #"<w:rStyle w:val="\#(style)"/>"# }
        if bold { properties += "<w:b/><w:bCs/>" }
        if italic { properties += "<w:i/><w:iCs/>" }
        let rPr = properties.isEmpty ? "" : "<w:rPr>\(properties)</w:rPr>"
        return
            #"<w:r w:rsidRPr="00A1B2C3">\#(rPr)<w:t xml:space="preserve">\#(OOXMLPackage.escape(text))</w:t></w:r>"#
    }

    static func paragraph(
        _ content: String, style: String? = nil, list: (id: Int, level: Int)? = nil,
        properties: String = ""
    ) -> String {
        var pPr = ""
        if let style { pPr += #"<w:pStyle w:val="\#(style)"/>"# }
        if let list {
            pPr +=
                #"<w:numPr><w:ilvl w:val="\#(list.level)"/><w:numId w:val="\#(list.id)"/></w:numPr>"#
        }
        pPr += properties
        let wrapped = pPr.isEmpty ? "" : "<w:pPr>\(pPr)</w:pPr>"
        return
            #"<w:p w14:paraId="1A2B3C4D" w:rsidR="00B10F2E" w:rsidRDefault="00B10F2E">\#(wrapped)\#(content)</w:p>"#
    }

    static func text(_ text: String, style: String? = nil) -> String {
        paragraph(run(text), style: style)
    }

    static let pageBreak = #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#

    static func sectionProperties(landscape: Bool, headers: Bool = false) -> String {
        let size =
            landscape
            ? #"<w:pgSz w:w="15840" w:h="12240" w:orient="landscape"/>"#
            : #"<w:pgSz w:w="12240" w:h="15840"/>"#
        let references =
            headers
            ? #"<w:headerReference w:type="default" r:id="rIdHeader1"/><w:footerReference w:type="default" r:id="rIdFooter1"/>"#
            : ""
        return "<w:sectPr w:rsidR=\"00B10F2E\">\(references)\(size)"
            + #"<w:pgMar w:top="1440" w:right="1440" w:bottom="1440" w:left="1440" w:header="708" w:footer="708" w:gutter="0"/><w:cols w:space="708"/><w:docGrid w:linePitch="360"/></w:sectPr>"#
    }

    static func sectionBreak(landscape: Bool, headers: Bool = false) -> String {
        "<w:p><w:pPr>\(sectionProperties(landscape: landscape, headers: headers))</w:pPr></w:p>"
    }

    static func cell(_ content: String, width: Int = 3000, properties: String = "") -> String {
        let body = content.isEmpty ? "<w:p/>" : text(content)
        return
            #"<w:tc><w:tcPr><w:tcW w:w="\#(width)" w:type="dxa"/>\#(properties)</w:tcPr>\#(body)</w:tc>"#
    }

    static func table(_ rows: [String], columns: Int) -> String {
        let grid = String(repeating: #"<w:gridCol w:w="3000"/>"#, count: columns)
        return
            #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblLook w:val="04A0"/></w:tblPr><w:tblGrid>\#(grid)</w:tblGrid>"#
            + rows.map { "<w:tr>\($0)</w:tr>" }.joined() + "</w:tbl>"
    }

    static func hyperlink(_ text: String, relationship: String = "rIdLink1") -> String {
        #"<w:hyperlink r:id="\#(relationship)" w:history="1">\#(run(text, style: "Hyperlink"))</w:hyperlink>"#
    }

    static func inlineImage(width: Double, height: Double, relationship: String = "rIdImage1")
        -> String
    {
        let cx = Int(width * 12700)
        let cy = Int(height * 12700)
        return
            #"<w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:effectExtent l="0" t="0" r="0" b="0"/><wp:docPr id="1" name="Picture 1"/><wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr><a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic><pic:nvPicPr><pic:cNvPr id="0" name="red.png"/><pic:cNvPicPr/></pic:nvPicPr><pic:blipFill><a:blip r:embed="\#(relationship)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill><pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr></pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r>"#
    }

    static let wordStyles =
        header
        + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006" xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml" mc:Ignorable="w14">"#
        + #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:asciiTheme="minorHAnsi" w:eastAsiaTheme="minorHAnsi" w:hAnsiTheme="minorHAnsi" w:cstheme="minorBidi"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US" w:eastAsia="en-US" w:bidi="ar-SA"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="160" w:line="259" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
        + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
        + heading(1, size: 32, color: "2F5496") + heading(2, size: 26, color: "2F5496")
        + heading(3, size: 24, color: "1F3763")
        + #"<w:style w:type="paragraph" w:styleId="Title"><w:name w:val="Title"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:contextualSpacing/></w:pPr><w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:spacing w:val="-10"/><w:kern w:val="28"/><w:sz w:val="56"/><w:szCs w:val="56"/></w:rPr></w:style>"#
        + #"<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/><w:pPr><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>"#
        + #"<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0563C1" w:themeColor="hyperlink"/><w:u w:val="single"/></w:rPr></w:style>"#
        + #"<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:left w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:right w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="auto"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="auto"/></w:tblBorders></w:tblPr></w:style>"#
        + "</w:styles>"

    static func heading(_ level: Int, size: Int, color: String) -> String {
        #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:link w:val="Heading\#(level)Char"/><w:uiPriority w:val="9"/><w:qFormat/><w:pPr><w:keepNext/><w:keepLines/><w:spacing w:before="240" w:after="0"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:rFonts w:asciiTheme="majorHAnsi" w:hAnsiTheme="majorHAnsi"/><w:color w:val="\#(color)" w:themeColor="accent1" w:themeShade="BF"/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
    }

    static let wordNumbering =
        header
        + #"<w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
        + #"<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>"#
        + #"<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr></w:lvl>"#
        + #"<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%2."/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr></w:lvl>"#
        + "</w:abstractNum>"
        + #"<w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>"#
        + #"<w:lvl w:ilvl="0"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="\#u{F0B7}"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="720" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Symbol" w:hAnsi="Symbol" w:hint="default"/></w:rPr></w:lvl>"#
        + #"<w:lvl w:ilvl="1"><w:start w:val="1"/><w:numFmt w:val="bullet"/><w:lvlText w:val="o"/><w:lvlJc w:val="left"/><w:pPr><w:ind w:left="1440" w:hanging="360"/></w:pPr><w:rPr><w:rFonts w:ascii="Courier New" w:hAnsi="Courier New" w:cs="Courier New" w:hint="default"/></w:rPr></w:lvl>"#
        + "</w:abstractNum>"
        + #"<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num><w:num w:numId="2"><w:abstractNumId w:val="1"/></w:num>"#
        + "</w:numbering>"

    static func wordDOCX(
        at url: URL, body: String, finalSection: String = sectionProperties(landscape: false),
        headerText: String? = nil, footerText: String? = nil, image: Data? = nil,
        includeStyles: Bool = true, includeNumbering: Bool = true,
        numberingXML: String = wordNumbering, footnotes: [String: String] = [:]
    ) throws {
        var package = OOXMLPackage()
        var overrides =
            #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        var relationships =
            #"<Relationship Id="rIdLink1" Type="\#(officeRelationships)/hyperlink" Target="https://example.com/report?id=7&amp;view=full" TargetMode="External"/>"#
        if includeStyles {
            overrides +=
                #"<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdStyles" Type="\#(officeRelationships)/styles" Target="styles.xml"/>"#
            package.add("word/styles.xml", wordStyles)
        }
        if includeNumbering {
            overrides +=
                #"<Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdNumbering" Type="\#(officeRelationships)/numbering" Target="numbering.xml"/>"#
            package.add("word/numbering.xml", numberingXML)
        }
        if includeStyles {
            overrides +=
                #"<Override PartName="/word/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdTheme" Type="\#(officeRelationships)/theme" Target="theme/theme1.xml"/>"#
            package.add(
                "word/theme/theme1.xml",
                header
                    + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Office Theme"><a:themeElements><a:fontScheme name="Office"><a:majorFont><a:latin typeface="Calibri Light"/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/></a:minorFont></a:fontScheme></a:themeElements></a:theme>"#
            )
        }
        if !footnotes.isEmpty {
            overrides +=
                #"<Override PartName="/word/footnotes.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footnotes+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdFootnotes" Type="\#(officeRelationships)/footnotes" Target="footnotes.xml"/>"#
            let notes = footnotes.sorted { $0.key < $1.key }.map { id, text in
                #"<w:footnote w:id="\#(id)"><w:p><w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:footnoteRef/></w:r>\#(run(" " + text))</w:p></w:footnote>"#
            }.joined()
            package.add(
                "word/footnotes.xml",
                header + "<w:footnotes \(wordNamespaces)>"
                    + #"<w:footnote w:type="separator" w:id="-1"><w:p><w:r><w:separator/></w:r></w:p></w:footnote><w:footnote w:type="continuationSeparator" w:id="0"><w:p><w:r><w:continuationSeparator/></w:r></w:p></w:footnote>"#
                    + notes + "</w:footnotes>")
        }
        if let headerText {
            overrides +=
                #"<Override PartName="/word/header1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.header+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdHeader1" Type="\#(officeRelationships)/header" Target="header1.xml"/>"#
            package.add(
                "word/header1.xml",
                header + "<w:hdr \(wordNamespaces)>" + text(headerText, style: "Header")
                    + "</w:hdr>")
        }
        if let footerText {
            overrides +=
                #"<Override PartName="/word/footer1.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.footer+xml"/>"#
            relationships +=
                #"<Relationship Id="rIdFooter1" Type="\#(officeRelationships)/footer" Target="footer1.xml"/>"#
            let field =
                #"<w:r><w:fldChar w:fldCharType="begin"/></w:r><w:r><w:instrText xml:space="preserve"> PAGE </w:instrText></w:r><w:r><w:fldChar w:fldCharType="separate"/></w:r><w:r><w:t>1</w:t></w:r><w:r><w:fldChar w:fldCharType="end"/></w:r>"#
            package.add(
                "word/footer1.xml",
                header + "<w:ftr \(wordNamespaces)>"
                    + paragraph(run(footerText + " ") + field, style: "Footer") + "</w:ftr>")
        }
        if let image {
            relationships +=
                #"<Relationship Id="rIdImage1" Type="\#(officeRelationships)/image" Target="media/image1.png"/>"#
            package.add("word/media/image1.png", data: image)
        }
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>"#
                + overrides + "</Types>")
        package.add(
            "_rels/.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/officeDocument" Target="word/document.xml"/>"#
                + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
                + "</Relationships>")
        package.add("docProps/core.xml", OOXMLPackage.coreProperties(title: "Fixture"))
        package.add(
            "word/_rels/document.xml.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"# + relationships
                + "</Relationships>")
        package.add(
            "word/document.xml",
            header + "<w:document \(wordNamespaces)><w:body>" + body + finalSection
                + "</w:body></w:document>")
        try package.write(to: url)
    }

    static func solidPNG(width: Int, height: Int, red: Double, green: Double, blue: Double)
        throws -> Data
    {
        let context = try requireFixture(
            CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try StudioImageIO.encode(try requireFixture(context.makeImage()), format: .png)
    }

    static func pages(_ url: URL) throws -> [String] {
        let document = try requireFixture(PDFDocument(url: url))
        return (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
    }

    static func order(_ needles: [String], in haystack: String) -> Bool {
        var cursor = haystack.startIndex
        for needle in needles {
            guard let found = haystack.range(of: needle, range: cursor..<haystack.endIndex) else {
                return false
            }
            cursor = found.upperBound
        }
        return true
    }

    static func coloredPixels(
        _ image: CGImage, where predicate: (Int, Int, Int) -> Bool
    ) -> Int {
        let width = image.width
        let height = image.height
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let data = context.data!.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var count = 0
        for offset in stride(from: 0, to: width * height * 4, by: 4)
        where predicate(Int(data[offset]), Int(data[offset + 1]), Int(data[offset + 2])) {
            count += 1
        }
        return count
    }

    static func redPixels(_ image: CGImage) -> Int {
        coloredPixels(image) { r, g, b in r > 200 && g < 60 && b < 60 }
    }

    static func sha(_ url: URL) throws -> Data {
        try Data(contentsOf: url)
    }
}

extension DocsAuditFixtures {
    static let spreadsheetNamespace = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"

    static let excelStyles =
        header
        + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
        + #"<numFmts count="4"><numFmt numFmtId="164" formatCode="&quot;$&quot;#,##0.00"/><numFmt numFmtId="165" formatCode="yyyy\-mm\-dd"/><numFmt numFmtId="166" formatCode="[$€-407]#,##0.00"/><numFmt numFmtId="167" formatCode="0.0%"/></numFmts>"#
        + #"<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
        + #"<cellXfs count="12"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/>"#
        + [14, 9, 10, 164, 165, 166, 20, 4, 3, 167, 22].map {
            #"<xf numFmtId="\#($0)" fontId="0" fillId="0" borderId="0" xfId="0" applyNumberFormat="1"/>"#
        }.joined()
        + "</cellXfs></styleSheet>"

    static func excelWorkbook(
        at url: URL, sheets: [(name: String, xml: String, state: String?)], shared: [String],
        date1904: Bool = false
    ) throws {
        var package = OOXMLPackage()
        var overrides = ""
        var entries = ""
        var relationships = ""
        for (index, sheet) in sheets.enumerated() {
            let number = index + 1
            overrides +=
                #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            let state = sheet.state.map { " state=\"\($0)\"" } ?? ""
            entries +=
                #"<sheet name="\#(OOXMLPackage.escape(sheet.name))" sheetId="\#(number)"\#(state) r:id="rId\#(number)"/>"#
            relationships +=
                #"<Relationship Id="rId\#(number)" Type="\#(officeRelationships)/worksheet" Target="/xl/worksheets/sheet\#(number).xml"/>"#
            package.add(
                "xl/worksheets/sheet\(number).xml",
                header
                    + #"<worksheet xmlns="\#(spreadsheetNamespace)" xmlns:r="\#(officeRelationships)">"#
                    + sheet.xml + "</worksheet>")
        }
        relationships +=
            #"<Relationship Id="rIdStyles" Type="\#(officeRelationships)/styles" Target="styles.xml"/><Relationship Id="rIdShared" Type="\#(officeRelationships)/sharedStrings" Target="sharedStrings.xml"/>"#
        let items = shared.map {
            #"<si><t xml:space="preserve">\#(OOXMLPackage.escape($0))</t></si>"#
        }
        .joined()
        package.add(
            "xl/sharedStrings.xml",
            header
                + #"<sst xmlns="\#(spreadsheetNamespace)" count="\#(shared.count)" uniqueCount="\#(shared.count)">\#(items)</sst>"#
        )
        package.add("xl/styles.xml", excelStyles)
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/>"#
                + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
                + #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
                + #"<Override PartName="/xl/sharedStrings.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sharedStrings+xml"/>"#
                + overrides + "</Types>")
        package.add(
            "_rels/.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/officeDocument" Target="xl/workbook.xml"/></Relationships>"#
        )
        let properties =
            date1904
            ? #"<workbookPr date1904="1"/>"# : #"<workbookPr defaultThemeVersion="166925"/>"#
        package.add(
            "xl/workbook.xml",
            header
                + #"<workbook xmlns="\#(spreadsheetNamespace)" xmlns:r="\#(officeRelationships)">\#(properties)<bookViews><workbookView activeTab="0"/></bookViews><sheets>\#(entries)</sheets><calcPr calcId="191029"/></workbook>"#
        )
        package.add(
            "xl/_rels/workbook.xml.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"# + relationships
                + "</Relationships>")
        try package.write(to: url)
    }

    static func cellXML(
        _ reference: String, _ value: String, type: String? = nil, style: Int? = nil,
        formula: String? = nil
    ) -> String {
        let typeAttribute = type.map { " t=\"\($0)\"" } ?? ""
        let styleAttribute = style.map { " s=\"\($0)\"" } ?? ""
        let formulaXML = formula.map { "<f>\(OOXMLPackage.escape($0))</f>" } ?? ""
        if type == "inlineStr" {
            return
                "<c r=\"\(reference)\"\(typeAttribute)\(styleAttribute)><is><t>\(OOXMLPackage.escape(value))</t></is></c>"
        }
        return
            "<c r=\"\(reference)\"\(typeAttribute)\(styleAttribute)>\(formulaXML)<v>\(OOXMLPackage.escape(value))</v></c>"
    }

    static func sheetXML(_ rows: [[String]], merges: [String] = [], extra: String = "") -> String {
        let data = rows.enumerated().map { index, cells in
            "<row r=\"\(index + 1)\" spans=\"1:3\">" + cells.joined() + "</row>"
        }.joined()
        let merged =
            merges.isEmpty
            ? ""
            : "<mergeCells count=\"\(merges.count)\">"
                + merges.map { "<mergeCell ref=\"\($0)\"/>" }.joined() + "</mergeCells>"
        return
            #"<dimension ref="A1:C3"/><sheetViews><sheetView workbookViewId="0"/></sheetViews><sheetFormatPr defaultRowHeight="15"/>"#
            + "<sheetData>\(data)</sheetData>\(merged)\(extra)"
            + #"<pageMargins left="0.7" right="0.7" top="0.75" bottom="0.75" header="0.3" footer="0.3"/>"#
    }
}

extension DocsAuditFixtures {
    static let presentationNamespaces =
        #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#

    struct DeckSlide {
        var shapes: String
        var notes: String?
        var hidden = false
        var image: Data?
    }

    static func textBox(
        id: Int, name: String, placeholder: String?, index: Int? = nil, paragraphs: [String],
        frame: (x: Int, y: Int, cx: Int, cy: Int)? = nil, bullets: Bool = false
    ) -> String {
        var ph = ""
        if let placeholder {
            let idx = index.map { " idx=\"\($0)\"" } ?? ""
            ph = "<p:ph type=\"\(placeholder)\"\(idx)/>"
        } else if let index {
            ph = "<p:ph idx=\"\(index)\"/>"
        }
        let xfrm =
            frame.map {
                "<a:xfrm><a:off x=\"\($0.x)\" y=\"\($0.y)\"/><a:ext cx=\"\($0.cx)\" cy=\"\($0.cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom>"
            } ?? ""
        let body = paragraphs.map { text in
            let bullet =
                bullets
                ? "<a:pPr marL=\"285750\" indent=\"-285750\"><a:buFont typeface=\"Arial\"/><a:buChar char=\"•\"/></a:pPr>"
                : ""
            return
                "<a:p>\(bullet)<a:r><a:rPr lang=\"en-US\" dirty=\"0\"/><a:t>\(OOXMLPackage.escape(text))</a:t></a:r></a:p>"
        }.joined()
        let txBox = placeholder == nil && index == nil ? " txBox=\"1\"" : ""
        return
            "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(name)\"/><p:cNvSpPr\(txBox)/><p:nvPr>\(ph)</p:nvPr></p:nvSpPr><p:spPr>\(xfrm)</p:spPr><p:txBody><a:bodyPr wrap=\"square\" rtlCol=\"0\"><a:normAutofit/></a:bodyPr><a:lstStyle/>\(body)</p:txBody></p:sp>"
    }

    static func picture(id: Int, relationship: String, frame: (x: Int, y: Int, cx: Int, cy: Int))
        -> String
    {
        "<p:pic><p:nvPicPr><p:cNvPr id=\"\(id)\" name=\"Picture \(id)\"/><p:cNvPicPr><a:picLocks noChangeAspect=\"1\"/></p:cNvPicPr><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed=\"\(relationship)\"/><a:stretch><a:fillRect/></a:stretch></p:blipFill><p:spPr><a:xfrm><a:off x=\"\(frame.x)\" y=\"\(frame.y)\"/><a:ext cx=\"\(frame.cx)\" cy=\"\(frame.cy)\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr></p:pic>"
    }

    static func deck(at url: URL, slides: [DeckSlide]) throws {
        var package = OOXMLPackage()
        let ns = presentationNamespaces
        var overrides = ""
        var list = ""
        var relationships =
            #"<Relationship Id="rId1" Type="\#(officeRelationships)/slideMaster" Target="slideMasters/slideMaster1.xml"/>"#
        let group =
            #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            overrides +=
                #"<Override PartName="/ppt/slides/slide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            list += #"<p:sldId id="\#(255 + number)" r:id="rId\#(number + 10)"/>"#
            relationships +=
                #"<Relationship Id="rId\#(number + 10)" Type="\#(officeRelationships)/slide" Target="slides/slide\#(number).xml"/>"#
            var slideRelationships =
                #"<Relationship Id="rId1" Type="\#(officeRelationships)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
            if let image = slide.image {
                package.add("ppt/media/image\(number).png", data: image)
                slideRelationships +=
                    #"<Relationship Id="rId2" Type="\#(officeRelationships)/image" Target="../media/image\#(number).png"/>"#
            }
            if let notes = slide.notes {
                overrides +=
                    #"<Override PartName="/ppt/notesSlides/notesSlide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>"#
                slideRelationships +=
                    #"<Relationship Id="rId3" Type="\#(officeRelationships)/notesSlide" Target="../notesSlides/notesSlide\#(number).xml"/>"#
                package.add(
                    "ppt/notesSlides/notesSlide\(number).xml",
                    header + "<p:notes \(ns)><p:cSld><p:spTree>\(group)"
                        + textBox(
                            id: 2, name: "Slide Image Placeholder 1", placeholder: "sldImg",
                            paragraphs: [])
                        + textBox(
                            id: 3, name: "Notes Placeholder 2", placeholder: "body", index: 1,
                            paragraphs: notes.components(separatedBy: "\n"))
                        + textBox(
                            id: 4, name: "Slide Number Placeholder 3", placeholder: "sldNum",
                            index: 5, paragraphs: ["\(number)"])
                        + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>"
                )
                package.add(
                    "ppt/notesSlides/_rels/notesSlide\(number).xml.rels",
                    header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                        + #"<Relationship Id="rId1" Type="\#(officeRelationships)/slide" Target="../slides/slide\#(number).xml"/>"#
                        + "</Relationships>")
            }
            let show = slide.hidden ? " show=\"0\"" : ""
            package.add(
                "ppt/slides/slide\(number).xml",
                header + "<p:sld \(ns)\(show)><p:cSld><p:spTree>\(group)" + slide.shapes
                    + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            )
            package.add(
                "ppt/slides/_rels/slide\(number).xml.rels",
                header + #"<Relationships xmlns="\#(relationshipsNamespace)">"# + slideRelationships
                    + "</Relationships>")
        }
        package.add(
            "ppt/slideMasters/slideMaster1.xml",
            header
                + "<p:sldMaster \(ns)><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg><p:spTree>\(group)"
                + textBox(
                    id: 2, name: "Title Placeholder 1", placeholder: "title", paragraphs: [],
                    frame: (838200, 365125, 10515600, 1325563))
                + textBox(
                    id: 3, name: "Text Placeholder 2", placeholder: "body", index: 1,
                    paragraphs: [], frame: (838200, 1825625, 10515600, 4351338))
                + #"</p:spTree></p:cSld><p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/><p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst><p:txStyles><p:titleStyle><a:lvl1pPr algn="l"><a:defRPr sz="4400"/></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr marL="228600" indent="-228600"><a:buFont typeface="Arial"/><a:buChar char="•"/><a:defRPr sz="2800"/></a:lvl1pPr></p:bodyStyle><p:otherStyle><a:lvl1pPr><a:defRPr sz="1800"/></a:lvl1pPr></p:otherStyle></p:txStyles></p:sldMaster>"#
        )
        package.add(
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/slideLayout" Target="../slideLayouts/slideLayout1.xml"/><Relationship Id="rId2" Type="\#(officeRelationships)/theme" Target="../theme/theme1.xml"/>"#
                + "</Relationships>")
        package.add(
            "ppt/slideLayouts/slideLayout1.xml",
            header
                + "<p:sldLayout \(ns) type=\"obj\" preserve=\"1\"><p:cSld name=\"Title and Content\"><p:spTree>\(group)"
                + textBox(id: 2, name: "Title 1", placeholder: "title", paragraphs: [])
                + textBox(
                    id: 3, name: "Content Placeholder 2", placeholder: nil, index: 1, paragraphs: []
                )
                + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>"
        )
        package.add(
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/slideMaster" Target="../slideMasters/slideMaster1.xml"/>"#
                + "</Relationships>")
        package.add("ppt/theme/theme1.xml", OOXMLTheme.xml)
        package.add(
            "ppt/presentation.xml",
            header + "<p:presentation \(ns) saveSubsetFonts=\"1\">"
                + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>"#
                + "<p:sldIdLst>\(list)</p:sldIdLst>"
                + #"<p:sldSz cx="12192000" cy="6858000"/><p:notesSz cx="6858000" cy="9144000"/></p:presentation>"#
        )
        package.add(
            "ppt/_rels/presentation.xml.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"# + relationships
                + "</Relationships>")
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>"#
                + #"<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>"#
                + overrides + "</Types>")
        package.add(
            "_rels/.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/officeDocument" Target="ppt/presentation.xml"/></Relationships>"#
        )
        try package.write(to: url)
    }
}

extension DocsAuditFixtures {
    static func find(_ needle: String, in document: PDFDocument) -> [(page: Int, rect: CGRect)] {
        document.findString(needle, withOptions: []).compactMap { selection in
            guard let page = selection.pages.first else { return nil }
            return (document.index(for: page), selection.bounds(for: page))
        }
    }

    static func fontSize(of needle: String, in document: PDFDocument) -> CGFloat? {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.attributedString else {
                continue
            }
            let range = (text.string as NSString).range(of: needle)
            guard range.location != NSNotFound else { continue }
            return (text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)?
                .pointSize
        }
        return nil
    }

    static func minimalDOCX(at url: URL, body: String) throws {
        var package = OOXMLPackage()
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/></Types>"#
        )
        package.add(
            "_rels/.rels",
            header + #"<Relationships xmlns="\#(relationshipsNamespace)">"#
                + #"<Relationship Id="rId1" Type="\#(officeRelationships)/officeDocument" Target="/word/document.xml"/></Relationships>"#
        )
        package.add(
            "word/document.xml",
            header + "<w:document \(wordNamespaces)><w:body>" + body + "</w:body></w:document>")
        try package.write(to: url)
    }

    static func encryptedOffice(at url: URL) throws {
        var data = Data([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1])
        data.append(Data(repeating: 0, count: 504))
        data.append(Data("EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }))
        data.append(Data(repeating: 7, count: 2048))
        try data.write(to: url)
    }

    static func damagedFiles(named stem: String, ext: String, in space: Workspace) throws -> [URL] {
        let empty = space.url("\(stem)-empty.\(ext)")
        try Data().write(to: empty)
        let garbage = space.url("\(stem)-garbage.\(ext)")
        try Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 7919 &+ 13) }).write(to: garbage)
        let encrypted = space.url("\(stem)-locked.\(ext)")
        try encryptedOffice(at: encrypted)
        let truncated = space.url("\(stem)-truncated.\(ext)")
        var package = OOXMLPackage()
        package.add("[Content_Types].xml", header + "<Types/>")
        package.add("word/document.xml", header + "<w:document><w:body><w:p><w:r><w:t>Broken")
        try package.write(to: truncated)
        return [empty, garbage, encrypted, truncated]
    }
}
