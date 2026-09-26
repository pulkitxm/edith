import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

public enum StudioPDF {
    public static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        if document.isLocked {
            let secret = password?.trimmingCharacters(in: .newlines) ?? ""
            guard !secret.isEmpty else { throw StudioError.needsPassword(url.lastPathComponent) }
            guard document.unlock(withPassword: secret) else {
                throw StudioError.wrongPassword(url.lastPathComponent)
            }
        }
        return document
    }

    public static func write(
        _ document: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]
    ) throws {
        let written =
            options.isEmpty
            ? document.write(to: url) : document.write(to: url, withOptions: options)
        guard written, FileManager.default.fileExists(atPath: url.path) else {
            throw StudioError.failed("The PDF could not be saved.")
        }
    }

    public static func cropBox(_ page: PDFPage) -> CGRect {
        page.bounds(for: .cropBox).standardized
    }

    public static func rotation(_ page: PDFPage) -> Int {
        ((page.rotation % 360) + 360) % 360
    }

    public static func displaySize(_ page: PDFPage) -> CGSize {
        let box = cropBox(page)
        let rotation = rotation(page)
        return rotation == 90 || rotation == 270
            ? CGSize(width: box.height, height: box.width) : box.size
    }

    public static func pageFromDisplay(size: CGSize, rotation: Int) -> CGAffineTransform {
        let w = size.width
        let h = size.height
        switch rotation {
        case 90: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: w, ty: 0)
        case 180: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: h)
        default: return .identity
        }
    }

    public static func displayFromPage(_ page: PDFPage) -> CGAffineTransform {
        let box = cropBox(page)
        let shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        let inverse = pageFromDisplay(size: box.size, rotation: rotation(page)).inverted()
        return shift.concatenating(inverse)
    }

    public static func render(
        _ page: PDFPage, dpi: Double, background: CGColor? = CGColor(gray: 1, alpha: 1),
        maxPixels: Int = 120_000_000
    ) throws -> CGImage {
        let size = displaySize(page)
        var scale = dpi / 72
        let pixels = size.width * scale * size.height * scale
        if pixels > Double(maxPixels) { scale *= (Double(maxPixels) / pixels).squareRoot() }
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StudioError.failed("Not enough memory to render the page.") }
        if let background {
            context.setFillColor(background)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        context.interpolationQuality = .high
        context.scaleBy(x: CGFloat(width) / size.width, y: CGFloat(height) / size.height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        page.draw(with: .cropBox, to: context)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else {
            throw StudioError.failed("The page could not be rendered.")
        }
        return image
    }

    public struct TextLine: Sendable, Equatable {
        public let text: String
        public let rect: CGRect

        public init(text: String, rect: CGRect) {
            self.text = text
            self.rect = rect
        }
    }

    public static func textLines(of page: PDFPage) -> [TextLine] {
        guard let string = page.string,
            !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let selection = page.selection(for: NSRange(location: 0, length: string.utf16.count))
        else { return [] }
        let toDisplay = displayFromPage(page)
        return selection.selectionsByLine().compactMap { line in
            guard let text = line.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                !text.isEmpty
            else { return nil }
            let rect = line.bounds(for: page).applying(toDisplay).standardized
            guard rect.width > 0.5, rect.height > 0.5 else { return nil }
            return TextLine(text: text, rect: rect)
        }
    }

    public static func drawInvisibleText(_ lines: [TextLine], in context: CGContext) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let fontSize = max(1, line.rect.height * 0.86)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(
                string: line.text, attributes: [.font: font as Any])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            guard width > 0 else { continue }
            let scaleX = line.rect.width / width
            context.textMatrix = CGAffineTransform(scaleX: scaleX, y: 1)
            let baseline =
                line.rect.minY + max(0, (line.rect.height - ascent - descent) / 2) + descent
            context.textPosition = CGPoint(x: line.rect.minX, y: baseline)
            CTLineDraw(ctLine, context)
        }
        context.restoreGState()
    }

    public static func jpegImage(_ image: CGImage, quality: Double, grayscale: Bool = false) throws
        -> CGImage
    {
        var source = image
        if grayscale, let gray = StudioImageOps.grayscale(image) { source = gray }
        let data = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                data, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw StudioError.failed("JPEG encoding is not available.") }
        CGImageDestinationAddImage(
            destination, source,
            [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
            let provider = CGDataProvider(data: data as CFData),
            let jpeg = CGImage(
                jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent)
        else { throw StudioError.failed("JPEG encoding failed.") }
        return jpeg
    }

    public struct PageCanvas {
        public let context: CGContext
        public let size: CGSize
        public let index: Int
        public let count: Int
    }

    public static func rebuild(
        _ document: PDFDocument, to url: URL, pages selected: Set<Int>? = nil,
        keepAnnotations: Bool = true, auxiliaryInfo: [CFString: Any] = [:],
        pageSetup: ((CGContext) -> Void)? = nil,
        under: ((PageCanvas) throws -> Void)? = nil, over: ((PageCanvas) throws -> Void)? = nil,
        progress: ((Double) -> Void)? = nil
    ) throws {
        var info: [CFString: Any] = auxiliaryInfo
        for (key, value) in documentInfo(document) where info[key] == nil { info[key] = value }
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        let count = document.pageCount
        var rotations: [Int] = []
        for index in 0..<count {
            try Task.checkCancellation()
            guard let page = document.page(at: index), let cgPage = page.pageRef else { continue }
            let box = cropBox(page)
            let rotation = rotation(page)
            rotations.append(rotation)
            var mediaBox = CGRect(origin: .zero, size: box.size)
            context.beginPage(mediaBox: &mediaBox)
            pageSetup?(context)
            let applies = selected?.contains(index) ?? true
            let display = displaySize(page)
            let toPage = pageFromDisplay(size: box.size, rotation: rotation)
            if applies, let under {
                context.saveGState()
                context.concatenate(toPage)
                try under(PageCanvas(context: context, size: display, index: index, count: count))
                context.restoreGState()
            }
            context.saveGState()
            context.clip(to: mediaBox)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(cgPage)
            context.restoreGState()
            if applies, let over {
                context.saveGState()
                context.concatenate(toPage)
                try over(PageCanvas(context: context, size: display, index: index, count: count))
                context.restoreGState()
            }
            context.endPage()
            progress?(Double(index + 1) / Double(max(count, 1)) * 0.9)
        }
        context.closePDF()
        try restoreStructure(
            from: document, into: url, rotations: rotations, keepAnnotations: keepAnnotations)
    }

    static func documentInfo(_ document: PDFDocument) -> [CFString: Any] {
        var info: [CFString: Any] = [:]
        let attributes = document.documentAttributes ?? [:]
        let pairs: [(PDFDocumentAttribute, CFString)] = [
            (.titleAttribute, kCGPDFContextTitle), (.authorAttribute, kCGPDFContextAuthor),
            (.subjectAttribute, kCGPDFContextSubject), (.creatorAttribute, kCGPDFContextCreator),
            (.keywordsAttribute, kCGPDFContextKeywords),
        ]
        for (attribute, key) in pairs {
            if let value = attributes[attribute] as? String, !value.isEmpty {
                info[key] = value
            } else if let values = attributes[attribute] as? [String], !values.isEmpty {
                info[key] = values.joined(separator: ", ")
            }
        }
        return info
    }

    static func restoreStructure(
        from original: PDFDocument, into url: URL, rotations: [Int], keepAnnotations: Bool
    ) throws {
        guard let rebuilt = PDFDocument(url: url) else {
            throw StudioError.failed("The rebuilt PDF could not be reopened.")
        }
        let hasAnnotations = (0..<original.pageCount).contains {
            original.page(at: $0)?.annotations.isEmpty == false
        }
        let hasOutline = (original.outlineRoot?.numberOfChildren ?? 0) > 0
        guard
            rotations.contains(where: { $0 != 0 }) || (keepAnnotations && hasAnnotations)
                || hasOutline
        else { return }
        let final = fresh(from: rebuilt)
        final.documentAttributes = rebuilt.documentAttributes
        for index in 0..<min(final.pageCount, original.pageCount) {
            guard let page = final.page(at: index), let source = original.page(at: index)
            else { continue }
            if index < rotations.count { page.rotation = rotations[index] }
            guard keepAnnotations else { continue }
            let box = cropBox(source)
            for annotation in source.annotations {
                let bounds = annotation.bounds.offsetBy(dx: -box.minX, dy: -box.minY)
                if annotation.type == "Link" {
                    if let link = relink(
                        annotation, bounds: bounds, original: original, rebuilt: final)
                    {
                        page.addAnnotation(link)
                    }
                    continue
                }
                guard annotation.type != "Popup",
                    let copy = annotation.copy() as? PDFAnnotation
                else { continue }
                copy.bounds = bounds
                page.addAnnotation(copy)
            }
        }
        if let outline = original.outlineRoot, outline.numberOfChildren > 0 {
            final.outlineRoot = copyOutline(outline, original: original, rebuilt: final)
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).pdf")
        try write(final, to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func fresh(from document: PDFDocument, pages: [Int]? = nil) -> PDFDocument {
        let result = PDFDocument()
        for index in pages ?? Array(0..<document.pageCount) {
            if let page = document.page(at: index)?.copy() as? PDFPage {
                result.insert(page, at: result.pageCount)
            }
        }
        return result
    }

    static func relink(
        _ annotation: PDFAnnotation, bounds: CGRect, original: PDFDocument, rebuilt: PDFDocument
    ) -> PDFAnnotation? {
        let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        link.border = annotation.border
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            link.url = url
            return link
        }
        let destination =
            annotation.destination ?? (annotation.action as? PDFActionGoTo)?.destination
        guard let destination, let mapped = remap(destination, original, rebuilt) else {
            return nil
        }
        link.destination = mapped
        return link
    }

    static func remap(
        _ destination: PDFDestination, _ original: PDFDocument, _ rebuilt: PDFDocument
    ) -> PDFDestination? {
        guard let page = destination.page else { return nil }
        let index = original.index(for: page)
        guard index != NSNotFound, let target = rebuilt.page(at: index) else { return nil }
        return PDFDestination(page: target, at: destination.point)
    }

    static func copyOutline(
        _ source: PDFOutline, original: PDFDocument, rebuilt: PDFDocument
    ) -> PDFOutline {
        let copy = PDFOutline()
        copy.label = source.label
        if let destination = source.destination {
            copy.destination = remap(destination, original, rebuilt)
        }
        for index in 0..<source.numberOfChildren {
            guard let child = source.child(at: index) else { continue }
            copy.insertChild(
                copyOutline(child, original: original, rebuilt: rebuilt), at: copy.numberOfChildren)
        }
        copy.isOpen = source.isOpen
        return copy
    }

    public static func imagePage(_ image: CGImage, size: CGSize) -> PDFPage? {
        let nsImage = NSImage(cgImage: image, size: size)
        return PDFPage(image: nsImage)
    }

    public static func pageCount(_ url: URL) -> Int? {
        guard let document = CGPDFDocument(url as CFURL) else { return nil }
        return document.numberOfPages
    }
}
