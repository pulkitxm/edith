import AppKit
import CoreGraphics
import Foundation
import PDFKit

public enum PDFTextAnalysis {
    public struct Cell: Equatable {
        public var text: String
        public var minX: CGFloat
        public var maxX: CGFloat
    }

    public struct Line: Equatable {
        public var text: String
        public var rect: CGRect
        public var size: CGFloat
        public var bold: Bool
        public var italic: Bool
        public var cells: [Cell]
    }

    struct Glyph {
        let text: String
        let rect: CGRect
        let size: CGFloat
        let bold: Bool
        let italic: Bool
    }

    public static func lines(of page: PDFPage) -> [Line] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let attributed = page.attributedString
        let nsString = string as NSString
        let toDisplay = StudioPDF.displayFromPage(page)
        var glyphs: [Glyph] = []
        var index = 0
        while index < nsString.length {
            let range = nsString.rangeOfComposedCharacterSequence(at: index)
            defer { index = range.location + range.length }
            let character = nsString.substring(with: range)
            if character.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            guard let selection = page.selection(for: range) else { continue }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0 || bounds.height > 0 else { continue }
            let rect = bounds.applying(toDisplay).standardized
            var size = rect.height
            var bold = false
            var italic = false
            if let attributed, range.location < attributed.length,
                let font = attributed.attribute(.font, at: range.location, effectiveRange: nil)
                    as? NSFont
            {
                size = font.pointSize
                let traits = font.fontDescriptor.symbolicTraits
                let name = font.fontName.lowercased()
                bold = traits.contains(.bold) || name.contains("bold") || name.contains("black")
                italic =
                    traits.contains(.italic) || name.contains("italic") || name.contains("oblique")
            }
            glyphs.append(
                Glyph(text: character, rect: rect, size: size, bold: bold, italic: italic))
        }
        return group(glyphs)
    }

    static func group(_ glyphs: [Glyph]) -> [Line] {
        guard !glyphs.isEmpty else { return [] }
        let sorted = glyphs.sorted { $0.rect.midY > $1.rect.midY }
        var rows: [[Glyph]] = []
        for glyph in sorted {
            if let lastIndex = rows.indices.last,
                let reference = rows[lastIndex].first,
                abs(reference.rect.midY - glyph.rect.midY)
                    <= max(2, min(reference.rect.height, glyph.rect.height) * 0.5)
            {
                rows[lastIndex].append(glyph)
            } else {
                rows.append([glyph])
            }
        }
        return rows.map { row in line(from: row.sorted { $0.rect.minX < $1.rect.minX }) }
    }

    static func line(from row: [Glyph]) -> Line {
        var text = ""
        var cells: [Cell] = []
        var cellText = ""
        var cellMin = row.first?.rect.minX ?? 0
        var cellMax = cellMin
        var previous: Glyph?
        let averageWidth =
            row.map(\.rect.width).reduce(0, +) / CGFloat(max(row.count, 1))
        for glyph in row {
            if let previous {
                let gap = glyph.rect.minX - previous.rect.maxX
                let em = max(previous.size, glyph.size, 1)
                if gap > max(em * 1.1, averageWidth * 2.2) {
                    cells.append(Cell(text: cellText, minX: cellMin, maxX: cellMax))
                    cellText = ""
                    cellMin = glyph.rect.minX
                    text += "  "
                } else if gap > em * 0.18 {
                    cellText += " "
                    text += " "
                }
            }
            cellText += glyph.text
            text += glyph.text
            cellMax = glyph.rect.maxX
            previous = glyph
        }
        cells.append(Cell(text: cellText, minX: cellMin, maxX: cellMax))
        var weights: [CGFloat: Int] = [:]
        for glyph in row { weights[(glyph.size * 2).rounded() / 2, default: 0] += 1 }
        let size = weights.max { $0.value < $1.value }?.key ?? 12
        let boldCount = row.filter(\.bold).count
        let italicCount = row.filter(\.italic).count
        let rect = row.dropFirst().reduce(row[0].rect) { $0.union($1.rect) }
        return Line(
            text: text, rect: rect, size: size, bold: boldCount * 2 > row.count,
            italic: italicCount * 2 > row.count, cells: cells)
    }

    public static func bodySize(_ pages: [[Line]]) -> CGFloat {
        var weights: [CGFloat: Int] = [:]
        for line in pages.joined() { weights[line.size, default: 0] += line.text.count }
        return weights.max { $0.value < $1.value }?.key ?? 12
    }

    public struct Paragraph: Equatable {
        public var text: String
        public var heading: Int?
        public var bullet: Bool
        public var size: CGFloat
        public var bold: Bool
        public var italic: Bool
    }

    static let bulletPrefixes = ["•", "◦", "▪", "‣", "●", "○", "■", "–", "- ", "* "]

    public static func paragraphs(_ lines: [Line], body: CGFloat) -> [Paragraph] {
        var result: [Paragraph] = []
        var previous: Line?
        for line in lines {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let heading = headingLevel(line, body: body)
            let bulletPrefix = bulletPrefixes.first { trimmed.hasPrefix($0) }
            var content = trimmed
            if let bulletPrefix {
                content = String(trimmed.dropFirst(bulletPrefix.count)).trimmingCharacters(
                    in: .whitespaces)
            }
            let continues: Bool = {
                guard let previous, let last = result.last, heading == nil, bulletPrefix == nil,
                    last.heading == nil
                else { return false }
                let gap = previous.rect.minY - line.rect.maxY
                let sameSize = abs(previous.size - line.size) < 0.6
                return sameSize && gap < max(line.rect.height, previous.rect.height) * 0.9
                    && abs(previous.rect.minX - line.rect.minX) < body * 3
            }()
            if continues, var last = result.popLast() {
                if last.text.hasSuffix("-"), let first = content.first, first.isLowercase {
                    last.text.removeLast()
                    last.text += content
                } else {
                    last.text += " " + content
                }
                result.append(last)
            } else {
                result.append(
                    Paragraph(
                        text: content, heading: heading, bullet: bulletPrefix != nil,
                        size: line.size, bold: line.bold, italic: line.italic))
            }
            previous = line
        }
        return result
    }

    static func headingLevel(_ line: Line, body: CGFloat) -> Int? {
        let words = line.text.split(separator: " ").count
        guard words <= 16 else { return nil }
        if line.size >= body * 1.6 { return 1 }
        if line.size >= body * 1.3 { return 2 }
        if line.size >= body * 1.1 || (line.bold && words <= 10 && line.size >= body - 0.5) {
            return 3
        }
        return nil
    }

    public static func markdown(_ document: PDFDocument, progress: (Double) -> Void = { _ in })
        -> String
    {
        var pages: [[Line]] = []
        for index in 0..<document.pageCount {
            pages.append(document.page(at: index).map(lines(of:)) ?? [])
            progress(Double(index + 1) / Double(max(document.pageCount, 1)))
        }
        let body = bodySize(pages)
        var output: [String] = []
        for lines in pages {
            for paragraph in paragraphs(lines, body: body) {
                if let heading = paragraph.heading {
                    output.append(String(repeating: "#", count: heading) + " " + paragraph.text)
                } else if paragraph.bullet {
                    output.append("- " + paragraph.text)
                } else if paragraph.bold {
                    output.append("**" + paragraph.text + "**")
                } else {
                    output.append(paragraph.text)
                }
            }
        }
        var text = ""
        for (index, block) in output.enumerated() {
            let isBullet = block.hasPrefix("- ")
            let previousBullet = index > 0 && output[index - 1].hasPrefix("- ")
            if index > 0 { text += isBullet && previousBullet ? "\n" : "\n\n" }
            text += block
        }
        return text + "\n"
    }

    public static func table(_ lines: [Line], tolerance: CGFloat = 8) -> [[String]] {
        var anchors: [CGFloat] = []
        for cell in lines.flatMap(\.cells) {
            if !anchors.contains(where: { abs($0 - cell.minX) <= tolerance }) {
                anchors.append(cell.minX)
            }
        }
        anchors.sort()
        return lines.map { line in
            var row = Array(repeating: "", count: anchors.count)
            for cell in line.cells {
                let column =
                    anchors.lastIndex(where: { $0 <= cell.minX + tolerance }) ?? 0
                row[column] = row[column].isEmpty ? cell.text : row[column] + " " + cell.text
            }
            while let last = row.last, last.isEmpty { row.removeLast() }
            return row
        }
    }
}
