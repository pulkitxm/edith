import AppKit
import Foundation

public enum DocumentMarkdown {
    public static let headingKey = NSAttributedString.Key("EdithStudioHeading")

    public struct Block: Equatable {
        public var text: String
        public var markdown: String
        public var heading: Int?
        public var listLevel: Int
        public var ordered: Bool
        public var code = false
    }

    struct Paragraph {
        let range: NSRange
        let style: NSParagraphStyle?
        let cell: NSTextTableBlock?
    }

    static func paragraphs(_ text: NSAttributedString) -> [Paragraph] {
        let string = text.string as NSString
        var result: [Paragraph] = []
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: .byParagraphs
        ) { _, range, _, _ in
            let style =
                range.length > 0 || range.location < text.length
                ? text.attribute(
                    .paragraphStyle, at: min(range.location, max(0, text.length - 1)),
                    effectiveRange: nil) as? NSParagraphStyle
                : nil
            let cell = style?.textBlocks.compactMap { $0 as? NSTextTableBlock }.first
            result.append(Paragraph(range: range, style: style, cell: cell))
        }
        return result
    }

    static func cleaned(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\u{0C}", with: "")
    }

    public static func blocks(_ text: NSAttributedString) -> [Block] {
        let body = bodySize(text)
        let explicit = hasExplicitHeadings(text)
        let string = text.string as NSString
        var blocks: [Block] = []
        var table: [Int: [Int: String]] = [:]
        var tableIdentity: ObjectIdentifier?
        func flushTable() {
            guard !table.isEmpty, let last = table.keys.max() else { return }
            let columns = (table.values.compactMap { $0.keys.max() }.max() ?? 0) + 1
            var lines: [String] = []
            for row in 0...last {
                let cells = (0..<columns).map { column in
                    (table[row]?[column] ?? "").replacingOccurrences(of: "|", with: "\\|")
                }
                lines.append("| " + cells.joined(separator: " | ") + " |")
                if row == 0 {
                    lines.append("|" + Array(repeating: " --- |", count: columns).joined())
                }
            }
            let joined = lines.joined(separator: "\n")
            blocks.append(
                Block(text: joined, markdown: joined, heading: nil, listLevel: 0, ordered: false))
            table = [:]
            tableIdentity = nil
        }
        for paragraph in paragraphs(text) {
            let range = paragraph.range
            let style = paragraph.style
            if let cell = paragraph.cell {
                let identity = ObjectIdentifier(cell.table)
                if tableIdentity != identity { flushTable() }
                tableIdentity = identity
                let plain = cleaned(string.substring(with: range))
                    .replacingOccurrences(of: "\u{2028}", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !plain.isEmpty else { continue }
                let existing = table[cell.startingRow]?[cell.startingColumn] ?? ""
                table[cell.startingRow, default: [:]][cell.startingColumn] =
                    existing.isEmpty ? plain : existing + " " + plain
                continue
            }
            guard range.length > 0 else {
                flushTable()
                continue
            }
            flushTable()
            let paragraphText = text.attributedSubstring(from: range)
            var plain = cleaned(paragraphText.string)
            let lists = style?.textLists ?? []
            var ordered = false
            var markerLength = 0
            if let list = lists.last {
                ordered =
                    !(list.markerFormat.rawValue.contains("disc")
                    || list.markerFormat.rawValue.contains("circle")
                    || list.markerFormat.rawValue.contains("square")
                    || list.markerFormat.rawValue.contains("hyphen")
                    || list.markerFormat.rawValue.contains("diamond")
                    || list.markerFormat.rawValue.contains("check"))
                let raw = paragraphText.string
                if let match = raw.range(of: #"^\t?[^\t]{0,12}\t"#, options: .regularExpression) {
                    markerLength = (String(raw[match]) as NSString).length
                    plain = cleaned(String(raw[match.upperBound...]))
                }
            }
            let trimmed = plain.replacingOccurrences(of: "\u{2028}", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if lists.isEmpty, isCode(paragraphText) {
                let code = cleaned(paragraphText.string)
                    .replacingOccurrences(of: "\u{2028}", with: "\n")
                    .trimmingCharacters(in: .newlines)
                blocks.append(
                    Block(
                        text: code, markdown: code, heading: nil, listLevel: 0, ordered: false,
                        code: true))
                continue
            }
            let inline = inlineMarkdown(
                paragraphText.attributedSubstring(
                    from: NSRange(
                        location: markerLength, length: paragraphText.length - markerLength)))
            var heading: Int?
            if lists.isEmpty {
                if explicit {
                    let value =
                        paragraphText.attribute(headingKey, at: 0, effectiveRange: nil) as? Int
                    heading = value.flatMap { $0 > 0 ? $0 : nil }
                } else {
                    heading = headingLevel(paragraphText, body: body, text: trimmed)
                }
            }
            blocks.append(
                Block(
                    text: trimmed, markdown: inline, heading: heading, listLevel: lists.count,
                    ordered: ordered))
        }
        flushTable()
        return blocks
    }

    static func hasExplicitHeadings(_ text: NSAttributedString) -> Bool {
        var found = false
        text.enumerateAttribute(headingKey, in: NSRange(location: 0, length: text.length)) {
            value, _, stop in
            if let level = value as? Int, level > 0 {
                found = true
                stop.pointee = true
            }
        }
        return found
    }

    static func isCode(_ paragraph: NSAttributedString) -> Bool {
        var monospaced = false
        var other = false
        paragraph.enumerateAttribute(.font, in: NSRange(location: 0, length: paragraph.length)) {
            value, range, stop in
            let segment = (paragraph.string as NSString).substring(with: range)
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let font = value as? NSFont,
                font.isFixedPitch
                    || font.fontDescriptor.symbolicTraits.contains(.monoSpace)
            {
                monospaced = true
            } else {
                other = true
                stop.pointee = true
            }
        }
        return monospaced && !other
    }

    public static func markdown(_ text: NSAttributedString) -> String {
        render(blocks(text))
    }

    public static func plain(_ text: NSAttributedString) -> String {
        let string = text.string as NSString
        var lines: [String] = []
        var row: [Int: String] = [:]
        var rowKey: (ObjectIdentifier, Int)?
        func flushRow() {
            guard let last = row.keys.max() else { return }
            lines.append((0...last).map { row[$0] ?? "" }.joined(separator: "\t"))
            row = [:]
            rowKey = nil
        }
        for paragraph in paragraphs(text) {
            let content = cleaned(string.substring(with: paragraph.range))
                .replacingOccurrences(of: "\u{2028}", with: "\n")
            if let cell = paragraph.cell {
                let key = (ObjectIdentifier(cell.table), cell.startingRow)
                if let rowKey, rowKey != key { flushRow() }
                rowKey = key
                let value = content.replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty else { continue }
                let existing = row[cell.startingColumn] ?? ""
                row[cell.startingColumn] = existing.isEmpty ? value : existing + " " + value
                continue
            }
            flushRow()
            lines.append(content)
        }
        flushRow()
        var result = lines.joined(separator: "\n")
        while result.hasSuffix("\n\n") { result.removeLast() }
        return result.hasSuffix("\n") ? result : result + "\n"
    }

    public static func render(_ blocks: [Block]) -> String {
        var output = ""
        var previousList = false
        var counters: [Int: Int] = [:]
        var kinds: [Int: Bool] = [:]
        var widths: [Int: Int] = [:]
        var code: [String] = []
        func emit(_ line: String, list: Bool) {
            if !output.isEmpty { output += list && previousList ? "\n" : "\n\n" }
            output += line
            previousList = list
        }
        func flushCode() {
            guard !code.isEmpty else { return }
            emit("```\n" + code.joined(separator: "\n") + "\n```", list: false)
            code = []
        }
        for block in blocks {
            if block.code {
                code.append(block.text)
                counters = [:]
                kinds = [:]
                continue
            }
            flushCode()
            let isList = block.listLevel > 0
            let line: String
            if let heading = block.heading {
                line = String(repeating: "#", count: min(max(heading, 1), 6)) + " " + block.text
            } else if isList {
                let level = block.listLevel
                for key in counters.keys where key > level { counters[key] = nil }
                for key in kinds.keys where key > level { kinds[key] = nil }
                if kinds[level] != block.ordered { counters[level] = nil }
                kinds[level] = block.ordered
                let indent = String(
                    repeating: " ", count: (1..<max(level, 1)).reduce(0) { $0 + (widths[$1] ?? 2) })
                let marker: String
                if block.ordered {
                    let number = (counters[level] ?? 0) + 1
                    counters[level] = number
                    marker = "\(number). "
                } else {
                    marker = "- "
                }
                widths[level] = marker.count
                line = indent + marker + block.markdown
            } else {
                line = block.markdown
            }
            if !isList {
                counters = [:]
                kinds = [:]
            }
            emit(line, list: isList)
        }
        flushCode()
        return output + "\n"
    }

    static func bodySize(_ text: NSAttributedString) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) {
            value, range, _ in
            guard let font = value as? NSFont else { return }
            weights[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    static func headingLevel(_ paragraph: NSAttributedString, body: CGFloat, text: String) -> Int? {
        guard text.split(separator: " ").count <= 16, !text.hasSuffix("."),
            let font = paragraph.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else { return nil }
        let size = font.pointSize
        if size >= body * 1.6 { return 1 }
        if size >= body * 1.3 { return 2 }
        if size >= body * 1.1 { return 3 }
        let bold = isBold(font)
        if bold, allBold(paragraph), text.split(separator: " ").count <= 10 { return 3 }
        return nil
    }

    static func isBold(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.bold)
            || font.fontName.lowercased().contains("bold")
    }

    static func isItalic(_ font: NSFont) -> Bool {
        font.fontDescriptor.symbolicTraits.contains(.italic)
            || font.fontName.lowercased().contains("italic")
    }

    static func allBold(_ text: NSAttributedString) -> Bool {
        var bold = true
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) {
            value, range, stop in
            let segment = (text.string as NSString).substring(with: range)
            guard !segment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if let font = value as? NSFont, isBold(font) { return }
            bold = false
            stop.pointee = true
        }
        return bold
    }

    static func inlineMarkdown(_ text: NSAttributedString) -> String {
        var output = ""
        let whole = NSRange(location: 0, length: text.length)
        let paragraphBold = allBold(text)
        text.enumerateAttributes(in: whole) { attributes, range, _ in
            var segment = cleaned((text.string as NSString).substring(with: range))
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\u{2028}", with: " ")
            guard !segment.isEmpty else { return }
            let leading = String(segment.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(segment.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            segment = segment.trimmingCharacters(in: .whitespaces)
            guard !segment.isEmpty else {
                output += leading
                return
            }
            if let font = attributes[.font] as? NSFont {
                if isBold(font), !paragraphBold { segment = "**\(segment)**" }
                if isItalic(font) { segment = "*\(segment)*" }
            }
            if let link = attributes[.link] {
                let target = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !target.isEmpty { segment = "[\(segment)](\(target))" }
            }
            output += leading + segment + trailing
        }
        return output.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "****", with: "")
    }
}
