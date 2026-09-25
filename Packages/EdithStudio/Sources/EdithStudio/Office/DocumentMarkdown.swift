import AppKit
import Foundation

public enum DocumentMarkdown {
    public struct Block: Equatable {
        public var text: String
        public var markdown: String
        public var heading: Int?
        public var listLevel: Int
        public var ordered: Bool
    }

    public static func blocks(_ text: NSAttributedString) -> [Block] {
        let body = bodySize(text)
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
        string.enumerateSubstrings(
            in: NSRange(location: 0, length: string.length), options: .byParagraphs
        ) { _, range, _, _ in
            guard range.length > 0 else {
                flushTable()
                return
            }
            let style =
                text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil)
                as? NSParagraphStyle
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                let identity = ObjectIdentifier(cell.table)
                if tableIdentity != identity { flushTable() }
                tableIdentity = identity
                let plain = string.substring(with: range).trimmingCharacters(
                    in: .whitespacesAndNewlines)
                table[cell.startingRow, default: [:]][cell.startingColumn] = plain
                return
            }
            flushTable()
            let paragraph = text.attributedSubstring(from: range)
            var plain = paragraph.string
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
                if let match = plain.range(of: #"^\t?[^\t]{0,12}\t"#, options: .regularExpression) {
                    markerLength = plain.distance(from: plain.startIndex, to: match.upperBound)
                    plain.removeSubrange(match)
                }
            }
            let trimmed = plain.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let inline = inlineMarkdown(
                paragraph.attributedSubstring(
                    from: NSRange(location: markerLength, length: paragraph.length - markerLength)))
            let heading = lists.isEmpty ? headingLevel(paragraph, body: body, text: trimmed) : nil
            blocks.append(
                Block(
                    text: trimmed, markdown: inline, heading: heading, listLevel: lists.count,
                    ordered: ordered))
        }
        flushTable()
        return blocks
    }

    public static func markdown(_ text: NSAttributedString) -> String {
        render(blocks(text))
    }

    public static func render(_ blocks: [Block]) -> String {
        var output = ""
        var previousList = false
        var counters: [Int: Int] = [:]
        for block in blocks {
            let isList = block.listLevel > 0
            let line: String
            if let heading = block.heading {
                line = String(repeating: "#", count: heading) + " " + block.text
            } else if isList {
                let indent = String(repeating: "  ", count: max(0, block.listLevel - 1))
                if block.ordered {
                    let number = (counters[block.listLevel] ?? 0) + 1
                    counters[block.listLevel] = number
                    line = indent + "\(number). " + block.markdown
                } else {
                    line = indent + "- " + block.markdown
                }
            } else {
                line = block.markdown
            }
            if !output.isEmpty { output += isList && previousList ? "\n" : "\n\n" }
            output += line
            if !isList { counters = [:] }
            previousList = isList
        }
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
            var segment = (text.string as NSString).substring(with: range)
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
