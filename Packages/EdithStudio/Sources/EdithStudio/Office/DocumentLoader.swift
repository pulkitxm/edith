import AppKit
import Foundation

public struct LoadedDocument {
    public let text: NSAttributedString
    public let paperSize: CGSize?
    public let margins: NSEdgeInsets?
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
                text: MarkdownStyler.attributed(raw), paperSize: nil, margins: nil)
        case "txt", "text":
            let raw = try readText(url)
            return LoadedDocument(text: plain(raw), paperSize: nil, margins: nil)
        case "html", "htm":
            let data = try Data(contentsOf: url)
            return try await MainActor.run {
                try read(data: data, type: .html, name: url.lastPathComponent, base: url)
            }
        case "docx":
            let loaded = try readFile(url, type: .officeOpenXML)
            return LoadedDocument(
                text: DOCXDefaults.apply(to: loaded.text, from: url), paperSize: loaded.paperSize,
                margins: loaded.margins)
        default:
            let type = documentType(for: ext)
            return try readFile(url, type: type)
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
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf16) { return text }
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

enum DOCXDefaults {
    static let substitutes = [
        "calibri": "Helvetica Neue", "calibri light": "Helvetica Neue", "aptos": "Helvetica Neue",
        "arial": "Arial", "cambria": "Georgia", "segoe ui": "Helvetica Neue",
    ]

    static func apply(to text: NSAttributedString, from url: URL) -> NSAttributedString {
        guard let parts = try? OOXMLPackage.read(url),
            let styles = parts["word/styles.xml"].flatMap(XMLTree.parse),
            let defaults = styles.child("docDefaults")
        else { return text }
        let document = parts["word/document.xml"].map { String(decoding: $0, as: UTF8.self) } ?? ""
        let fonts = defaults.path("rPrDefault", "rPr", "rFonts")
        let family = fonts?.attribute("ascii") ?? fonts?.attribute("hAnsi")
        let spacing = defaults.path("pPrDefault", "pPr", "spacing")
        let after = spacing?.number("after").map { CGFloat($0) / 20 }
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        if let family, !family.lowercased().contains("times"), !document.contains("Times") {
            let replacement = replacementFamily(family)
            copy.enumerateAttribute(.font, in: whole) { value, range, _ in
                guard let font = value as? NSFont,
                    font.familyName?.lowercased().contains("times") == true
                else { return }
                var converted =
                    NSFontManager.shared.font(
                        withFamily: replacement, traits: [], weight: 5, size: font.pointSize)
                    ?? NSFont.systemFont(ofSize: font.pointSize)
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.bold) {
                    converted = NSFontManager.shared.convert(converted, toHaveTrait: .boldFontMask)
                }
                if traits.contains(.italic) {
                    converted = NSFontManager.shared.convert(
                        converted, toHaveTrait: .italicFontMask)
                }
                copy.addAttribute(.font, value: converted, range: range)
            }
        }
        if let after, after > 0 {
            copy.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                let style =
                    (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                guard style.paragraphSpacing == 0, style.textBlocks.isEmpty else { return }
                style.paragraphSpacing = after
                copy.addAttribute(.paragraphStyle, value: style, range: range)
            }
        }
        return copy
    }

    static func replacementFamily(_ family: String) -> String {
        if NSFontManager.shared.availableFontFamilies.contains(family) { return family }
        return substitutes[family.lowercased()] ?? "Helvetica Neue"
    }
}

public enum MarkdownStyler {
    static let bodySize: CGFloat = 11

    public static func attributed(_ markdown: String) -> NSAttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: true, interpretedSyntax: .full,
            failurePolicy: .returnPartiallyParsedIfPossible)
        guard let parsed = try? AttributedString(markdown: markdown, options: options) else {
            return DocumentLoader.plain(markdown)
        }
        let result = NSMutableAttributedString()
        var currentBlock: Int?
        var blockPrefixDone = false
        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let intent = run.presentationIntent
            let identity = intent?.components.first?.identity
            if identity != currentBlock {
                if currentBlock != nil { result.append(NSAttributedString(string: "\n")) }
                currentBlock = identity
                blockPrefixDone = false
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
            result.append(NSAttributedString(string: text, attributes: attributes))
        }
        return result
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
