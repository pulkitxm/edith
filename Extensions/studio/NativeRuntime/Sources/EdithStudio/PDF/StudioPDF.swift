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

    public static func topLeft(of page: PDFPage) -> CGPoint {
        CGPoint(x: 0, y: displaySize(page).height).applying(displayFromPage(page).inverted())
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
        drawDisplayed(page, in: context)
        guard let image = context.makeImage() else {
            throw StudioError.failed("The page could not be rendered.")
        }
        return image
    }

    public static func drawDisplayed(_ page: PDFPage, in context: CGContext) {
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: displaySize(page)))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        page.draw(with: .cropBox, to: context)
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }

    public struct TextLine: Sendable, Equatable {
        public let text: String
        public let rect: CGRect
        public let angle: Int

        public init(text: String, rect: CGRect, angle: Int = 0) {
            self.text = text
            self.rect = rect
            self.angle = angle
        }
    }

    struct Glyph {
        let text: String
        let rect: CGRect
        let lineBreak: Bool
        let space: Bool

        var center: CGPoint { CGPoint(x: rect.midX, y: rect.midY) }
    }

    public static func textLines(of page: PDFPage) -> [TextLine] {
        runs(glyphs(of: page, transform: displayFromPage(page)))
    }

    static func glyphs(of page: PDFPage, transform: CGAffineTransform) -> [Glyph] {
        guard let string = page.string, !string.isEmpty else { return [] }
        let text = string as NSString
        var result: [Glyph] = []
        var lineBreak = false
        var space = false
        var index = 0
        while index < text.length {
            let range = text.rangeOfComposedCharacterSequence(at: index)
            index = range.location + range.length
            let character = text.substring(with: range)
            if character.rangeOfCharacter(from: .newlines) != nil {
                lineBreak = true
                continue
            }
            if character.trimmingCharacters(in: .whitespaces).isEmpty {
                space = true
                continue
            }
            guard let selection = page.selection(for: range) else { continue }
            let bounds = selection.bounds(for: page)
            guard bounds.width > 0 || bounds.height > 0 else { continue }
            result.append(
                Glyph(
                    text: character, rect: bounds.applying(transform).standardized,
                    lineBreak: lineBreak, space: space))
            lineBreak = false
            space = false
        }
        return result
    }

    static func runs(_ glyphs: [Glyph], excluding: [CGRect] = []) -> [TextLine] {
        var lines: [TextLine] = []
        var current: [Glyph] = []
        var direction: CGVector?
        func flush() {
            defer {
                current = []
                direction = nil
            }
            guard let first = current.first else { return }
            var text = first.text
            for (previous, glyph) in zip(current, current.dropFirst()) {
                let thickness = self.thickness(previous, glyph, direction)
                if glyph.space || gap(previous, glyph, direction) > thickness * 0.25 {
                    text += " "
                }
                text += glyph.text
            }
            let rect = current.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            lines.append(TextLine(text: text, rect: rect, angle: angle(of: direction) ?? -1))
        }
        for glyph in glyphs {
            if excluding.contains(where: { $0.intersects(glyph.rect) }) {
                flush()
                continue
            }
            if let last = current.last {
                let candidate = direction ?? axis(from: last, to: glyph)
                if glyph.lineBreak || !follows(glyph, after: last, along: candidate) {
                    flush()
                } else {
                    direction = candidate
                }
            }
            current.append(glyph)
        }
        flush()
        var votes: [Int: Int] = [:]
        for line in lines where line.angle >= 0 { votes[line.angle, default: 0] += line.text.count }
        let dominant = votes.max { $0.value < $1.value }?.key ?? 0
        return lines.map { line in
            line.angle >= 0 ? line : TextLine(text: line.text, rect: line.rect, angle: dominant)
        }
    }

    static func axis(from a: Glyph, to b: Glyph) -> CGVector {
        let dx = b.center.x - a.center.x
        let dy = b.center.y - a.center.y
        if abs(dx) >= abs(dy) { return CGVector(dx: dx >= 0 ? 1 : -1, dy: 0) }
        return CGVector(dx: 0, dy: dy >= 0 ? 1 : -1)
    }

    static func angle(of direction: CGVector?) -> Int? {
        guard let direction else { return nil }
        if direction.dx > 0 { return 0 }
        if direction.dy > 0 { return 90 }
        if direction.dx < 0 { return 180 }
        return 270
    }

    static func thickness(_ a: Glyph, _ b: Glyph, _ direction: CGVector?) -> CGFloat {
        let vertical = direction.map { $0.dx == 0 } ?? false
        return vertical ? max(a.rect.width, b.rect.width) : max(a.rect.height, b.rect.height)
    }

    static func gap(_ a: Glyph, _ b: Glyph, _ direction: CGVector?) -> CGFloat {
        guard let direction else { return 0 }
        let along =
            (b.center.x - a.center.x) * direction.dx + (b.center.y - a.center.y) * direction.dy
        let extent =
            direction.dx == 0
            ? (a.rect.height + b.rect.height) / 2 : (a.rect.width + b.rect.width) / 2
        return along - extent
    }

    static func follows(_ glyph: Glyph, after last: Glyph, along direction: CGVector) -> Bool {
        let along =
            (glyph.center.x - last.center.x) * direction.dx
            + (glyph.center.y - last.center.y) * direction.dy
        let across = abs(
            (glyph.center.x - last.center.x) * direction.dy
                - (glyph.center.y - last.center.y) * direction.dx)
        let thickness = self.thickness(last, glyph, direction)
        guard along > 0, across <= thickness * 0.5 else { return false }
        return gap(last, glyph, direction) <= thickness * 1.2
    }

    public static func drawInvisibleText(_ lines: [TextLine], in context: CGContext) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        for line in lines {
            let turned = line.angle == 90 || line.angle == 270
            let along = turned ? line.rect.height : line.rect.width
            let across = turned ? line.rect.width : line.rect.height
            guard along > 0, across > 0 else { continue }
            let fontSize = max(1, across * 0.86)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(
                string: line.text, attributes: [.font: font as Any])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, &ascent, &descent, nil))
            guard width > 0 else { continue }
            let rect = line.rect
            let origin: CGPoint
            switch line.angle {
            case 90: origin = CGPoint(x: rect.maxX, y: rect.minY)
            case 180: origin = CGPoint(x: rect.maxX, y: rect.maxY)
            case 270: origin = CGPoint(x: rect.minX, y: rect.maxY)
            default: origin = CGPoint(x: rect.minX, y: rect.minY)
            }
            context.saveGState()
            context.translateBy(x: origin.x, y: origin.y)
            context.rotate(by: CGFloat(line.angle) * .pi / 180)
            context.textMatrix = CGAffineTransform(scaleX: along / width, y: 1)
            let baseline = max(0, (across - ascent - descent) / 2) + descent
            context.textPosition = CGPoint(x: 0, y: baseline)
            CTLineDraw(ctLine, context)
            context.restoreGState()
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
        adjust: ((PDFAnnotation) -> Void)? = nil, progress: ((Double) -> Void)? = nil
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
            from: document, into: url, rotations: rotations, keepAnnotations: keepAnnotations,
            adjust: adjust)
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
        from original: PDFDocument, into url: URL, rotations: [Int], keepAnnotations: Bool,
        adjust: ((PDFAnnotation) -> Void)? = nil
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
                adjust?(copy)
                page.addAnnotation(copy)
            }
        }
        if let outline = original.outlineRoot,
            let copied = copyOutline(outline, map: { remap($0, original, final) })
        {
            final.outlineRoot = copied
        }
        try replace(url, with: final)
    }

    static func restoreLinks(from original: PDFDocument, into url: URL) throws {
        let linked = (0..<original.pageCount).contains { index in
            original.page(at: index)?.annotations.contains { $0.type == "Link" } == true
        }
        guard linked, let written = PDFDocument(url: url) else { return }
        let final = fresh(from: written)
        final.documentAttributes = written.documentAttributes
        for index in 0..<min(final.pageCount, original.pageCount) {
            guard let page = final.page(at: index), let source = original.page(at: index)
            else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                page.removeAnnotation(annotation)
            }
            for annotation in source.annotations where annotation.type == "Link" {
                if let link = relink(
                    annotation, bounds: annotation.bounds, original: original, rebuilt: final)
                {
                    page.addAnnotation(link)
                }
            }
        }
        try replace(url, with: final)
    }

    static func replace(_ url: URL, with document: PDFDocument) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).pdf")
        try write(document, to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    public static func fresh(from document: PDFDocument, pages: [Int]? = nil) -> PDFDocument {
        let assembly = PDFAssembly()
        assembly.append(document, pages: pages)
        if let outline = assembly.outline(of: document) {
            assembly.document.outlineRoot = outline
        }
        return assembly.finish()
    }

    static func relink(
        _ annotation: PDFAnnotation, bounds: CGRect, original: PDFDocument, rebuilt: PDFDocument
    ) -> PDFAnnotation? {
        relink(annotation, bounds: bounds) { remap($0, original, rebuilt) }
    }

    static func relink(
        _ annotation: PDFAnnotation, bounds: CGRect,
        map: (PDFDestination) -> PDFDestination?
    ) -> PDFAnnotation? {
        let link = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        link.border = annotation.border
        if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
            link.url = url
            return link
        }
        if let destination = annotation.destination
            ?? (annotation.action as? PDFActionGoTo)?.destination
        {
            guard let mapped = map(destination) else { return nil }
            link.destination = mapped
            return link
        }
        if let named = annotation.action as? PDFActionNamed {
            link.action = PDFActionNamed(name: named.name)
            return link
        }
        if let remote = annotation.action as? PDFActionRemoteGoTo {
            link.action = PDFActionRemoteGoTo(
                pageIndex: remote.pageIndex, at: remote.point, fileURL: remote.url)
            return link
        }
        return nil
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
        copyOutline(source, map: { remap($0, original, rebuilt) }) ?? PDFOutline()
    }

    static func copyOutline(
        _ source: PDFOutline, map: (PDFDestination) -> PDFDestination?
    ) -> PDFOutline? {
        let root = PDFOutline()
        appendChildren(of: source, to: root, map: map)
        return root.numberOfChildren > 0 ? root : nil
    }

    static func appendChildren(
        of source: PDFOutline, to parent: PDFOutline, map: (PDFDestination) -> PDFDestination?
    ) {
        for index in 0..<source.numberOfChildren {
            guard let child = source.child(at: index) else { continue }
            let copy = PDFOutline()
            copy.label = child.label
            var target = false
            if let destination = child.destination
                ?? (child.action as? PDFActionGoTo)?.destination
            {
                if let mapped = map(destination) {
                    copy.destination = mapped
                    target = true
                }
            } else if let url = (child.action as? PDFActionURL)?.url {
                copy.action = PDFActionURL(url: url)
                target = true
            }
            appendChildren(of: child, to: copy, map: map)
            guard target || copy.numberOfChildren > 0 else { continue }
            parent.insertChild(copy, at: parent.numberOfChildren)
            copy.isOpen = child.isOpen
        }
    }

    struct Placement {
        let source: Int
        let target: Int
        let transform: CGAffineTransform
    }

    static func identityPlacements(_ document: PDFDocument) -> [Placement] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index).map {
                Placement(source: index, target: index, transform: displayFromPage($0))
            }
        }
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

final class PDFNavigation {
    struct Link {
        let page: Int
        let rect: CGRect
        let url: URL?
        let name: String?
    }

    struct Anchor {
        let page: Int
        let name: String
        let point: CGPoint
    }

    private(set) var links: [Link] = []
    private var anchors: [Anchor] = []
    private var outline: [CFString: Any]?

    init(original: PDFDocument, placements: [StudioPDF.Placement]) {
        var first: [Int: StudioPDF.Placement] = [:]
        for placement in placements where first[placement.source] == nil {
            first[placement.source] = placement
        }
        func resolve(_ destination: PDFDestination) -> (page: Int, point: CGPoint)? {
            guard let page = destination.page else { return nil }
            let index = original.index(for: page)
            guard index != NSNotFound, let placement = first[index] else { return nil }
            var point = destination.point
            let unspecified = kPDFDestinationUnspecifiedValue
            if point.x == unspecified || point.y == unspecified {
                let top = CGPoint(x: 0, y: StudioPDF.displaySize(page).height)
                point = top.applying(StudioPDF.displayFromPage(page).inverted())
            }
            return (placement.target, point.applying(placement.transform))
        }
        for placement in placements {
            guard let page = original.page(at: placement.source) else { continue }
            for annotation in page.annotations where annotation.type == "Link" {
                let rect = annotation.bounds.applying(placement.transform).standardized
                if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                    links.append(Link(page: placement.target, rect: rect, url: url, name: nil))
                } else if let destination = annotation.destination
                    ?? (annotation.action as? PDFActionGoTo)?.destination,
                    let target = resolve(destination)
                {
                    let name = "studio-link-\(anchors.count + 1)"
                    anchors.append(Anchor(page: target.page, name: name, point: target.point))
                    links.append(Link(page: placement.target, rect: rect, url: nil, name: name))
                }
            }
        }
        func entries(_ item: PDFOutline) -> [[CFString: Any]] {
            (0..<item.numberOfChildren).compactMap { index -> [CFString: Any]? in
                guard let child = item.child(at: index) else { return nil }
                var entry: [CFString: Any] = [kCGPDFOutlineTitle: child.label ?? ""]
                let children = entries(child)
                if let destination = child.destination
                    ?? (child.action as? PDFActionGoTo)?.destination,
                    let target = resolve(destination)
                {
                    entry[kCGPDFOutlineDestination] = NSNumber(value: target.page + 1)
                    entry[kCGPDFOutlineDestinationRect] =
                        CGRect(origin: target.point, size: .zero).dictionaryRepresentation
                } else if let url = (child.action as? PDFActionURL)?.url {
                    entry[kCGPDFOutlineDestination] = url
                } else if let first = children.first {
                    entry[kCGPDFOutlineDestination] = first[kCGPDFOutlineDestination]
                } else {
                    return nil
                }
                if !children.isEmpty { entry[kCGPDFOutlineChildren] = children }
                return entry
            }
        }
        if let root = original.outlineRoot {
            let children = entries(root)
            if !children.isEmpty { outline = [kCGPDFOutlineChildren: children] }
        }
    }

    func begin(page: Int, in context: CGContext) {
        for anchor in anchors where anchor.page == page {
            context.addDestination(anchor.name as CFString, at: anchor.point)
        }
        for link in links where link.page == page {
            if let url = link.url {
                context.setURL(url as CFURL, for: link.rect)
            } else if let name = link.name {
                context.setDestination(name as CFString, for: link.rect)
            }
        }
    }

    func finish(in context: CGContext) {
        guard let outline else { return }
        CGPDFContextSetOutline(context, outline as CFDictionary)
    }
}

final class PDFAssembly {
    let document = PDFDocument()
    private var targets: [ObjectIdentifier: [Int: PDFPage]] = [:]
    private var copies: [(links: [PDFAnnotation], copy: PDFPage)] = []
    private var sources: [PDFDocument] = []

    @discardableResult
    func append(_ source: PDFDocument, pages: [Int]? = nil) -> Int {
        sources.append(source)
        var appended = 0
        for index in pages ?? Array(0..<source.pageCount) {
            guard let page = source.page(at: index) else { continue }
            let links = page.annotations.filter { $0.type == "Link" }
            guard let copy = page.copy() as? PDFPage else { continue }
            document.insert(copy, at: document.pageCount)
            Self.removeLinks(from: copy)
            let key = ObjectIdentifier(source)
            if targets[key]?[index] == nil { targets[key, default: [:]][index] = copy }
            copies.append((links, copy))
            appended += 1
        }
        return appended
    }

    func append(_ page: PDFPage) {
        document.insert(page, at: document.pageCount)
    }

    func append(_ page: PDFPage, standingFor source: PDFDocument, index: Int) {
        sources.append(source)
        document.insert(page, at: document.pageCount)
        let key = ObjectIdentifier(source)
        if targets[key]?[index] == nil { targets[key, default: [:]][index] = page }
    }

    func page(for source: PDFDocument, _ index: Int) -> PDFPage? {
        targets[ObjectIdentifier(source)]?[index]
    }

    func target(for destination: PDFDestination) -> PDFDestination? {
        guard let page = destination.page, let owner = page.document else { return nil }
        let index = owner.index(for: page)
        guard index != NSNotFound, let target = targets[ObjectIdentifier(owner)]?[index] else {
            return nil
        }
        return PDFDestination(page: target, at: destination.point)
    }

    static func removeLinks(from page: PDFPage) {
        for annotation in page.annotations where annotation.type == "Link" {
            page.removeAnnotation(annotation)
        }
    }

    func outline(of source: PDFDocument) -> PDFOutline? {
        guard let root = source.outlineRoot else { return nil }
        return StudioPDF.copyOutline(root) { self.target(for: $0) }
    }

    func finish() -> PDFDocument {
        for (links, copy) in copies {
            Self.removeLinks(from: copy)
            for annotation in links {
                if let link = StudioPDF.relink(
                    annotation, bounds: annotation.bounds, map: { self.target(for: $0) })
                {
                    copy.addAnnotation(link)
                }
            }
        }
        copies = []
        return document
    }
}

extension StudioTool {
    func checkingChoices() -> StudioTool {
        guard let perform else { return self }
        let options = self.options
        return StudioTool(
            id: id, title: title, summary: summary, symbol: symbolName, group: group,
            inputs: inputs, extraExtensions: extraExtensions,
            excludedExtensions: excludedExtensions, arity: arity, produces: produces,
            options: options, requirements: requirements, style: style, keywords: keywords,
            groupsOutputs: groupsOutputs, actionTitle: actionTitle, family: family
        ) { run in
            let settings = try StudioChoices.normalized(run.settings, options: options)
            return try await perform(
                StudioRun(
                    tool: run.tool, inputs: run.inputs, settings: settings,
                    workDirectory: run.workDirectory, environment: run.environment,
                    reporter: run.reporter))
        }
    }
}

enum StudioChoices {
    static func normalized(_ settings: StudioSettings, options: [StudioOption]) throws
        -> StudioSettings
    {
        var result = settings
        for option in options where option.isVisible(in: settings) {
            guard case .choice(let choices) = option.kind, let value = settings[option.key]
            else { continue }
            let raw = (value.text ?? value.display).trimmingCharacters(in: .whitespaces)
            guard let match = choices.first(where: { $0.value.lowercased() == raw.lowercased() })
            else {
                throw StudioError.invalidOption(
                    option.label.lowercased(),
                    "use one of " + choices.map(\.value).joined(separator: ", "))
            }
            result[option.key] = .text(match.value)
        }
        return result
    }
}
