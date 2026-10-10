import AppKit
import CoreGraphics
import Foundation

public struct DocumentPageSetup: Sendable {
    public var paper: CGSize
    public var margins: NSEdgeInsets

    public init(paper: CGSize, margins: NSEdgeInsets) {
        self.paper = paper
        self.margins = margins
    }

    public var content: CGSize {
        CGSize(
            width: max(72, paper.width - margins.left - margins.right),
            height: max(72, paper.height - margins.top - margins.bottom))
    }

    static let paperOption = StudioOption.choice(
        "paper", "Page size",
        [StudioChoice("auto", "From the document")] + StudioPaperSize.choices, default: "auto")
    static let orientationOption = StudioOption.choice(
        "orientation", "Orientation",
        [
            StudioChoice("auto", "Automatic"), StudioChoice("portrait", "Portrait"),
            StudioChoice("landscape", "Landscape"),
        ], default: "auto")
    static let marginOption = StudioOption.choice(
        "margin", "Margins",
        [
            StudioChoice("auto", "From the document"), StudioChoice("36", "Narrow"),
            StudioChoice("72", "Normal"), StudioChoice("108", "Wide"),
        ], default: "auto")

    static func resolve(
        _ settings: StudioSettings, documentPaper: CGSize?, documentMargins: NSEdgeInsets?,
        prefersLandscape: Bool = false
    ) -> DocumentPageSetup {
        let chosen = StudioPaperSize(rawValue: settings.text("paper"))?.points
        var paper = chosen ?? documentPaper ?? StudioPaperSize.a4.points
        let landscape: Bool
        switch settings.text("orientation") {
        case "portrait": landscape = false
        case "landscape": landscape = true
        default:
            landscape =
                chosen == nil && documentPaper != nil
                ? paper.width > paper.height : prefersLandscape
        }
        if landscape != (paper.width > paper.height) {
            paper = CGSize(width: paper.height, height: paper.width)
        }
        let margins: NSEdgeInsets
        if let value = Double(settings.text("margin")) {
            margins = NSEdgeInsets(top: value, left: value, bottom: value, right: value)
        } else if let documentMargins {
            margins = documentMargins
        } else {
            margins = NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)
        }
        return DocumentPageSetup(paper: paper, margins: margins)
    }
}

public struct DocumentSection {
    public var text: NSAttributedString
    public var setup: DocumentPageSetup
    public var header: NSAttributedString?
    public var footer: NSAttributedString?
    public var distinctFirstPage = false
    public var firstHeader: NSAttributedString?
    public var firstFooter: NSAttributedString?
    public var headerDistance: CGFloat = 36
    public var footerDistance: CGFloat = 36

    public init(text: NSAttributedString, setup: DocumentPageSetup) {
        self.text = text
        self.setup = setup
    }
}

public enum TextPaginator {
    public static let fieldKey = NSAttributedString.Key("EdithStudioField")

    @discardableResult
    public static func render(
        _ text: NSAttributedString, setup: DocumentPageSetup, title: String, to url: URL,
        maxPages: Int = 5000, progress: (Double) -> Void = { _ in }
    ) throws -> Int {
        try render(
            [DocumentSection(text: text, setup: setup)], title: title, to: url, maxPages: maxPages,
            progress: progress)
    }

    struct Laid {
        let section: DocumentSection
        let storage: NSTextStorage
        let layout: NSLayoutManager
        let containers: [NSTextContainer]
    }

    @discardableResult
    public static func render(
        _ sections: [DocumentSection], title: String, to url: URL, maxPages: Int = 5000,
        progress: (Double) -> Void = { _ in }
    ) throws -> Int {
        var laid: [Laid] = []
        var total = 0
        for section in sections {
            try Task.checkCancellation()
            let item = try layout(section, maxPages: max(1, maxPages - total))
            total += item.containers.count
            laid.append(item)
        }
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        var page = 0
        for item in laid {
            let setup = item.section.setup
            for (index, container) in item.containers.enumerated() {
                try Task.checkCancellation()
                page += 1
                var box = CGRect(origin: .zero, size: setup.paper)
                context.beginPage(mediaBox: &box)
                context.saveGState()
                context.translateBy(x: 0, y: setup.paper.height)
                context.scaleBy(x: 1, y: -1)
                let graphics = NSGraphicsContext(cgContext: context, flipped: true)
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = graphics
                appearance.performAsCurrentDrawingAppearance {
                    let range = item.layout.glyphRange(for: container)
                    let origin = CGPoint(x: setup.margins.left, y: setup.margins.top)
                    item.layout.drawBackground(forGlyphRange: range, at: origin)
                    item.layout.drawGlyphs(forGlyphRange: range, at: origin)
                    let first = index == 0 && item.section.distinctFirstPage
                    let header = first ? item.section.firstHeader : item.section.header
                    let footer = first ? item.section.firstFooter : item.section.footer
                    if let header {
                        drawMargin(
                            header, page: page, total: total, section: item.section, top: true)
                    }
                    if let footer {
                        drawMargin(
                            footer, page: page, total: total, section: item.section, top: false)
                    }
                }
                NSGraphicsContext.restoreGraphicsState()
                context.restoreGState()
                context.endPage()
                progress(Double(page) / Double(max(total, 1)))
            }
        }
        context.closePDF()
        return page
    }

    static func layout(_ section: DocumentSection, maxPages: Int) throws -> Laid {
        let setup = section.setup
        let storage = NSTextStorage(
            attributedString: normalized(section.text, fitting: setup.content))
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        var emptyStreak = 0
        while containers.count < maxPages {
            try Task.checkCancellation()
            let container = NSTextContainer(size: setup.content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            emptyStreak = range.length == 0 ? emptyStreak + 1 : 0
            if NSMaxRange(range) >= layout.numberOfGlyphs || emptyStreak >= 2 { break }
        }
        if emptyStreak > 0, containers.count > 1 {
            for _ in 0..<min(emptyStreak, containers.count - 1) {
                layout.removeTextContainer(at: containers.count - 1)
                containers.removeLast()
            }
        }
        let laidOut = containers.last.map { NSMaxRange(layout.glyphRange(for: $0)) } ?? 0
        if laidOut < layout.numberOfGlyphs {
            let characters = layout.characterIndexForGlyph(at: laidOut)
            let rest = (storage.string as NSString).substring(from: characters)
            if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw StudioError.failed(
                    containers.count >= maxPages
                        ? "The document is longer than \(maxPages) pages."
                        : "Part of the document does not fit on a page and could not be converted."
                )
            }
        }
        return Laid(section: section, storage: storage, layout: layout, containers: containers)
    }

    static func drawMargin(
        _ text: NSAttributedString, page: Int, total: Int, section: DocumentSection, top: Bool
    ) {
        let filled = NSMutableAttributedString(attributedString: normalized(text, fitting: nil))
        var replacements: [(NSRange, String)] = []
        filled.enumerateAttribute(
            fieldKey, in: NSRange(location: 0, length: filled.length)
        ) { value, range, _ in
            guard let field = value as? String else { return }
            replacements.append((range, field == "NUMPAGES" ? "\(total)" : "\(page)"))
        }
        for (range, value) in replacements.reversed() {
            filled.replaceCharacters(in: range, with: value)
        }
        let setup = section.setup
        let width = setup.content.width
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let height = ceil(
            filled.boundingRect(with: CGSize(width: width, height: 10_000), options: options)
                .height)
        let y =
            top
            ? max(0, section.headerDistance)
            : setup.paper.height - max(0, section.footerDistance) - height
        filled.draw(
            with: CGRect(x: setup.margins.left, y: y, width: width, height: height + 2),
            options: options)
    }

    static func normalized(_ text: NSAttributedString, fitting content: CGSize?)
        -> NSAttributedString
    {
        let copy = NSMutableAttributedString(attributedString: text)
        let whole = NSRange(location: 0, length: copy.length)
        copy.enumerateAttribute(.foregroundColor, in: whole) { value, range, _ in
            guard let color = value as? NSColor else {
                copy.addAttribute(.foregroundColor, value: NSColor.black, range: range)
                return
            }
            if color.type == .catalog || color == NSColor.textColor || color == NSColor.labelColor {
                copy.addAttribute(.foregroundColor, value: NSColor.black, range: range)
            }
        }
        copy.enumerateAttribute(.link, in: whole) { value, range, _ in
            guard value != nil else { return }
            copy.addAttribute(
                .foregroundColor, value: NSColor(srgbRed: 0.05, green: 0.36, blue: 0.8, alpha: 1),
                range: range)
            copy.addAttribute(
                .underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
        }
        copy.enumerateAttribute(.font, in: whole) { value, range, _ in
            if value == nil {
                copy.addAttribute(.font, value: NSFont.systemFont(ofSize: 11), range: range)
            }
        }
        if let content {
            copy.enumerateAttribute(.attachment, in: whole) { value, _, _ in
                guard let attachment = value as? NSTextAttachment else { return }
                var size = attachment.bounds.size
                if size.width <= 0 || size.height <= 0 {
                    size = attachment.image?.size ?? .zero
                }
                guard size.width > 0, size.height > 0 else { return }
                let scale = min(
                    1, content.width / size.width, (content.height - 24) / size.height)
                if scale < 1 || attachment.bounds.size == .zero {
                    attachment.bounds = CGRect(
                        x: 0, y: 0, width: floor(size.width * scale),
                        height: floor(size.height * scale))
                }
            }
        }
        return copy
    }
}
