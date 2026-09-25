import AppKit
import CoreText
import Foundation
import PDFKit

enum LayoutTranslation {
    struct Block {
        let page: Int
        let lines: [PDFTextAnalysis.Line]
        var isCell = false

        var translatable: Bool {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            guard trimmed.contains(where: \.isLetter) else { return false }
            return !(trimmed.count <= 4 && !trimmed.contains(where: \.isLowercase))
        }

        var text: String {
            var result = ""
            for line in lines {
                let trimmed = line.text.trimmingCharacters(in: .whitespaces)
                if result.hasSuffix("-"), let first = trimmed.first, first.isLowercase {
                    result.removeLast()
                    result += trimmed
                } else {
                    result += result.isEmpty ? trimmed : " " + trimmed
                }
            }
            return result
        }

        var rect: CGRect { lines.dropFirst().reduce(lines[0].rect) { $0.union($1.rect) } }
        var size: CGFloat { lines.map(\.size).max() ?? 12 }
        var bold: Bool { lines.filter(\.bold).count * 2 > lines.count }
    }

    static func blocks(of document: PDFDocument) -> [Block] {
        var result: [Block] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var current: [PDFTextAnalysis.Line] = []
            for line in PDFTextAnalysis.lines(of: page)
            where !line.text.trimmingCharacters(in: .whitespaces).isEmpty {
                if line.cells.count > 1 {
                    if !current.isEmpty { result.append(Block(page: index, lines: current)) }
                    current = []
                    for cell in split(line) {
                        result.append(Block(page: index, lines: [cell], isCell: true))
                    }
                    continue
                }
                if let previous = current.last {
                    let gap = previous.rect.minY - line.rect.maxY
                    let bullet = PDFTextAnalysis.bulletPrefixes.contains {
                        line.text.trimmingCharacters(in: .whitespaces).hasPrefix($0)
                    }
                    let joins =
                        !bullet && abs(previous.size - line.size) < 0.6
                        && gap < max(previous.rect.height, line.rect.height) * 0.9
                        && abs(previous.rect.minX - line.rect.minX) < max(line.size, 8) * 3
                        && line.cells.count == 1 && previous.cells.count == 1
                    if !joins {
                        result.append(Block(page: index, lines: current))
                        current = []
                    }
                }
                current.append(line)
            }
            if !current.isEmpty { result.append(Block(page: index, lines: current)) }
        }
        return result
    }

    static func split(_ line: PDFTextAnalysis.Line) -> [PDFTextAnalysis.Line] {
        guard line.cells.count > 1 else { return [line] }
        return line.cells.map { cell in
            PDFTextAnalysis.Line(
                text: cell.text,
                rect: CGRect(
                    x: cell.minX, y: line.rect.minY, width: max(cell.maxX - cell.minX, 1),
                    height: line.rect.height),
                size: line.size, bold: line.bold, italic: line.italic, cells: [cell])
        }
    }

    static func write(
        _ document: PDFDocument, blocks: [Block], translations: [String], to url: URL,
        progress: @escaping (Double) -> Void
    ) throws {
        var byPage: [Int: [(Block, String)]] = [:]
        for (block, text) in zip(blocks, translations) {
            byPage[block.page, default: []].append((block, text))
        }
        try StudioPDF.rebuild(
            document, to: url, pages: Set(byPage.keys),
            over: { canvas in
                for (block, text) in byPage[canvas.index] ?? [] where text != block.text {
                    draw(text, over: block, in: canvas.context, page: canvas.size)
                }
            }, progress: progress)
    }

    static func draw(_ text: String, over block: Block, in context: CGContext, page: CGSize) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        for line in block.lines {
            context.fill(line.rect.insetBy(dx: -1.5, dy: -1.5))
        }
        let rect = block.rect.insetBy(dx: -1, dy: -1)
        let original = block.size
        let available = block.isCell ? rect.width : max(rect.width, page.width - rect.minX - 36)
        let frame = CGRect(
            x: rect.minX, y: rect.minY - original * 0.35,
            width: max(available, original * 3), height: rect.height + original * 0.5)
        var size = original
        var font = StudioStamp.font(named: "Helvetica", size: size, bold: block.bold)
        while size > max(5, original * 0.55) {
            font = StudioStamp.font(named: "Helvetica", size: size, bold: block.bold)
            let needed = StudioText.fittingSize(text, font: font, width: frame.width)
            if needed.height <= frame.height { break }
            size -= 0.5
        }
        StudioText.draw(
            text, in: frame, context: context, font: font, color: .black, alignment: .left)
        context.restoreGState()
    }
}
