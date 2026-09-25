import AppKit
import CoreGraphics
import Foundation

public enum SpreadsheetRenderer {
    struct Layout {
        let widths: [CGFloat]
        let fontSize: CGFloat
    }

    static let padding: CGFloat = 4
    static let maxColumnWidth: CGFloat = 220
    static let minColumnWidth: CGFloat = 28

    public static func render(
        _ sheets: [SpreadsheetSheet], settings: StudioSettings, title: String, to url: URL,
        headerRow: Bool = true, progress: (Double) -> Void = { _ in }
    ) throws -> Int {
        let usable = sheets.filter { $0.rows.contains { $0.contains { !$0.isEmpty } } }
        guard !usable.isEmpty else {
            throw StudioError.nothingToDo("The spreadsheet has no cells to print.")
        }
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        var pages = 0
        for (index, sheet) in usable.enumerated() {
            try Task.checkCancellation()
            let natural = naturalWidths(sheet, fontSize: 9)
            let naturalTotal = natural.reduce(0, +)
            let portrait = DocumentPageSetup.resolve(
                settings, documentPaper: nil, documentMargins: nil, prefersLandscape: false)
            let prefersLandscape = naturalTotal > portrait.content.width
            let setup = DocumentPageSetup.resolve(
                settings,
                documentPaper: nil,
                documentMargins: NSEdgeInsets(top: 42, left: 36, bottom: 42, right: 36),
                prefersLandscape: prefersLandscape)
            let layout = fit(natural, into: setup.content.width)
            pages += try draw(
                sheet, layout: layout, setup: setup, headerRow: headerRow,
                showTitle: usable.count > 1, context: context)
            progress(Double(index + 1) / Double(usable.count))
        }
        context.closePDF()
        return pages
    }

    static func font(_ size: CGFloat, bold: Bool = false) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: bold ? .semibold : .regular)
    }

    static func naturalWidths(_ sheet: SpreadsheetSheet, fontSize: CGFloat) -> [CGFloat] {
        let columns = sheet.columnCount
        var widths = Array(repeating: minColumnWidth, count: columns)
        let regular = font(fontSize)
        let bold = font(fontSize, bold: true)
        for (rowIndex, row) in sheet.rows.prefix(400).enumerated() {
            for (column, value) in row.enumerated() where !value.isEmpty {
                let measured = (value as NSString).size(
                    withAttributes: [.font: rowIndex == 0 ? bold : regular]
                ).width
                widths[column] = min(maxColumnWidth, max(widths[column], measured + padding * 2))
            }
        }
        return widths
    }

    static func fit(_ widths: [CGFloat], into available: CGFloat) -> Layout {
        let total = widths.reduce(0, +)
        guard total > available, total > 0 else { return Layout(widths: widths, fontSize: 9) }
        let scale = available / total
        let fontSize = max(6, 9 * min(1, scale * 1.15))
        return Layout(widths: widths.map { $0 * scale }, fontSize: fontSize)
    }

    static func height(
        of row: [String], widths: [CGFloat], font: NSFont
    ) -> CGFloat {
        var tallest = font.ascender - font.descender + font.leading
        for (column, value) in row.enumerated() where column < widths.count && !value.isEmpty {
            let bounds = (value as NSString).boundingRect(
                with: CGSize(width: max(4, widths[column] - padding * 2), height: 400),
                options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font])
            tallest = max(tallest, min(bounds.height, 120))
        }
        return ceil(tallest + padding * 2)
    }

    static func draw(
        _ sheet: SpreadsheetSheet, layout: Layout, setup: DocumentPageSetup, headerRow: Bool,
        showTitle: Bool, context: CGContext
    ) throws -> Int {
        var box = CGRect(origin: .zero, size: setup.paper)
        let regular = font(layout.fontSize)
        let bold = font(layout.fontSize, bold: true)
        let header = headerRow ? sheet.rows.first : nil
        let body = headerRow ? Array(sheet.rows.dropFirst()) : sheet.rows
        var pages = 0
        var cursor = 0
        let top = setup.margins.top
        let bottom = setup.paper.height - setup.margins.bottom
        repeat {
            try Task.checkCancellation()
            context.beginPage(mediaBox: &box)
            pages += 1
            context.saveGState()
            context.translateBy(x: 0, y: setup.paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            var y = top
            if showTitle {
                let title = NSAttributedString(
                    string: sheet.name,
                    attributes: [.font: font(12, bold: true), .foregroundColor: NSColor.black])
                title.draw(at: CGPoint(x: setup.margins.left, y: y))
                y += 20
            }
            if let header {
                let height = self.height(of: header, widths: layout.widths, font: bold)
                drawRow(
                    header, y: y, height: height, layout: layout, font: bold,
                    fill: NSColor(white: 0.92, alpha: 1), left: setup.margins.left)
                y += height
            }
            var drewRow = false
            while cursor < body.count {
                let row = body[cursor]
                let height = self.height(of: row, widths: layout.widths, font: regular)
                if y + height > bottom, drewRow { break }
                drawRow(
                    row, y: y, height: height, layout: layout, font: regular, fill: nil,
                    left: setup.margins.left)
                y += height
                cursor += 1
                drewRow = true
            }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()
        } while cursor < body.count && pages < 5000
        return pages
    }

    static func drawRow(
        _ row: [String], y: CGFloat, height: CGFloat, layout: Layout, font: NSFont,
        fill: NSColor?, left: CGFloat
    ) {
        var x = left
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        for (column, width) in layout.widths.enumerated() {
            let cell = CGRect(x: x, y: y, width: width, height: height)
            if let fill {
                fill.setFill()
                cell.fill()
            }
            NSColor(white: 0.72, alpha: 1).setStroke()
            let border = NSBezierPath(rect: cell)
            border.lineWidth = 0.4
            border.stroke()
            if column < row.count, !row[column].isEmpty {
                let value = row[column]
                let numeric = Double(value.replacingOccurrences(of: ",", with: "")) != nil
                let style = paragraph.mutableCopy() as? NSMutableParagraphStyle ?? paragraph
                style.alignment = numeric ? .right : .left
                let text = NSAttributedString(
                    string: value,
                    attributes: [
                        .font: font, .foregroundColor: NSColor.black, .paragraphStyle: style,
                    ])
                text.draw(
                    with: cell.insetBy(dx: padding, dy: padding),
                    options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine])
            }
            x += width
        }
    }
}
