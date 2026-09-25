import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import EdithStudio

enum DocumentFixtures {
    static func docx(at url: URL, paragraphs: Int = 3) throws {
        var blocks: [DOCXWriter.Block] = [
            .paragraph([DOCXWriter.Run(text: "Project Plan", size: 24, bold: true)], heading: 1)
        ]
        for index in 0..<paragraphs {
            blocks.append(
                .paragraph(
                    [
                        DOCXWriter.Run(text: "Paragraph \(index + 1) explains "),
                        DOCXWriter.Run(text: "important", bold: true),
                        DOCXWriter.Run(text: " details of the rollout."),
                    ], heading: nil))
        }
        blocks.append(.table([["Name", "Owner"], ["Launch", "Maya"]]))
        try DOCXWriter.write(blocks, title: "Plan", to: url)
    }

    static func xlsx(at url: URL, rows: Int = 4) throws {
        var data = [["Region", "Revenue", "Active"]]
        for index in 0..<rows {
            data.append(["Region \(index + 1)", "\(1000 + index * 250)", "TRUE"])
        }
        try XLSXWriter.write(
            [
                XLSXWriter.Sheet(name: "Sales", rows: data),
                XLSXWriter.Sheet(name: "Notes", rows: [["Owner"], ["Maya Chen"]]),
            ], title: "Book", to: url)
    }

    static func sharedStringsXLSX(at url: URL) throws {
        var package = OOXMLPackage()
        let header = OOXMLPackage.xmlHeader
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/></Types>"#
        )
        package.add(
            "xl/workbook.xml",
            header
                + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>"#
        )
        package.add(
            "xl/_rels/workbook.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>"#
        )
        package.add(
            "xl/sharedStrings.xml",
            header
                + #"<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Item</t></si><si><r><t>Due</t></r><r><t xml:space="preserve"> date</t></r></si><si><t>Widget</t></si></sst>"#
        )
        package.add(
            "xl/styles.xml",
            header
                + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>"#
        )
        package.add(
            "xl/worksheets/sheet1.xml",
            header
                + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="C1" t="s"><v>1</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>2.5</v></c><c r="C2" s="1"><v>45000</v></c><c r="D2" t="b"><v>0</v></c></row></sheetData></worksheet>"#
        )
        try package.write(to: url)
    }

    static func pptx(at url: URL) throws {
        var package = OOXMLPackage()
        let header = OOXMLPackage.xmlHeader
        let ns =
            #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/></Types>"#
        )
        package.add(
            "ppt/presentation.xml",
            header + "<p:presentation \(ns)>"
                + #"<p:sldIdLst><p:sldId id="256" r:id="rId3"/><p:sldId id="257" r:id="rId4"/></p:sldIdLst><p:sldSz cx="9144000" cy="5143500"/></p:presentation>"#
        )
        package.add(
            "ppt/_rels/presentation.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide2.xml"/><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/></Relationships>"#
        )
        package.add(
            "ppt/slideMasters/slideMaster1.xml",
            header
                + "<p:sldMaster \(ns)><p:cSld><p:bg><p:bgPr><a:solidFill><a:srgbClr val=\"F4F1EA\"/></a:solidFill></p:bgPr></p:bg><p:spTree>"
                + placeholder(id: 2, type: "title", x: 457200, y: 228600, cx: 8229600, cy: 857250)
                + placeholder(id: 3, type: "body", x: 457200, y: 2500000, cx: 8229600, cy: 2400000)
                + "</p:spTree></p:cSld><p:txStyles><p:titleStyle><a:lvl1pPr><a:defRPr sz=\"4000\" b=\"1\"><a:solidFill><a:srgbClr val=\"1F2937\"/></a:solidFill></a:defRPr></a:lvl1pPr></p:titleStyle><p:bodyStyle><a:lvl1pPr><a:buChar char=\"•\"/><a:defRPr sz=\"2400\"/></a:lvl1pPr></p:bodyStyle></p:txStyles></p:sldMaster>"
        )
        package.add(
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/></Relationships>"#
        )
        package.add(
            "ppt/slideLayouts/slideLayout1.xml",
            header + "<p:sldLayout \(ns)><p:cSld><p:spTree>"
                + placeholder(id: 2, type: "title", x: 457200, y: 1500000, cx: 8229600, cy: 800000)
                + "</p:spTree></p:cSld></p:sldLayout>")
        package.add(
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/></Relationships>"#
        )
        let layoutRels =
            #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
        package.add(
            "ppt/slides/slide1.xml",
            header + "<p:sld \(ns)><p:cSld><p:spTree>"
                + textShape(id: 2, type: "title", text: ["Quarterly Review"])
                + textShape(
                    id: 3, type: "body", text: ["Revenue up 12 percent", "Two launches shipped"])
                + "</p:spTree></p:cSld></p:sld>")
        package.add(
            "ppt/slides/_rels/slide1.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + layoutRels
                + "</Relationships>")
        let image = try pngData(width: 40, height: 30)
        package.add("ppt/media/image1.png", data: image)
        package.add(
            "ppt/slides/slide2.xml",
            header + "<p:sld \(ns)><p:cSld><p:spTree>"
                + textShape(id: 2, type: "title", text: ["Next Steps"])
                + #"<p:sp><p:nvSpPr><p:cNvPr id="4" name="Box"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr><a:xfrm><a:off x="4572000" y="2000000"/><a:ext cx="3000000" cy="1000000"/></a:xfrm><a:prstGeom prst="rect"/><a:solidFill><a:srgbClr val="D97757"/></a:solidFill></p:spPr><p:txBody><a:bodyPr anchor="ctr"/><a:p><a:pPr algn="ctr"/><a:r><a:rPr sz="2000" b="1"><a:solidFill><a:srgbClr val="FFFFFF"/></a:solidFill></a:rPr><a:t>Hire two engineers</a:t></a:r></a:p></p:txBody></p:sp>"#
                + #"<p:pic><p:nvPicPr><p:cNvPr id="5" name="Logo"/><p:cNvPicPr/><p:nvPr/></p:nvPicPr><p:blipFill><a:blip r:embed="rId2"/></p:blipFill><p:spPr><a:xfrm><a:off x="500000" y="2000000"/><a:ext cx="2000000" cy="1500000"/></a:xfrm></p:spPr></p:pic>"#
                + "</p:spTree></p:cSld></p:sld>")
        package.add(
            "ppt/slides/_rels/slide2.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + layoutRels
                + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="../media/image1.png"/>"#
                + "</Relationships>")
        try package.write(to: url)
    }

    static func placeholder(id: Int, type: String, x: Int, y: Int, cx: Int, cy: Int) -> String {
        "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(type)\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"\(type)\"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(cx)\" cy=\"\(cy)\"/></a:xfrm></p:spPr><p:txBody><a:bodyPr/><a:p><a:endParaRPr/></a:p></p:txBody></p:sp>"
    }

    static func textShape(id: Int, type: String, text: [String]) -> String {
        let paragraphs = text.map {
            "<a:p><a:r><a:rPr lang=\"en-US\"/><a:t>\($0)</a:t></a:r></a:p>"
        }
        .joined()
        return
            "<p:sp><p:nvSpPr><p:cNvPr id=\"\(id)\" name=\"\(type)\"/><p:cNvSpPr/><p:nvPr><p:ph type=\"\(type)\"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/>\(paragraphs)</p:txBody></p:sp>"
    }

    static func pngData(width: Int, height: Int) throws -> Data {
        let image = Fixtures.photo(width: width, height: height)
        return try StudioImageIO.encode(image, format: .png)
    }
}
