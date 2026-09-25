import CoreGraphics
import Foundation

public struct DOCXWriter {
    public struct Run: Equatable {
        public var text: String
        public var size: Double
        public var bold: Bool
        public var italic: Bool
        public var font: String?
        public var color: String?

        public init(
            text: String, size: Double = 11, bold: Bool = false, italic: Bool = false,
            font: String? = nil, color: String? = nil
        ) {
            self.text = text
            self.size = size
            self.bold = bold
            self.italic = italic
            self.font = font
            self.color = color
        }
    }

    public enum Block {
        case paragraph([Run], heading: Int?)
        case image(Data, ext: String, width: Double, height: Double)
        case pageBreak
        case table([[String]])
    }

    public static func write(
        _ blocks: [Block], title: String, pageSize: CGSize = CGSize(width: 612, height: 792),
        margin: Double = 54, to url: URL
    ) throws {
        let header = OOXMLPackage.xmlHeader
        var package = OOXMLPackage()
        var body = ""
        var relationships =
            header
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
        var imageCount = 0
        let usableWidth = pageSize.width - margin * 2
        let usableHeight = pageSize.height - margin * 2
        for block in blocks {
            switch block {
            case let .paragraph(runs, heading):
                body += paragraph(runs, heading: heading)
            case .pageBreak:
                body += #"<w:p><w:r><w:br w:type="page"/></w:r></w:p>"#
            case let .table(rows):
                body += table(rows)
            case let .image(data, ext, width, height):
                imageCount += 1
                let id = "rIdImage\(imageCount)"
                let name = "image\(imageCount).\(ext)"
                package.add("word/media/\(name)", data: data)
                relationships +=
                    #"<Relationship Id="\#(id)" Type="\#(OOXMLPackage.imageRelationship)" Target="media/\#(name)"/>"#
                let scale = min(1, usableWidth / max(width, 1), usableHeight / max(height, 1))
                body += drawing(
                    id: id, index: imageCount, width: width * scale, height: height * scale)
            }
        }
        relationships += "</Relationships>"
        let twips = { (points: Double) in Int((points * 20).rounded()) }
        let document =
            header
            + #"<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing" xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"><w:body>"#
            + body
            + #"<w:sectPr><w:pgSz w:w="\#(twips(pageSize.width))" w:h="\#(twips(pageSize.height))"/><w:pgMar w:top="\#(twips(margin))" w:right="\#(twips(margin))" w:bottom="\#(twips(margin))" w:left="\#(twips(margin))" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>"#
            + "</w:body></w:document>"
        package.add(
            "[Content_Types].xml",
            header
                + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
                + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
                + #"<Default Extension="xml" ContentType="application/xml"/>"#
                + #"<Default Extension="png" ContentType="image/png"/>"#
                + #"<Default Extension="jpg" ContentType="image/jpeg"/>"#
                + #"<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>"#
                + #"<Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/>"#
                + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
                + "</Types>")
        package.add(
            "_rels/.rels",
            OOXMLPackage.rootRelationships(
                main: "word/document.xml", type: OOXMLPackage.officeDocumentType))
        package.add("docProps/core.xml", OOXMLPackage.coreProperties(title: title))
        package.add("word/document.xml", document)
        package.add("word/_rels/document.xml.rels", relationships)
        package.add("word/styles.xml", styles)
        try package.write(to: url)
    }

    static func paragraph(_ runs: [Run], heading: Int?) -> String {
        var xml = "<w:p>"
        if let heading { xml += #"<w:pPr><w:pStyle w:val="Heading\#(heading)"/></w:pPr>"# }
        for run in runs {
            xml += "<w:r><w:rPr>"
            if let font = run.font {
                let escaped = OOXMLPackage.escape(font)
                xml +=
                    #"<w:rFonts w:ascii="\#(escaped)" w:hAnsi="\#(escaped)" w:cs="\#(escaped)"/>"#
            }
            if run.bold { xml += "<w:b/>" }
            if run.italic { xml += "<w:i/>" }
            if let color = run.color { xml += #"<w:color w:val="\#(color)"/>"# }
            let half = Int((run.size * 2).rounded())
            xml += #"<w:sz w:val="\#(half)"/><w:szCs w:val="\#(half)"/></w:rPr>"#
            let lines = run.text.components(separatedBy: "\n")
            for (index, line) in lines.enumerated() {
                if index > 0 { xml += "<w:br/>" }
                xml += #"<w:t xml:space="preserve">\#(OOXMLPackage.escape(line))</w:t>"#
            }
            xml += "</w:r>"
        }
        return xml + "</w:p>"
    }

    static func table(_ rows: [[String]]) -> String {
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return "" }
        var xml =
            #"<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/><w:tblBorders>"#
            + ["top", "left", "bottom", "right", "insideH", "insideV"].map {
                #"<w:\#($0) w:val="single" w:sz="4" w:space="0" w:color="BFBFBF"/>"#
            }.joined()
            + "</w:tblBorders></w:tblPr><w:tblGrid>"
            + String(repeating: #"<w:gridCol w:w="2000"/>"#, count: columns) + "</w:tblGrid>"
        for row in rows {
            xml += "<w:tr>"
            for column in 0..<columns {
                let value = column < row.count ? row[column] : ""
                xml +=
                    #"<w:tc><w:tcPr><w:tcW w:w="2000" w:type="dxa"/></w:tcPr><w:p><w:r><w:t xml:space="preserve">\#(OOXMLPackage.escape(value))</w:t></w:r></w:p></w:tc>"#
            }
            xml += "</w:tr>"
        }
        return xml + "</w:tbl><w:p/>"
    }

    static func drawing(id: String, index: Int, width: Double, height: Double) -> String {
        let cx = Int(width * 12700)
        let cy = Int(height * 12700)
        return
            #"<w:p><w:r><w:drawing><wp:inline distT="0" distB="0" distL="0" distR="0"><wp:extent cx="\#(cx)" cy="\#(cy)"/><wp:docPr id="\#(index)" name="Picture \#(index)"/>"#
            + #"<wp:cNvGraphicFramePr><a:graphicFrameLocks noChangeAspect="1"/></wp:cNvGraphicFramePr>"#
            + #"<a:graphic><a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture"><pic:pic>"#
            + #"<pic:nvPicPr><pic:cNvPr id="\#(index)" name="Picture \#(index)"/><pic:cNvPicPr/></pic:nvPicPr>"#
            + #"<pic:blipFill><a:blip r:embed="\#(id)"/><a:stretch><a:fillRect/></a:stretch></pic:blipFill>"#
            + #"<pic:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(cx)" cy="\#(cy)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></pic:spPr>"#
            + "</pic:pic></a:graphicData></a:graphic></wp:inline></w:drawing></w:r></w:p>"
    }

    static var styles: String {
        let headings = (1...3).map { level -> String in
            let size = [0, 40, 32, 26][level]
            return
                #"<w:style w:type="paragraph" w:styleId="Heading\#(level)"><w:name w:val="heading \#(level)"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before="240" w:after="80"/><w:outlineLvl w:val="\#(level - 1)"/></w:pPr><w:rPr><w:b/><w:sz w:val="\#(size)"/><w:szCs w:val="\#(size)"/></w:rPr></w:style>"#
        }.joined()
        return OOXMLPackage.xmlHeader
            + #"<w:styles xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">"#
            + #"<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="264" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>"#
            + #"<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>"#
            + headings + "</w:styles>"
    }
}
