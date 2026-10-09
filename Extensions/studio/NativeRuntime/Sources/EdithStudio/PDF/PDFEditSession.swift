import AppKit
import CoreGraphics
import Foundation
import PDFKit

public final class PDFEditSession {
    public enum Shape: String, CaseIterable, Sendable {
        case rectangle
        case ellipse
        case line
        case arrow
    }

    public enum Markup: String, CaseIterable, Sendable {
        case highlight
        case underline
        case strikeOut
    }

    public enum Field: Equatable, Sendable {
        case text(multiline: Bool)
        case checkbox
        case choice([String])
    }

    public struct Style: Equatable, Sendable {
        public var color: StudioColor
        public var fill: StudioColor?
        public var lineWidth: Double
        public var fontName: String
        public var fontSize: Double

        public init(
            color: StudioColor = StudioColor(red: 0.85, green: 0.12, blue: 0.1),
            fill: StudioColor? = nil, lineWidth: Double = 2, fontName: String = "Helvetica",
            fontSize: Double = 14
        ) {
            self.color = color
            self.fill = fill
            self.lineWidth = lineWidth
            self.fontName = fontName
            self.fontSize = fontSize
        }
    }

    public struct Placement: Identifiable {
        public let id: UUID
        public var page: Int
        public var rect: CGRect
        public var image: CGImage
        public var opacity: Double
        public var rotation = 0
    }

    public static let placementMarker = "studio.placement"
    public static let redactionMarker = "studio.redaction"

    public let source: URL
    public private(set) var document: PDFDocument
    public private(set) var placements: [Placement] = []
    public private(set) var isDirty = false

    public init(url: URL, password: String? = nil) throws {
        source = url
        document = try StudioPDF.open(url, password: password)
    }

    public init(document: PDFDocument, source: URL) {
        self.source = source
        self.document = document
    }

    public init?(snapshot: Snapshot, source: URL) {
        guard let document = PDFDocument(data: snapshot.data) else { return nil }
        self.source = source
        self.document = document
        placements = snapshot.placements
        refreshMarkers(redactions: snapshot.redactions)
    }

    public var pageCount: Int { document.pageCount }

    public var redactions: [Int: [CGRect]] {
        var marks: [Int: [CGRect]] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let rects = page.annotations.filter { $0.userName == Self.redactionMarker }
                .map { $0.bounds.standardized }
            if !rects.isEmpty { marks[index] = rects }
        }
        return marks
    }

    public func markSaved() {
        isDirty = false
    }

    public func page(_ index: Int) -> PDFPage? { document.page(at: index) }

    public func index(of page: PDFPage) -> Int? {
        let index = document.index(for: page)
        return index == NSNotFound ? nil : index
    }

    public struct Snapshot: @unchecked Sendable {
        let data: Data
        let placements: [Placement]
        let redactions: [Int: [CGRect]]
    }

    public func snapshot() -> Snapshot? {
        let marks = redactions
        let markers = removeMarkers()
        defer { restoreMarkers(markers) }
        guard let data = document.dataRepresentation() else { return nil }
        return Snapshot(data: data, placements: placements, redactions: marks)
    }

    public func restore(_ snapshot: Snapshot) {
        guard let restored = PDFDocument(data: snapshot.data) else { return }
        document = restored
        placements = snapshot.placements
        refreshMarkers(redactions: snapshot.redactions)
        isDirty = true
    }

    public func movePage(from source: Int, to destination: Int) {
        guard source != destination, let page = document.page(at: source) else { return }
        document.removePage(at: source)
        let target = min(max(destination, 0), document.pageCount)
        document.insert(page, at: target)
        remapPages { index in
            if index == source { return target }
            if source < target, index > source, index <= target { return index - 1 }
            if source > target, index >= target, index < source { return index + 1 }
            return index
        }
        isDirty = true
    }

    public func rotatePages(_ indices: [Int], by degrees: Int) {
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            page.rotation = ((StudioPDF.rotation(page) + degrees) % 360 + 360) % 360
        }
        isDirty = true
    }

    public func deletePages(_ indices: Set<Int>) throws {
        guard indices.count < document.pageCount else {
            throw StudioError.nothingToDo("A PDF needs at least one page.")
        }
        for index in indices.sorted(by: >) { document.removePage(at: index) }
        let sorted = indices.sorted()
        placements.removeAll { indices.contains($0.page) }
        remapPages { index in index - sorted.filter { $0 < index }.count }
        isDirty = true
    }

    public func duplicatePage(_ index: Int) {
        guard let page = document.page(at: index) else { return }
        let placed = page.annotations.filter { $0 is PlacementAnnotation }
        for annotation in placed { page.removeAnnotation(annotation) }
        let copy = page.copy() as? PDFPage
        for annotation in placed { page.addAnnotation(annotation) }
        guard let copy else { return }
        remapPages { $0 > index ? $0 + 1 : $0 }
        document.insert(copy, at: index + 1)
        for placement in placements where placement.page == index {
            let clone = Placement(
                id: UUID(), page: index + 1, rect: placement.rect, image: placement.image,
                opacity: placement.opacity, rotation: placement.rotation)
            placements.append(clone)
            copy.addAnnotation(PlacementAnnotation(placement: clone))
        }
        isDirty = true
    }

    public func insertBlankPage(at index: Int, size: CGSize? = nil) {
        let reference = document.page(at: max(0, min(index, document.pageCount - 1)))
        let pageSize = size ?? reference.map(StudioPDF.displaySize) ?? StudioPaperSize.a4.points
        let page = PDFPage()
        page.setBounds(CGRect(origin: .zero, size: pageSize), for: .mediaBox)
        let target = min(max(index, 0), document.pageCount)
        remapPages { $0 >= target ? $0 + 1 : $0 }
        document.insert(page, at: target)
        isDirty = true
    }

    public func insertPages(from url: URL, at index: Int, password: String? = nil) throws -> Int {
        var target = min(max(index, 0), document.pageCount)
        var inserted = 0
        if url.studioKind == .image {
            let image = try StudioImageIO.load(url)
            guard let page = ImagesToPDF.page(for: image, layout: .init()) else { return 0 }
            remapPages { $0 >= target ? $0 + 1 : $0 }
            document.insert(page, at: target)
            isDirty = true
            return 1
        }
        let other = try StudioPDF.open(url, password: password)
        let count = other.pageCount
        remapPages { $0 >= target ? $0 + count : $0 }
        for pageIndex in 0..<count {
            guard let page = other.page(at: pageIndex)?.copy() as? PDFPage else { continue }
            document.insert(page, at: target)
            target += 1
            inserted += 1
        }
        isDirty = true
        return inserted
    }

    public func extractPages(_ indices: [Int], to url: URL) throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let composed = try compose(pages: indices.sorted(), scratch: scratch) { _ in }
        guard !composed.marks.isEmpty else {
            try StudioPDF.write(composed.document, to: url)
            return
        }
        try PDFRedaction.applyWithoutRecognition(
            composed.marks, to: composed.document, fill: .black, searchable: true,
            scrubMetadata: false, output: url)
    }

    func compose(pages selection: [Int]?, scratch: URL, progress: @escaping (Double) -> Void)
        throws -> (document: PDFDocument, marks: [Int: [CGRect]])
    {
        let selected = selection ?? Array(0..<document.pageCount)
        let position = Dictionary(
            selected.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        var marks: [Int: [CGRect]] = [:]
        for (index, rects) in redactions {
            if let target = position[index] { marks[target] = rects }
        }
        let markers = removeMarkers()
        defer { restoreMarkers(markers) }
        var working = StudioPDF.fresh(from: document, pages: selected)
        working.documentAttributes = document.documentAttributes
        var chosen: [Int: [Placement]] = [:]
        for placement in placements {
            if let target = position[placement.page] {
                chosen[target, default: []].append(placement)
            }
        }
        guard !chosen.isEmpty else { return (working, marks) }
        let stage = scratch.appendingPathComponent("placed.pdf")
        let pages = (0..<working.pageCount).map { working.page(at: $0) }
        for (index, rects) in marks {
            guard let crop = pages[index].map(StudioPDF.cropBox) else { continue }
            marks[index] = rects.map { $0.offsetBy(dx: -crop.minX, dy: -crop.minY) }
        }
        try StudioPDF.rebuild(
            working, to: stage, pages: Set(chosen.keys),
            over: { canvas in
                guard let page = pages[canvas.index] else { return }
                for placement in chosen[canvas.index] ?? [] {
                    Self.draw(
                        placement.image, opacity: placement.opacity, bounds: placement.rect,
                        placedAt: placement.rotation, on: page, in: canvas.context)
                }
            }, progress: progress)
        working = try StudioPDF.open(stage)
        return (working, marks)
    }

    @discardableResult
    public func addText(_ text: String, in rect: CGRect, page index: Int, style: Style)
        -> PDFAnnotation?
    {
        guard let page = document.page(at: index) else { return nil }
        let annotation = PDFAnnotation(bounds: rect, forType: .freeText, withProperties: nil)
        annotation.contents = text
        annotation.font =
            NSFont(name: style.fontName, size: style.fontSize)
            ?? NSFont.systemFont(ofSize: style.fontSize)
        annotation.fontColor = NSColor(cgColor: style.color.cgColor) ?? .black
        annotation.color = style.fill.flatMap { NSColor(cgColor: $0.cgColor) } ?? .clear
        let border = PDFBorder()
        border.lineWidth = 0
        annotation.border = border
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    public static func textBounds(_ text: String, at point: CGPoint, style: Style) -> CGRect {
        let font =
            NSFont(name: style.fontName, size: style.fontSize)
            ?? NSFont.systemFont(ofSize: style.fontSize)
        let size = (text as NSString).boundingRect(
            with: CGSize(width: 420, height: 2000), options: [.usesLineFragmentOrigin],
            attributes: [.font: font]
        ).size
        return CGRect(
            x: point.x, y: point.y - size.height - 6, width: max(size.width + 14, 40),
            height: size.height + 8)
    }

    @discardableResult
    public func addShape(
        _ shape: Shape, from start: CGPoint, to end: CGPoint, page index: Int, style: Style
    ) -> PDFAnnotation? {
        guard let page = document.page(at: index) else { return nil }
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).standardized
        let border = PDFBorder()
        border.lineWidth = style.lineWidth
        let annotation: PDFAnnotation
        switch shape {
        case .rectangle, .ellipse:
            annotation = PDFAnnotation(
                bounds: rect.insetBy(dx: -style.lineWidth, dy: -style.lineWidth),
                forType: shape == .rectangle ? .square : .circle, withProperties: nil)
            annotation.interiorColor = style.fill.flatMap { NSColor(cgColor: $0.cgColor) }
        case .line, .arrow:
            let padded = rect.insetBy(dx: -style.lineWidth * 4 - 4, dy: -style.lineWidth * 4 - 4)
            annotation = PDFAnnotation(bounds: padded, forType: .line, withProperties: nil)
            annotation.startPoint = CGPoint(x: start.x - padded.minX, y: start.y - padded.minY)
            annotation.endPoint = CGPoint(x: end.x - padded.minX, y: end.y - padded.minY)
            annotation.startLineStyle = .none
            annotation.endLineStyle = shape == .arrow ? .closedArrow : .none
            annotation.interiorColor = NSColor(cgColor: style.color.cgColor)
        }
        annotation.color = NSColor(cgColor: style.color.cgColor) ?? .red
        annotation.border = border
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    @discardableResult
    public func addInk(_ strokes: [[CGPoint]], page index: Int, style: Style) -> PDFAnnotation? {
        guard let page = document.page(at: index), !strokes.isEmpty else { return nil }
        var bounds = CGRect.null
        for stroke in strokes {
            for point in stroke { bounds = bounds.union(CGRect(origin: point, size: .zero)) }
        }
        guard !bounds.isNull else { return nil }
        let padded = bounds.insetBy(dx: -style.lineWidth - 2, dy: -style.lineWidth - 2)
        let annotation = PDFAnnotation(bounds: padded, forType: .ink, withProperties: nil)
        for stroke in strokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x - padded.minX, y: stroke[0].y - padded.minY))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x - padded.minX, y: point.y - padded.minY))
            }
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            annotation.add(path)
        }
        let border = PDFBorder()
        border.lineWidth = style.lineWidth
        annotation.border = border
        annotation.color = NSColor(cgColor: style.color.cgColor) ?? .red
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    @discardableResult
    public func addMarkup(_ markup: Markup, for selection: PDFSelection, color: StudioColor)
        -> Int
    {
        var added = 0
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let bounds = line.bounds(for: page)
                guard bounds.width > 0 else { continue }
                let type: PDFAnnotationSubtype =
                    switch markup {
                    case .highlight: .highlight
                    case .underline: .underline
                    case .strikeOut: .strikeOut
                    }
                let annotation = PDFAnnotation(bounds: bounds, forType: type, withProperties: nil)
                annotation.color =
                    NSColor(cgColor: color.cgColor)?.withAlphaComponent(
                        markup == .highlight ? 0.45 : 1) ?? .yellow
                page.addAnnotation(annotation)
                added += 1
            }
        }
        if added > 0 { isDirty = true }
        return added
    }

    @discardableResult
    public func addNote(_ text: String, at point: CGPoint, page index: Int, color: StudioColor)
        -> PDFAnnotation?
    {
        guard let page = document.page(at: index) else { return nil }
        let annotation = PDFAnnotation(
            bounds: CGRect(x: point.x, y: point.y - 20, width: 20, height: 20), forType: .text,
            withProperties: nil)
        annotation.contents = text
        annotation.color = NSColor(cgColor: color.cgColor) ?? .yellow
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    @discardableResult
    public func addField(_ field: Field, in rect: CGRect, page index: Int, name: String)
        -> PDFAnnotation?
    {
        guard let page = document.page(at: index) else { return nil }
        let annotation = PDFAnnotation(bounds: rect, forType: .widget, withProperties: nil)
        switch field {
        case .text(let multiline):
            annotation.widgetFieldType = .text
            annotation.isMultiline = multiline
            annotation.font = NSFont.systemFont(ofSize: min(12, max(8, rect.height * 0.6)))
        case .checkbox:
            annotation.widgetFieldType = .button
            annotation.widgetControlType = .checkBoxControl
            annotation.buttonWidgetState = .offState
        case .choice(let options):
            annotation.widgetFieldType = .choice
            annotation.choices = options
            annotation.widgetStringValue = options.first ?? ""
            annotation.font = NSFont.systemFont(ofSize: min(12, max(8, rect.height * 0.6)))
        }
        annotation.fieldName = name
        annotation.backgroundColor = NSColor(calibratedRed: 0.86, green: 0.91, blue: 1, alpha: 0.55)
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        annotation.color = NSColor(calibratedRed: 0.35, green: 0.45, blue: 0.7, alpha: 1)
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    public func nextFieldName(prefix: String = "Field") -> String {
        var names = Set<String>()
        for index in 0..<document.pageCount {
            for annotation in document.page(at: index)?.annotations ?? [] {
                if let name = annotation.fieldName { names.insert(name) }
            }
        }
        var number = 1
        while names.contains("\(prefix) \(number)") { number += 1 }
        return "\(prefix) \(number)"
    }

    public func detectFormFields() -> Int {
        var created = 0
        let pattern = try? NSRegularExpression(pattern: #"_{4,}|\[\s?\]|☐|□"#)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index), let text = page.string, let pattern else {
                continue
            }
            let existing = page.annotations.filter { $0.type == "Widget" }.map(\.bounds)
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let selection = page.selection(for: match.range) else { continue }
                let bounds = selection.bounds(for: page)
                guard bounds.width > 2, !existing.contains(where: { $0.intersects(bounds) }) else {
                    continue
                }
                let token = (text as NSString).substring(with: match.range)
                if token.hasPrefix("_") {
                    let field = CGRect(
                        x: bounds.minX, y: bounds.minY, width: bounds.width,
                        height: max(bounds.height + 6, 16))
                    addField(.text(multiline: false), in: field, page: index, name: nextFieldName())
                } else {
                    let side = max(bounds.height, 12)
                    addField(
                        .checkbox,
                        in: CGRect(
                            x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side,
                            height: side),
                        page: index, name: nextFieldName(prefix: "Check"))
                }
                created += 1
            }
        }
        return created
    }

    public func remove(_ annotation: PDFAnnotation) {
        guard let page = annotation.page else { return }
        if let id = placementID(of: annotation) {
            placements.removeAll { $0.id == id }
        }
        page.removeAnnotation(annotation)
        isDirty = true
    }

    public func move(_ annotation: PDFAnnotation, to bounds: CGRect) {
        annotation.bounds = bounds
        if let id = placementID(of: annotation),
            let position = placements.firstIndex(where: { $0.id == id })
        {
            placements[position].rect = bounds
        }
        isDirty = true
    }

    @discardableResult
    public func place(_ image: CGImage, in rect: CGRect, page index: Int, opacity: Double = 1)
        -> UUID?
    {
        guard let page = document.page(at: index) else { return nil }
        let placement = Placement(
            id: UUID(), page: index, rect: rect, image: image, opacity: opacity,
            rotation: StudioPDF.rotation(page))
        placements.append(placement)
        page.addAnnotation(PlacementAnnotation(placement: placement))
        isDirty = true
        return placement.id
    }

    @discardableResult
    public func markRedaction(_ rect: CGRect, page index: Int) -> PDFAnnotation? {
        let rect = rect.standardized
        guard let page = document.page(at: index), rect.width > 1, rect.height > 1 else {
            return nil
        }
        let annotation = Self.redactionAnnotation(rect)
        page.addAnnotation(annotation)
        isDirty = true
        return annotation
    }

    @discardableResult
    public func markRedactions(terms: [String], patterns: [PDFRedaction.Pattern]) -> Int {
        let found = PDFRedaction.find(terms: terms, patterns: patterns, in: document)
        var count = 0
        for (index, rects) in found {
            for rect in rects {
                markRedaction(rect, page: index)
                count += 1
            }
        }
        return count
    }

    public func clearRedactions() {
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.userName == Self.redactionMarker {
                page.removeAnnotation(annotation)
            }
        }
        isDirty = true
    }

    public var redactionCount: Int { redactions.values.reduce(0) { $0 + $1.count } }

    public func crop(pages indices: [Int], to rect: CGRect) {
        for index in indices {
            guard let page = document.page(at: index) else { continue }
            let target = rect.intersection(StudioPDF.cropBox(page))
            guard target.width > 8, target.height > 8 else { continue }
            PDFCropping.apply(target, to: page)
        }
        isDirty = true
    }

    public func trimMargins(pages indices: [Int], padding: Double = 12) throws -> Int {
        var trimmed = 0
        for index in indices {
            guard let page = document.page(at: index),
                let content = try PDFCropping.contentRect(of: page)
            else { continue }
            let target = content.insetBy(dx: -padding, dy: -padding).intersection(
                StudioPDF.cropBox(page))
            guard target.width > 8, target.height > 8 else { continue }
            PDFCropping.apply(target, to: page)
            trimmed += 1
        }
        if trimmed > 0 { isDirty = true }
        return trimmed
    }

    public func export(
        to url: URL, flatten: Bool = false, searchableRedactions: Bool = true,
        progress: @escaping (Double) -> Void = { _ in }
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "studio-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let composed = try compose(pages: nil, scratch: scratch) { progress($0 * 0.5) }
        var working = composed.document
        if !composed.marks.isEmpty {
            let stage = scratch.appendingPathComponent("redacted.pdf")
            try await PDFRedaction.apply(
                composed.marks, to: working, fill: .black, searchable: searchableRedactions,
                scrubMetadata: false, output: stage,
                progress: { progress(0.5 + $0 * 0.4) })
            working = try StudioPDF.open(stage)
        }
        try StudioPDF.write(
            working, to: url, options: flatten ? [.burnInAnnotationsOption: true] : [:])
        if flatten { try StudioPDF.restoreLinks(from: working, into: url) }
        progress(1)
        isDirty = false
    }

    static func draw(
        _ image: CGImage, opacity: Double, bounds: CGRect, placedAt rotation: Int,
        on page: PDFPage, in context: CGContext
    ) {
        let frame = bounds.applying(StudioPDF.displayFromPage(page)).standardized
        let turn = ((StudioPDF.rotation(page) - rotation) % 360 + 360) % 360
        let upright =
            turn == 90 || turn == 270
            ? CGSize(width: frame.height, height: frame.width) : frame.size
        context.saveGState()
        context.setAlpha(opacity)
        context.interpolationQuality = .high
        context.translateBy(x: frame.minX, y: frame.minY)
        context.concatenate(StudioPDF.pageFromDisplay(size: upright, rotation: turn).inverted())
        context.draw(image, in: CGRect(origin: .zero, size: upright))
        context.restoreGState()
    }

    func placementID(of annotation: PDFAnnotation) -> UUID? {
        (annotation as? PlacementAnnotation)?.placementID
    }

    static func redactionAnnotation(_ rect: CGRect) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        annotation.userName = redactionMarker
        annotation.color = NSColor.black
        annotation.interiorColor = NSColor.black.withAlphaComponent(0.78)
        let border = PDFBorder()
        border.lineWidth = 1
        annotation.border = border
        return annotation
    }

    struct Markers {
        let entries: [(PDFPage, PDFAnnotation)]
    }

    func removeMarkers() -> Markers {
        var entries: [(PDFPage, PDFAnnotation)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations
            where annotation.userName == Self.redactionMarker || annotation is PlacementAnnotation {
                entries.append((page, annotation))
                page.removeAnnotation(annotation)
            }
        }
        return Markers(entries: entries)
    }

    func restoreMarkers(_ markers: Markers) {
        for (page, annotation) in markers.entries { page.addAnnotation(annotation) }
    }

    func refreshMarkers(redactions: [Int: [CGRect]]) {
        _ = removeMarkers()
        for placement in placements {
            document.page(at: placement.page)?.addAnnotation(
                PlacementAnnotation(placement: placement))
        }
        for (index, rects) in redactions {
            for rect in rects {
                document.page(at: index)?.addAnnotation(Self.redactionAnnotation(rect))
            }
        }
    }

    func remapPages(_ transform: (Int) -> Int) {
        for position in placements.indices {
            placements[position].page = transform(placements[position].page)
        }
    }
}

public final class PlacementAnnotation: PDFAnnotation {
    public let placementID: UUID
    let image: CGImage
    let opacity: Double
    let rotation: Int

    init(placement: PDFEditSession.Placement) {
        placementID = placement.id
        image = placement.image
        opacity = placement.opacity
        rotation = placement.rotation
        super.init(bounds: placement.rect, forType: .stamp, withProperties: nil)
        userName = PDFEditSession.placementMarker
    }

    required init?(coder: NSCoder) { nil }

    public override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let page else { return }
        PDFEditSession.draw(
            image, opacity: opacity, bounds: bounds, placedAt: rotation, on: page, in: context)
    }
}

public enum StudioSignature {
    public static func typed(_ text: String, font: String, color: StudioColor, height: Double = 120)
        -> CGImage?
    {
        let nsFont =
            NSFont(name: font, size: height * 0.62) ?? NSFont.systemFont(ofSize: height * 0.62)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: nsFont, .foregroundColor: NSColor(cgColor: color.cgColor) ?? .black,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let width = Int(ceil(size.width + height * 0.4))
        let pixelHeight = Int(ceil(max(size.height, height) * 1.1))
        guard width > 0, let context = StudioImageOps.context(width: width, height: pixelHeight)
        else {
            return nil
        }
        context.clear(CGRect(x: 0, y: 0, width: width, height: pixelHeight))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(
            at: CGPoint(x: height * 0.2, y: (Double(pixelHeight) - size.height) / 2),
            withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage().flatMap(trimmed)
    }

    public static func drawn(
        _ strokes: [[CGPoint]], canvas: CGSize, color: StudioColor, lineWidth: Double = 3,
        scale: Double = 3
    ) -> CGImage? {
        let width = Int(canvas.width * scale)
        let height = Int(canvas.height * scale)
        guard width > 0, height > 0,
            let context = StudioImageOps.context(width: width, height: height)
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(lineWidth * scale)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes where stroke.count > 1 {
            context.beginPath()
            context.move(
                to: CGPoint(x: stroke[0].x * scale, y: Double(height) - stroke[0].y * scale))
            for point in stroke.dropFirst() {
                context.addLine(
                    to: CGPoint(x: point.x * scale, y: Double(height) - point.y * scale))
            }
            context.strokePath()
        }
        return context.makeImage().flatMap(trimmed)
    }

    public static func cleaned(_ image: CGImage, threshold: Double = 0.82) -> CGImage? {
        guard let context = StudioImageOps.context(width: image.width, height: image.height),
            let data = context.data
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        let limit = UInt8(threshold * 255)
        for row in 0..<image.height {
            for column in 0..<image.width {
                let offset = row * context.bytesPerRow + column * 4
                if bytes[offset] > limit && bytes[offset + 1] > limit && bytes[offset + 2] > limit {
                    bytes[offset] = 0
                    bytes[offset + 1] = 0
                    bytes[offset + 2] = 0
                    bytes[offset + 3] = 0
                }
            }
        }
        return context.makeImage().flatMap(trimmed)
    }

    public static func trimmed(_ image: CGImage) -> CGImage? {
        guard let context = StudioImageOps.context(width: image.width, height: image.height),
            let data = context.data
        else { return image }
        context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * image.height)
        var minX = image.width
        var minY = image.height
        var maxX = -1
        var maxY = -1
        for row in 0..<image.height {
            for column in 0..<image.width
            where bytes[row * context.bytesPerRow + column * 4 + 3] > 8 {
                minX = min(minX, column)
                maxX = max(maxX, column)
                minY = min(minY, row)
                maxY = max(maxY, row)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 6
        let rect = CGRect(
            x: max(0, minX - pad), y: max(0, minY - pad),
            width: min(image.width, maxX + pad + 1) - max(0, minX - pad),
            height: min(image.height, maxY + pad + 1) - max(0, minY - pad))
        return image.cropping(to: rect)
    }
}
