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

    public static func scrubber(terms: [String], patterns: [Pattern]) -> (String) -> String {
        let expressions =
            terms.map { NSRegularExpression.escapedPattern(for: $0) }
            + patterns.map(\.expression)
        let compiled = expressions.compactMap {
            try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
        }
        return { text in
            compiled.reduce(text) { current, expression in
                expression.stringByReplacingMatches(
                    in: current, range: NSRange(current.startIndex..., in: current),
                    withTemplate: "\u{2588}\u{2588}\u{2588}")
            }
        }
    }

    public static func apply(
        _ marks: [Int: [CGRect]], to document: PDFDocument, fill: StudioColor, searchable: Bool,
        scrubMetadata: Bool, output: URL, dpi: Double = 200,
        scrub: ((String) -> String)? = nil, progress: (Double) -> Void = { _ in }
    ) async throws {
        let prepared = try prepare(
            marks, in: document, fill: fill, dpi: dpi, searchable: searchable, progress: progress)
        var burned: [Int: PDFPage] = [:]
        for (index, item) in prepared {
            try Task.checkCancellation()
            var lines: [StudioPDF.TextLine] = []
            if let unread = item.unread {
                lines = try await StudioVision.recognizeText(in: unread, accurate: true).map {
                    line in
                    StudioPDF.TextLine(
                        text: line.text,
                        rect: CGRect(
                            x: line.box.minX * item.display.width,
                            y: line.box.minY * item.display.height,
                            width: line.box.width * item.display.width,
                            height: line.box.height * item.display.height))
                }
            }
            burned[index] = try item.page(displayLines: lines)
        }
        try write(
            marks, burned: burned, from: document, scrubMetadata: scrubMetadata, scrub: scrub,
            to: output)
    }

    public static func applyWithoutRecognition(
        _ marks: [Int: [CGRect]], to document: PDFDocument, fill: StudioColor, searchable: Bool,
        scrubMetadata: Bool, output: URL, dpi: Double = 200, scrub: ((String) -> String)? = nil
    ) throws {
        let prepared = try prepare(
            marks, in: document, fill: fill, dpi: dpi, searchable: searchable
        ) { _ in }
        let burned = try prepared.mapValues { try $0.page(displayLines: []) }
        try write(
            marks, burned: burned, from: document, scrubMetadata: scrubMetadata, scrub: scrub,
            to: output)
    }

    static func write(
        _ marks: [Int: [CGRect]], burned: [Int: PDFPage], from document: PDFDocument,
        scrubMetadata: Bool, scrub: ((String) -> String)?, to output: URL
    ) throws {
        let assembly = PDFAssembly()
        for index in 0..<document.pageCount {
            if let page = burned[index] {
                assembly.append(page, standingFor: document, index: index)
                continue
            }
            assembly.append(document, pages: [index])
            if let copy = assembly.document.page(at: assembly.document.pageCount - 1) {
                for annotation in copy.annotations where annotation.type == "Redact" {
                    copy.removeAnnotation(annotation)
                }
            }
        }
        for (index, rects) in marks where burned[index] != nil {
            guard let page = document.page(at: index),
                let target = assembly.page(for: document, index)
            else { continue }
            let crop = StudioPDF.cropBox(page)
            for annotation in page.annotations where annotation.type == "Link" {
                guard !rects.contains(where: { $0.intersects(annotation.bounds) }),
                    let link = StudioPDF.relink(
                        annotation,
                        bounds: annotation.bounds.offsetBy(dx: -crop.minX, dy: -crop.minY),
                        map: { assembly.target(for: $0) })
                else { continue }
                target.addAnnotation(link)
            }
        }
        if let outline = assembly.outline(of: document) {
            if let scrub { relabel(outline, scrub) }
            assembly.document.outlineRoot = outline
        }
        let result = assembly.finish()
        result.documentAttributes = scrubMetadata ? [:] : document.documentAttributes
        try StudioPDF.write(result, to: output)
    }

    static func relabel(_ outline: PDFOutline, _ scrub: (String) -> String) {
        for index in 0..<outline.numberOfChildren {
            guard let child = outline.child(at: index) else { continue }
            if let label = child.label { child.label = scrub(label) }
            relabel(child, scrub)
        }
    }

    struct Prepared {
        let burned: CGImage
        let unread: CGImage?
        let pageLines: [StudioPDF.TextLine]
        let crop: CGRect
        let rotation: Int
        let display: CGSize

        func page(displayLines: [StudioPDF.TextLine]) throws -> PDFPage {
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
            StudioPDF.drawInvisibleText(pageLines, in: pdf)
            if !displayLines.isEmpty {
                pdf.saveGState()
                pdf.concatenate(StudioPDF.pageFromDisplay(size: crop.size, rotation: rotation))
                StudioPDF.drawInvisibleText(displayLines, in: pdf)
                pdf.restoreGState()
            }
            pdf.endPage()
            pdf.closePDF()
            guard let redacted = PDFDocument(data: data as Data)?.page(at: 0) else {
                throw StudioError.failed("The redacted page could not be read back.")
            }
            redacted.rotation = rotation
            return redacted
        }
    }

    static func prepare(
        _ marks: [Int: [CGRect]], in document: PDFDocument, fill: StudioColor, dpi: Double,
        searchable: Bool, progress: (Double) -> Void
    ) throws -> [Int: Prepared] {
        var prepared: [Int: Prepared] = [:]
        let indices = marks.keys.sorted()
        for (step, index) in indices.enumerated() {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let rects = marks[index], !rects.isEmpty
            else { continue }
            prepared[index] = try prepare(
                page, rects: rects, fill: fill, dpi: dpi, searchable: searchable)
            progress(Double(step + 1) / Double(indices.count))
        }
        return prepared
    }

    static func prepare(
        _ page: PDFPage, rects: [CGRect], fill: StudioColor, dpi: Double, searchable: Bool
    ) throws -> Prepared {
        let rotation = StudioPDF.rotation(page)
        let crop = StudioPDF.cropBox(page)
        let displayed = try StudioPDF.render(page, dpi: dpi)
        guard let upright = StudioImageOps.rotated(displayed, quarterTurns: -rotation / 90),
            let context = StudioImageOps.context(
                width: upright.width, height: upright.height, opaque: true)
        else { throw StudioError.failed("Not enough memory to redact the page.") }
        let scaleX = Double(upright.width) / crop.width
        let scaleY = Double(upright.height) / crop.height
        let local = rects.map { $0.standardized.offsetBy(dx: -crop.minX, dy: -crop.minY) }
        context.draw(upright, in: CGRect(x: 0, y: 0, width: upright.width, height: upright.height))
        context.setFillColor(fill.cgColor)
        for rect in local {
            context.fill(
                CGRect(
                    x: rect.minX * scaleX, y: rect.minY * scaleY,
                    width: rect.width * scaleX, height: rect.height * scaleY
                ).integral)
        }
        guard let burned = context.makeImage() else {
            throw StudioError.failed("The redacted page could not be drawn.")
        }
        var pageLines: [StudioPDF.TextLine] = []
        var unread: CGImage?
        if searchable {
            let shift = CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
            let glyphs = StudioPDF.glyphs(of: page, transform: shift)
            if glyphs.isEmpty {
                unread = StudioImageOps.rotated(burned, quarterTurns: rotation / 90)
            } else {
                pageLines = StudioPDF.runs(glyphs, excluding: local)
            }
        }
        return Prepared(
            burned: burned, unread: unread, pageLines: pageLines, crop: crop, rotation: rotation,
            display: StudioPDF.displaySize(page))
    }
}
