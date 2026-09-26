import AppKit
import Foundation

public struct LoadedDocument {
    public let text: NSAttributedString
    public let paperSize: CGSize?
    public let margins: NSEdgeInsets?
    public var sections: [DocumentSection]?

    public init(
        text: NSAttributedString, paperSize: CGSize?, margins: NSEdgeInsets?,
        sections: [DocumentSection]? = nil
    ) {
        self.text = text
        self.paperSize = paperSize
        self.margins = margins
        self.sections = sections
    }
}

public enum DocumentLoader {
    static let appPackages: Set<String> = ["pages", "key", "numbers"]

    public static func load(_ url: URL) async throws -> LoadedDocument {
        let ext = url.pathExtension.lowercased()
        if appPackages.contains(ext) {
            throw StudioError.unsupportedInput(
                url.lastPathComponent,
                "this tool. Export it from \(appName(ext)) as Word, Excel, PowerPoint or PDF first")
        }
        switch ext {
        case "md", "markdown":
            let raw = try readText(url)
            return LoadedDocument(
                text: MarkdownStyler.attributed(raw, base: url), paperSize: nil, margins: nil)
        case "txt", "text":
            let raw = try readText(url)
            return LoadedDocument(text: plain(raw), paperSize: nil, margins: nil)
        case "html", "htm":
            let data = try Data(contentsOf: url)
            return try await MainActor.run {
                try read(data: data, type: .html, name: url.lastPathComponent, base: url)
            }
        case "docx", "doc", "rtf", "odt", "wordml":
            return try await loadWord(url, ext: ext)
        default:
            let type = documentType(for: ext)
            return try readFile(url, type: type)
        }
    }

    static func loadWord(_ url: URL, ext: String) async throws -> LoadedDocument {
        switch OOXMLPackage.signature(url) {
        case .empty:
            throw StudioError.nothingToDo("\(url.lastPathComponent) is empty.")
        case .encrypted:
            throw StudioError.failed(
                "\(url.lastPathComponent) is password protected. Open it in Word, remove the password, then try again."
            )
        case .compound:
            return try readFile(url, type: .docFormat)
        case .rtf:
            return try readFile(url, type: .rtf)
        case .html:
            let data = try Data(contentsOf: url)
            return try await MainActor.run {
                try read(data: data, type: .html, name: url.lastPathComponent, base: url)
            }
        case .zip where ext == "odt":
            return try readFile(url, type: .openDocument)
        case .zip:
            let sections = try DOCXReader.read(url)
            let text = NSMutableAttributedString()
            for section in sections { text.append(section.text) }
            return LoadedDocument(
                text: text, paperSize: sections.first?.setup.paper,
                margins: sections.first?.setup.margins, sections: sections)
        case .unknown where ext == "wordml" || ext == "doc":
            return try readFile(url, type: documentType(for: ext))
        case .unknown:
            throw StudioError.unreadable(url.lastPathComponent)
        }
    }

    static func appName(_ ext: String) -> String {
        switch ext {
        case "pages": "Pages"
        case "key": "Keynote"
        default: "Numbers"
        }
    }

    static func documentType(for ext: String) -> NSAttributedString.DocumentType? {
        switch ext {
        case "docx": .officeOpenXML
        case "doc": .docFormat
        case "rtf": .rtf
        case "rtfd": .rtfd
        case "odt": .openDocument
        case "wordml": .wordML
        default: nil
        }
    }

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            return String(decoding: data.dropFirst(3), as: UTF8.self)
        }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) { return text }
        }
        let zeros = data.prefix(4096).filter { $0 == 0 }.count
        if zeros * 5 > min(data.count, 4096), data.count >= 2 {
            let littleEndian = data.first != 0
            if let text = String(
                data: data, encoding: littleEndian ? .utf16LittleEndian : .utf16BigEndian)
            {
                return text
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1252) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    static func plain(_ text: String) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        return NSAttributedString(
            string: text,
            attributes: [
                .font: NSFont(name: "Menlo", size: 10)
                    ?? NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                .foregroundColor: NSColor.black, .paragraphStyle: paragraph,
            ])
    }

    static func readFile(_ url: URL, type: NSAttributedString.DocumentType?) throws
        -> LoadedDocument
    {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]
        if let type { options[.documentType] = type }
        var attributes: NSDictionary?
        let text: NSAttributedString
        do {
            text = try NSAttributedString(
                url: url, options: options, documentAttributes: &attributes)
        } catch {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        return LoadedDocument(
            text: text, paperSize: paperSize(attributes), margins: margins(attributes))
    }

    @MainActor
    static func read(
        data: Data, type: NSAttributedString.DocumentType, name: String, base: URL?
    ) throws -> LoadedDocument {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: type, .characterEncoding: String.Encoding.utf8.rawValue,
        ]
        if let base { options[.baseURL] = base }
        var attributes: NSDictionary?
        do {
            let text = try NSAttributedString(
                data: data, options: options, documentAttributes: &attributes)
            return LoadedDocument(text: text, paperSize: nil, margins: nil)
        } catch {
            throw StudioError.unreadable(name)
        }
    }

    static func paperSize(_ attributes: NSDictionary?) -> CGSize? {
        guard let value = attributes?[NSAttributedString.DocumentAttributeKey.paperSize] as? NSValue
        else { return nil }
        let size = value.sizeValue
        return size.width > 100 && size.height > 100 ? size : nil
    }

    static func margins(_ attributes: NSDictionary?) -> NSEdgeInsets? {
        guard let attributes else { return nil }
        func value(_ key: NSAttributedString.DocumentAttributeKey) -> CGFloat? {
            (attributes[key] as? NSNumber).map { CGFloat($0.doubleValue) }
        }
        guard let left = value(.leftMargin), let right = value(.rightMargin),
            let top = value(.topMargin), let bottom = value(.bottomMargin)
        else { return nil }
        return NSEdgeInsets(top: top, left: left, bottom: bottom, right: right)
    }
}

public enum MarkdownStyler {
    static let bodySize: CGFloat = 11

    struct TableCell {
        let table: Int
        let row: Int
        let column: Int
        let columns: [PresentationIntent.TableColumn]
    }

    public static func attributed(_ markdown: String, base: URL? = nil) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return DocumentLoader.plain(markdown)
        }
        let result = NSMutableAttributedString()
        var currentBlock: Int?
        var blockPrefixDone = false
        var tables: [Int: NSTextTable] = [:]
        var lastCell: TableCell?
        func cellAttributes(_ cell: TableCell) -> [NSAttributedString.Key: Any] {
            let table =
                tables[cell.table]
                ?? {
                    let table = NSTextTable()
                    table.numberOfColumns = max(1, cell.columns.count)
                    table.collapsesBorders = true
                    tables[cell.table] = table
                    return table
                }()
            let block = NSTextTableBlock(
                table: table, startingRow: cell.row, rowSpan: 1, startingColumn: cell.column,
                columnSpan: 1)
            block.setValue(
                100 / CGFloat(max(1, cell.columns.count)), type: .percentageValueType, for: .width)
            block.setWidth(0.5, type: .absoluteValueType, for: .border)
            block.setBorderColor(NSColor(white: 0.6, alpha: 1))
            block.setWidth(4, type: .absoluteValueType, for: .padding)
            if cell.row == 0 { block.backgroundColor = NSColor(white: 0.93, alpha: 1) }
            let paragraph = NSMutableParagraphStyle()
            paragraph.textBlocks = [block]
            if cell.column < cell.columns.count {
                switch cell.columns[cell.column].alignment {
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                default: paragraph.alignment = .left
                }
            }
            let font =
                cell.row == 0
                ? NSFont.boldSystemFont(ofSize: bodySize) : NSFont.systemFont(ofSize: bodySize)
            return [
                .font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.black,
                DocumentMarkdown.headingKey: 0,
            ]
        }
        func fill(
            _ table: Int, row: Int, from start: Int, to end: Int,
            columns: [PresentationIntent.TableColumn]
        ) {
            guard start < end else { return }
            for column in start..<end {
                result.append(
                    NSAttributedString(
                        string: "\n",
                        attributes: cellAttributes(
                            TableCell(table: table, row: row, column: column, columns: columns))))
            }
        }
        func finishRow() {
            guard let last = lastCell else { return }
            fill(
                last.table, row: last.row, from: last.column + 1, to: last.columns.count,
                columns: last.columns)
        }
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity
            let cell = tableCell(intent)
            if identity != currentBlock {
                if currentBlock != nil {
                    result.append(
                        NSAttributedString(
                            string: "\n",
                            attributes: lastCell.map(cellAttributes) ?? [:]))
                }
                if let last = lastCell,
                    cell == nil || cell?.table != last.table || cell?.row != last.row
                {
                    finishRow()
                    lastCell = nil
                }
                if let cell {
                    let start =
                        lastCell.map {
                            $0.table == cell.table && $0.row == cell.row ? $0.column + 1 : 0
                        }
                        ?? 0
                    fill(
                        cell.table, row: cell.row, from: start, to: cell.column,
                        columns: cell.columns)
                    lastCell = cell
                }
                currentBlock = identity
                blockPrefixDone = false
            }
            if let cell {
                var attributes = cellAttributes(cell)
                let inline = run.inlinePresentationIntent
                if var font = attributes[.font] as? NSFont {
                    if inline?.contains(.stronglyEmphasized) == true {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                    }
                    if inline?.contains(.emphasized) == true {
                        font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                    }
                    if inline?.contains(.code) == true {
                        font = NSFont.monospacedSystemFont(ofSize: bodySize - 1, weight: .regular)
                    }
                    attributes[.font] = font
                }
                if let link = run.link { attributes[.link] = link }
                result.append(NSAttributedString(string: text, attributes: attributes))
                continue
            }
            let block = BlockStyle(intent)
            if block.code, text.hasSuffix("\n") { text.removeLast() }
            if !blockPrefixDone {
                if let prefix = block.prefix {
                    result.append(
                        NSAttributedString(
                            string: prefix, attributes: block.attributes(inline: nil)))
                }
                blockPrefixDone = true
            }
            var attributes = block.attributes(inline: run.inlinePresentationIntent)
            if let link = run.link { attributes[.link] = link }
            if let image = run.imageURL, let attachment = localImage(image, base: base) {
                let picture = NSMutableAttributedString(attachment: attachment)
                picture.addAttributes(
                    attributes, range: NSRange(location: 0, length: picture.length))
                result.append(picture)
                continue
            }
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        if lastCell != nil {
            result.append(
                NSAttributedString(string: "\n", attributes: lastCell.map(cellAttributes) ?? [:]))
            finishRow()
        }
        return result
    }

    static func tableCell(_ intent: PresentationIntent?) -> TableCell? {
        guard let components = intent?.components else { return nil }
        var column: Int?
        var row: Int?
        var table: (Int, [PresentationIntent.TableColumn])?
        for component in components {
            switch component.kind {
            case let .tableCell(index): column = index
            case .tableHeaderRow: row = 0
            case let .tableRow(index): row = index
            case let .table(columns): table = (component.identity, columns)
            default: continue
            }
        }
        guard let column, let row, let table else { return nil }
        return TableCell(table: table.0, row: row, column: column, columns: table.1)
    }

    static func localImage(_ reference: URL, base: URL?) -> NSTextAttachment? {
        let file: URL
        if reference.isFileURL {
            file = reference
        } else if reference.scheme == nil, let base {
            file = URL(
                fileURLWithPath: reference.relativeString,
                relativeTo: base.deletingLastPathComponent())
        } else {
            return nil
        }
        guard let image = NSImage(contentsOf: file.standardizedFileURL), image.size.width > 0 else {
            return nil
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        attachment.bounds = CGRect(origin: .zero, size: image.size)
        return attachment
    }

    struct BlockStyle {
        var heading: Int?
        var code = false
        var quote = false
        var listDepth = 0
        var ordinal: Int?
        var unordered = false

        init(_ intent: PresentationIntent?) {
            var foundList = false
            for component in intent?.components ?? [] {
                switch component.kind {
                case let .header(level): heading = level
                case .codeBlock: code = true
                case .blockQuote: quote = true
                case let .listItem(ordinal):
                    if self.ordinal == nil { self.ordinal = ordinal }
                case .unorderedList:
                    listDepth += 1
                    if !foundList {
                        unordered = true
                        foundList = true
                    }
                case .orderedList:
                    listDepth += 1
                    foundList = true
                default: break
                }
            }
        }

        var prefix: String? {
            guard listDepth > 0 else { return nil }
            if unordered { return "•\t" }
            return "\(ordinal ?? 1).\t"
        }

        func attributes(inline: InlinePresentationIntent?) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.paragraphSpacing = 6
            paragraph.lineSpacing = 1.5
            var size = MarkdownStyler.bodySize
            var weight: NSFont.Weight = .regular
            if let heading {
                size = [0, 24, 19, 16, 14, 12, 11][min(heading, 6)]
                weight = .bold
                paragraph.paragraphSpacingBefore = heading <= 2 ? 12 : 8
                paragraph.paragraphSpacing = 4
            }
            if listDepth > 0 {
                paragraph.textLists = (0..<listDepth).map { level in
                    NSTextList(
                        markerFormat: level == listDepth - 1 && !unordered ? .decimal : .disc,
                        options: 0)
                }
                let indent = CGFloat(listDepth) * 18
                paragraph.headIndent = indent
                paragraph.firstLineHeadIndent = indent - 14
                paragraph.tabStops = [NSTextTab(textAlignment: .left, location: indent)]
                paragraph.paragraphSpacing = 2
            }
            if quote {
                paragraph.headIndent = 18
                paragraph.firstLineHeadIndent = 18
            }
            var font: NSFont
            if code || inline?.contains(.code) == true {
                font = NSFont.monospacedSystemFont(ofSize: size - 1, weight: weight)
            } else {
                font = NSFont.systemFont(ofSize: size, weight: weight)
            }
            if inline?.contains(.stronglyEmphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            }
            if inline?.contains(.emphasized) == true {
                font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            }
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .paragraphStyle: paragraph,
                .foregroundColor: quote ? NSColor(white: 0.35, alpha: 1) : NSColor.black,
                DocumentMarkdown.headingKey: heading ?? 0,
            ]
            if inline?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if code {
                attributes[.backgroundColor] = NSColor(white: 0.94, alpha: 1)
            }
            return attributes
        }
    }
}
