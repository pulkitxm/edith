import AppKit
import CoreGraphics
import Foundation
import PDFKit

public enum PDFRedaction {
    public enum Pattern: String, CaseIterable, Sendable {
        case email, phone, card, url, date

        var expression: String {
            switch self {
            case .email: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#
            case .phone:
                #"(?<!\d)(?:\+?\d{1,3}[\s.-]?)?(?:\(\d{2,4}\)[\s.-]?)?\d{3,4}[\s.-]?\d{3,4}(?:[\s.-]?\d{2,4})?(?!\d)"#
            case .card: #"(?<!\d)(?:\d[ -]?){12,18}\d(?!\d)"#
            case .url: #"(?:https?://|www\.)[^\s<>\"]+"#
            case .date:
                #"\b(?:\d{1,2}[/.-]\d{1,2}[/.-]\d{2,4}|\d{4}-\d{2}-\d{2}|(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.? \d{1,2},? \d{4})\b"#
            }
        }
    }

    public static func terms(from raw: String) -> [String] {
        raw.split(whereSeparator: { $0 == "\n" || $0 == "," })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    public static func find(
        terms: [String], patterns: [Pattern], in document: PDFDocument
    ) -> [Int: [CGRect]] {
        var marks: [Int: [CGRect]] = [:]
        func add(_ selection: PDFSelection) {
            for line in selection.selectionsByLine() {
                for page in line.pages {
                    let index = document.index(for: page)
                    guard index != NSNotFound else { continue }
                    let rect = line.bounds(for: page).insetBy(dx: -1.5, dy: -1.5)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    marks[index, default: []].append(rect)
                }
            }
        }
        for term in terms {
            for selection in document.findString(term, withOptions: [.caseInsensitive]) {
                add(selection)
            }
        }
        let expressions = patterns.compactMap {
            try? NSRegularExpression(pattern: $0.expression, options: [.caseInsensitive])
        }
        guard !expressions.isEmpty else { return marks }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string else { continue }
            let range = NSRange(text.startIndex..., in: text)
            for expression in expressions {
                for match in expression.matches(in: text, range: range) {
                    if let selection = page.selection(for: match.range) { add(selection) }
                }
            }
        }
        return marks
    }

    public static func apply(
        _ marks: [Int: [CGRect]], to document: PDFDocument, fill: StudioColor, searchable: Bool,
        scrubMetadata: Bool, output: URL, dpi: Double = 200, progress: (Double) -> Void = { _ in }
    ) async throws {
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            guard let rects = marks[index], !rects.isEmpty else {
                if let copy = page.copy() as? PDFPage {
                    for annotation in copy.annotations where annotation.type == "Redact" {
                        copy.removeAnnotation(annotation)
                    }
                    result.insert(copy, at: result.pageCount)
                }
                continue
            }
            let flattened = try await burn(
                page, rects: rects, fill: fill, dpi: dpi, searchable: searchable)
            result.insert(flattened, at: result.pageCount)
            progress(Double(index + 1) / Double(document.pageCount))
        }
        for (index, rects) in marks where !rects.isEmpty {
            guard let page = document.page(at: index), let target = result.page(at: index)
            else { continue }
            let crop = StudioPDF.cropBox(page)
            for annotation in page.annotations where annotation.type == "Link" {
                guard !rects.contains(where: { $0.intersects(annotation.bounds) }),
                    let link = StudioPDF.relink(
                        annotation,
                        bounds: annotation.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY),
                        original: document, rebuilt: result)
                else { continue }
                target.addAnnotation(link)
            }
        }
        if scrubMetadata {
            result.documentAttributes = [:]
        } else {
            result.documentAttributes = document.documentAttributes
        }
        try StudioPDF.write(result, to: output)
    }

    static func burn(
        _ page: PDFPage, rects: [CGRect], fill: StudioColor, dpi: Double, searchable: Bool
    ) async throws -> PDFPage {
        let rotation = StudioPDF.rotation(page)
        let crop = StudioPDF.cropBox(page)
        let displayed = try StudioPDF.render(page, dpi: dpi)
        guard let upright = StudioImageOps.rotated(displayed, quarterTurns: -rotation / 90),
            let context = StudioImageOps.context(
                width: upright.width, height: upright.height, opaque: true)
        else { throw StudioError.failed("Not enough memory to redact the page.") }
        let scaleX = Double(upright.width) / crop.width
        let scaleY = Double(upright.height) / crop.height
        context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        context.setFillColor(fill.cgColor)
        for rect in rects {
            let local = rect.standardized.offsetBy(dx: -crop.minX, dy: -crop.minY)
            context.fill(
                CGRect(
                    x: local.minX * scaleX, y: local.minY * scaleY,
                    width: local.width * scaleX, height: local.height * scaleY
                ).integral)
        }
        guard let burned = context.makeImage() else {
            throw StudioError.failed("The redacted page could not be drawn.")
        }
        let lines: [StudioPDF.TextLine] =
            searchable
            ? (try await StudioVision.recognizeText(in: burned, accurate: true)).map { line in
                StudioPDF.TextLine(
                    text: line.text,
                    rect: CGRect(
                        x: line.box.minX * crop.width, y: line.box.minY * crop.height,
                        width: line.box.width * crop.width, height: line.box.height * crop.height))
            } : []
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw StudioError.failed("The redacted page could not be written.")
        }
        var box = CGRect(origin: .zero, size: crop.size)
        guard let pdf = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw StudioError.failed("The redacted page could not be written.")
        }
        pdf.beginPage(mediaBox: &box)
        pdf.interpolationQuality = .high
        pdf.draw(try StudioPDF.jpegImage(burned, quality: 0.85), in: box)
        StudioPDF.drawInvisibleText(lines, in: pdf)
        pdf.endPage()
        pdf.closePDF()
        guard let redacted = PDFDocument(data: data as Data)?.page(at: 0) else {
            throw StudioError.failed("The redacted page could not be read back.")
        }
        redacted.rotation = rotation
        return redacted
    }
}
