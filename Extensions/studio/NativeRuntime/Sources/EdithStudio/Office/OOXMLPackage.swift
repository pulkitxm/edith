import Foundation
import ZIPFoundation

public struct OOXMLPackage {
    public var parts: [(path: String, data: Data)] = []

    public init() {}

    public mutating func add(_ path: String, _ text: String) {
        parts.append((path, Data(text.utf8)))
    }

    public mutating func add(_ path: String, data: Data) {
        parts.append((path, data))
    }

    public func write(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        let archive = try Archive(url: url, accessMode: .create)
        for part in parts {
            let data = part.data
            try archive.addEntry(
                with: part.path, type: .file, uncompressedSize: Int64(data.count),
                compressionMethod: .deflate
            ) { position, size in
                let start = Int(position)
                return data.subdata(in: start..<min(start + size, data.count))
            }
        }
    }

    public static func read(_ url: URL) throws -> [String: Data] {
        let archive = try Archive(url: url, accessMode: .read)
        var entries: [String: Data] = [:]
        var budget = 1 << 30
        for entry in archive where entry.type == .file {
            guard entry.uncompressedSize < 200 << 20 else { continue }
            var data = Data()
            _ = try archive.extract(entry, skipCRC32: true) { chunk in
                data.append(chunk)
                budget -= chunk.count
                if data.count > 200 << 20 || budget < 0 {
                    throw StudioError.unreadable(url.lastPathComponent)
                }
            }
            entries[entry.path] = data
        }
        return entries
    }

    public enum Signature: Equatable {
        case zip
        case compound
        case encrypted
        case rtf
        case html
        case empty
        case unknown
    }

    public static func signature(_ url: URL) -> Signature {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .unknown }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 512)) ?? Data()
        if head.isEmpty { return .empty }
        let bytes = [UInt8](head)
        if bytes.starts(with: [0x50, 0x4B, 0x03, 0x04])
            || bytes.starts(with: [0x50, 0x4B, 0x05, 0x06])
        {
            return .zip
        }
        if bytes.starts(with: [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            let marker = Data(
                "EncryptedPackage".utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] })
            let whole = (try? Data(contentsOf: url, options: .alwaysMapped)) ?? head
            return whole.range(of: marker) != nil ? .encrypted : .compound
        }
        let text = String(decoding: head.prefix(256), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(["\u{FEFF}"]))
            .lowercased()
        if text.hasPrefix("{\\rtf") { return .rtf }
        if text.hasPrefix("<!doctype html") || text.hasPrefix("<html")
            || text.hasPrefix("<?xml")
                && text.contains("<html")
        {
            return .html
        }
        return .unknown
    }

    public static func requirePackage(_ url: URL, application: String, format: String) throws {
        let name = url.lastPathComponent
        switch signature(url) {
        case .zip: return
        case .empty: throw StudioError.nothingToDo("\(name) is empty.")
        case .encrypted:
            throw StudioError.failed(
                "\(name) is password protected. Open it in \(application), remove the password, then try again."
            )
        case .compound:
            throw StudioError.unsupportedInput(
                name, "this tool. It is an older \(application) file, save it as \(format) first")
        default: throw StudioError.unreadable(name)
        }
    }

    public static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&apos;"
            default:
                let value = scalar.value
                if value < 0x20 && value != 0x09 && value != 0x0A && value != 0x0D { continue }
                if (0xD800...0xDFFF).contains(value) || value == 0xFFFE || value == 0xFFFF {
                    continue
                }
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    static let xmlHeader = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#

    static let imageTypes = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif",
        "tif": "image/tiff", "tiff": "image/tiff", "bmp": "image/bmp",
    ]

    static func imageExtension(_ ext: String) -> String {
        let lowered = ext.lowercased()
        return imageTypes[lowered] == nil ? "png" : lowered
    }

    static func imageDefaults(_ extensions: Set<String>) -> String {
        (extensions.union(["png", "jpg"])).sorted().compactMap { ext in
            imageTypes[ext].map { #"<Default Extension="\#(ext)" ContentType="\#($0)"/>"# }
        }.joined()
    }

    static func coreProperties(title: String) -> String {
        let date = ISO8601DateFormatter().string(from: Date())
        return xmlHeader
            + #"<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:dcterms="http://purl.org/dc/terms/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">"#
            + "<dc:title>\(escape(title))</dc:title><dc:creator>Edith Studio</dc:creator>"
            + #"<dcterms:created xsi:type="dcterms:W3CDTF">\#(date)</dcterms:created>"#
            + #"<dcterms:modified xsi:type="dcterms:W3CDTF">\#(date)</dcterms:modified>"#
            + "</cp:coreProperties>"
    }

    static func rootRelationships(main: String, type: String) -> String {
        xmlHeader
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="\#(type)" Target="\#(main)"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>"#
            + "</Relationships>"
    }

    static let officeDocumentType =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument"
    static let imageRelationship =
        "http://schemas.openxmlformats.org/officeDocument/2006/relationships/image"
}

public struct XLSXWriter {
    public struct Sheet {
        public var name: String
        public var rows: [[String]]

        public init(name: String, rows: [[String]]) {
            self.name = name
            self.rows = rows
        }
    }

    public static func write(_ sheets: [Sheet], title: String, to url: URL) throws {
        var package = OOXMLPackage()
        let usable = sheets.isEmpty ? [Sheet(name: "Sheet1", rows: [])] : sheets
        var names = Set<String>()
        let sheetNames = usable.enumerated().map { index, sheet -> String in
            var name = String(
                sheet.name.components(separatedBy: CharacterSet(charactersIn: "[]:*?/\\")).joined()
                    .components(separatedBy: .controlCharacters).joined()
                    .trimmingCharacters(in: CharacterSet(charactersIn: "' "))
                    .prefix(28)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "' "))
            if name.isEmpty || name.lowercased() == "history" { name = "Sheet\(index + 1)" }
            var candidate = name
            var suffix = 2
            while !names.insert(candidate.lowercased()).inserted {
                candidate = "\(name) \(suffix)"
                suffix += 1
            }
            return candidate
        }
        let header = OOXMLPackage.xmlHeader
        var contentTypes =
            header
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + #"<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>"#
            + #"<Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        var workbook =
            header
            + #"<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets>"#
        var relationships =
            header
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
        for (index, sheet) in usable.enumerated() {
            let number = index + 1
            contentTypes +=
                #"<Override PartName="/xl/worksheets/sheet\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>"#
            workbook +=
                #"<sheet name="\#(OOXMLPackage.escape(sheetNames[index]))" sheetId="\#(number)" r:id="rId\#(number)"/>"#
            relationships +=
                #"<Relationship Id="rId\#(number)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet\#(number).xml"/>"#
            package.add("xl/worksheets/sheet\(number).xml", worksheet(sheet.rows))
        }
        let styleID = usable.count + 1
        relationships +=
            #"<Relationship Id="rId\#(styleID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>"#
            + "</Relationships>"
        workbook += "</sheets></workbook>"
        contentTypes += "</Types>"
        package.add("[Content_Types].xml", contentTypes)
        package.add(
            "_rels/.rels",
            OOXMLPackage.rootRelationships(
                main: "xl/workbook.xml", type: OOXMLPackage.officeDocumentType))
        package.add("docProps/core.xml", OOXMLPackage.coreProperties(title: title))
        package.add("xl/workbook.xml", workbook)
        package.add("xl/_rels/workbook.xml.rels", relationships)
        package.add(
            "xl/styles.xml",
            header
                + #"<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">"#
                + #"<fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts>"#
                + #"<fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>"#
                + #"<borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>"#
                + #"<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>"#
                + #"<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>"#
                + "</styleSheet>")
        try package.write(to: url)
    }

    public static func columnName(_ index: Int) -> String {
        var number = index + 1
        var name = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            name = String(UnicodeScalar(65 + remainder)!) + name
            number = (number - 1) / 26
        }
        return name
    }

    static func worksheet(_ rows: [[String]]) -> String {
        var xml =
            OOXMLPackage.xmlHeader
            + #"<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>"#
        for (rowIndex, row) in rows.enumerated() {
            xml += #"<row r="\#(rowIndex + 1)">"#
            for (columnIndex, value) in row.enumerated() where !value.isEmpty {
                let reference = columnName(columnIndex) + String(rowIndex + 1)
                if let number = numericValue(value) {
                    xml += #"<c r="\#(reference)"><v>\#(number)</v></c>"#
                } else {
                    let clipped = String(value.prefix(32_767))
                    xml +=
                        #"<c r="\#(reference)" t="inlineStr"><is><t xml:space="preserve">\#(OOXMLPackage.escape(clipped))</t></is></c>"#
                }
            }
            xml += "</row>"
        }
        return xml + "</sheetData></worksheet>"
    }

    static func numericValue(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, text.count < 16 else { return nil }
        guard
            text.range(
                of: #"^-?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$"#, options: .regularExpression) != nil
        else { return nil }
        let cleaned = text.replacingOccurrences(of: ",", with: "")
        if cleaned.hasPrefix("0"), cleaned.count > 1, !cleaned.hasPrefix("0.") { return nil }
        return cleaned
    }
}

public struct PPTXWriter {
    public struct Slide {
        public var image: Data
        public var imageExtension: String
        public var notes: String?

        public init(image: Data, imageExtension: String, notes: String? = nil) {
            self.image = image
            self.imageExtension = imageExtension
            self.notes = notes
        }
    }

    static func slideSize(_ size: CGSize) -> (width: Int, height: Int) {
        let emu = 12700.0
        var width = max(1, Double(size.width) * emu)
        var height = max(1, Double(size.height) * emu)
        let largest = 51_206_400.0
        let smallest = 914_400.0
        let shrink = min(1, largest / max(width, height))
        width *= shrink
        height *= shrink
        let grow = max(1, smallest / min(width, height))
        if max(width, height) * grow <= largest {
            width *= grow
            height *= grow
        }
        return (
            Int(min(max(width, smallest), largest).rounded()),
            Int(min(max(height, smallest), largest).rounded())
        )
    }

    public static func write(_ slides: [Slide], size: CGSize, title: String, to url: URL) throws {
        let (width, height) = slideSize(size)
        let namespaces =
            #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
        let hasNotes = slides.contains {
            !($0.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let extensions = Set(slides.map { OOXMLPackage.imageExtension($0.imageExtension) })
        let header = OOXMLPackage.xmlHeader
        var package = OOXMLPackage()
        var contentTypes =
            header
            + #"<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">"#
            + #"<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>"#
            + #"<Default Extension="xml" ContentType="application/xml"/>"#
            + OOXMLPackage.imageDefaults(extensions)
            + #"<Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/>"#
            + #"<Override PartName="/ppt/slideMasters/slideMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideMaster+xml"/>"#
            + #"<Override PartName="/ppt/slideLayouts/slideLayout1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slideLayout+xml"/>"#
            + #"<Override PartName="/ppt/theme/theme1.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
            + #"<Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>"#
        var slideList = ""
        var presentationRels =
            header
            + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
            + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="slideMasters/slideMaster1.xml"/>"#
            + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="theme/theme1.xml"/>"#
        for (index, slide) in slides.enumerated() {
            let number = index + 1
            let relID = number + 2
            contentTypes +=
                #"<Override PartName="/ppt/slides/slide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/>"#
            slideList += #"<p:sldId id="\#(255 + number)" r:id="rId\#(relID)"/>"#
            presentationRels +=
                #"<Relationship Id="rId\#(relID)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide\#(number).xml"/>"#
            let media = "image\(number).\(OOXMLPackage.imageExtension(slide.imageExtension))"
            package.add("ppt/media/\(media)", data: slide.image)
            var slideRelationships =
                #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
                + #"<Relationship Id="rId2" Type="\#(OOXMLPackage.imageRelationship)" Target="../media/\#(media)"/>"#
            if let notes = slide.notes, hasNotes,
                !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                contentTypes +=
                    #"<Override PartName="/ppt/notesSlides/notesSlide\#(number).xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesSlide+xml"/>"#
                slideRelationships +=
                    #"<Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesSlide" Target="../notesSlides/notesSlide\#(number).xml"/>"#
                package.add(
                    "ppt/notesSlides/notesSlide\(number).xml",
                    header + "<p:notes \(namespaces)><p:cSld><p:spTree>" + groupProperties
                        + #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>"#
                        + #"<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/>"#
                        + paragraphs(notes) + "</p:txBody></p:sp></p:spTree></p:cSld>"
                        + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>")
                package.add(
                    "ppt/notesSlides/_rels/notesSlide\(number).xml.rels",
                    header
                        + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                        + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="../notesMasters/notesMaster1.xml"/>"#
                        + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="../slides/slide\#(number).xml"/>"#
                        + "</Relationships>")
            }
            package.add(
                "ppt/slides/_rels/slide\(number).xml.rels",
                header
                    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                    + slideRelationships + "</Relationships>")
            package.add(
                "ppt/slides/slide\(number).xml",
                header
                    + #"<p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree>"#
                    + #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>"#
                    + #"<p:pic><p:nvPicPr><p:cNvPr id="2" name="Page \#(number)"/><p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>"#
                    + #"<p:blipFill><a:blip r:embed="rId2"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>"#
                    + #"<p:spPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="\#(width)" cy="\#(height)"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:pic>"#
                    + "</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>"
            )
        }
        if hasNotes {
            presentationRels +=
                #"<Relationship Id="rIdNotesMaster" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/notesMaster" Target="notesMasters/notesMaster1.xml"/>"#
            contentTypes +=
                #"<Override PartName="/ppt/notesMasters/notesMaster1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.notesMaster+xml"/>"#
                + #"<Override PartName="/ppt/theme/theme2.xml" ContentType="application/vnd.openxmlformats-officedocument.theme+xml"/>"#
            package.add(
                "ppt/notesMasters/notesMaster1.xml",
                header + "<p:notesMaster \(namespaces)><p:cSld><p:spTree>" + groupProperties
                    + #"<p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr><p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="1143000" y="685800"/><a:ext cx="4572000" cy="3429000"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr></p:sp>"#
                    + #"<p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr><p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr><p:spPr><a:xfrm><a:off x="685800" y="4343400"/><a:ext cx="5486400" cy="4114800"/></a:xfrm><a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:endParaRPr lang="en-US"/></a:p></p:txBody></p:sp>"#
                    + "</p:spTree></p:cSld>"
                    + #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#
                    + #"<p:notesStyle><a:lvl1pPr marL="0" algn="l"><a:defRPr sz="1200"/></a:lvl1pPr></p:notesStyle></p:notesMaster>"#
            )
            package.add(
                "ppt/notesMasters/_rels/notesMaster1.xml.rels",
                header
                    + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                    + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme2.xml"/>"#
                    + "</Relationships>")
            package.add("ppt/theme/theme2.xml", OOXMLTheme.xml)
        }
        presentationRels += "</Relationships>"
        contentTypes += "</Types>"
        package.add("[Content_Types].xml", contentTypes)
        package.add(
            "_rels/.rels",
            OOXMLPackage.rootRelationships(
                main: "ppt/presentation.xml", type: OOXMLPackage.officeDocumentType))
        package.add("docProps/core.xml", OOXMLPackage.coreProperties(title: title))
        package.add(
            "ppt/presentation.xml",
            header
                + #"<p:presentation xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">"#
                + #"<p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>"#
                + (hasNotes
                    ? #"<p:notesMasterIdLst><p:notesMasterId r:id="rIdNotesMaster"/></p:notesMasterIdLst>"#
                    : "")
                + "<p:sldIdLst>\(slideList)</p:sldIdLst>"
                + #"<p:sldSz cx="\#(width)" cy="\#(height)"/><p:notesSz cx="6858000" cy="9144000"/>"#
                + "</p:presentation>")
        package.add("ppt/_rels/presentation.xml.rels", presentationRels)
        package.add(
            "ppt/slideMasters/slideMaster1.xml",
            header
                + #"<p:sldMaster xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main">"#
                + #"<p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
                + #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#
                + #"<p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/></p:sldLayoutIdLst>"#
                + "</p:sldMaster>")
        package.add(
            "ppt/slideMasters/_rels/slideMaster1.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideLayout" Target="../slideLayouts/slideLayout1.xml"/>"#
                + #"<Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/theme" Target="../theme/theme1.xml"/>"#
                + "</Relationships>")
        package.add(
            "ppt/slideLayouts/slideLayout1.xml",
            header
                + #"<p:sldLayout xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" type="blank">"#
                + #"<p:cSld name="Blank"><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/></p:spTree></p:cSld>"#
                + "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>")
        package.add(
            "ppt/slideLayouts/_rels/slideLayout1.xml.rels",
            header
                + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
                + #"<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slideMaster" Target="../slideMasters/slideMaster1.xml"/>"#
                + "</Relationships>")
        package.add("ppt/theme/theme1.xml", OOXMLTheme.xml)
        try package.write(to: url)
    }

    static let groupProperties =
        #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#

    static func paragraphs(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").map {
            line in
            line.isEmpty
                ? #"<a:p><a:endParaRPr lang="en-US"/></a:p>"#
                : #"<a:p><a:r><a:rPr lang="en-US" dirty="0"/><a:t>\#(OOXMLPackage.escape(line))</a:t></a:r></a:p>"#
        }.joined()
    }
}

enum OOXMLTheme {
    static var xml: String {
        let colors = [
            ("dk1", "000000"), ("lt1", "FFFFFF"), ("dk2", "1F2937"), ("lt2", "F3F4F6"),
            ("accent1", "D97757"), ("accent2", "4472C4"), ("accent3", "70AD47"),
            ("accent4", "FFC000"), ("accent5", "5B9BD5"), ("accent6", "A5A5A5"),
            ("hlink", "0563C1"), ("folHlink", "954F72"),
        ]
        let scheme = colors.map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
        let fill = #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#
        let line = #"<a:ln w="9525"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
        return OOXMLPackage.xmlHeader
            + #"<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Studio"><a:themeElements>"#
            + #"<a:clrScheme name="Studio">\#(scheme)</a:clrScheme>"#
            + #"<a:fontScheme name="Studio"><a:majorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:majorFont><a:minorFont><a:latin typeface="Calibri"/><a:ea typeface=""/><a:cs typeface=""/></a:minorFont></a:fontScheme>"#
            + #"<a:fmtScheme name="Studio"><a:fillStyleLst>\#(fill)\#(fill)\#(fill)</a:fillStyleLst>"#
            + "<a:lnStyleLst>\(line)\(line)\(line)</a:lnStyleLst>"
            + "<a:effectStyleLst><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle><a:effectStyle><a:effectLst/></a:effectStyle></a:effectStyleLst>"
            + "<a:bgFillStyleLst>\(fill)\(fill)\(fill)</a:bgFillStyleLst></a:fmtScheme>"
            + "</a:themeElements></a:theme>"
    }
}
