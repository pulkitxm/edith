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

public enum TextPaginator {
    @discardableResult
    public static func render(
        _ text: NSAttributedString, setup: DocumentPageSetup, title: String, to url: URL,
        maxPages: Int = 5000, progress: (Double) -> Void = { _ in }
    ) throws -> Int {
        let storage = NSTextStorage(attributedString: normalized(text))
        let layout = NSLayoutManager()
        layout.usesFontLeading = true
        storage.addLayoutManager(layout)
        var containers: [NSTextContainer] = []
        let glyphCount = { layout.numberOfGlyphs }
        var emptyStreak = 0
        while containers.count < maxPages {
            try Task.checkCancellation()
            let container = NSTextContainer(size: setup.content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            emptyStreak = range.length == 0 ? emptyStreak + 1 : 0
            if NSMaxRange(range) >= glyphCount() || emptyStreak >= 2 { break }
        }
        if emptyStreak > 0, containers.count > 1 {
            for _ in 0..<min(emptyStreak, containers.count - 1) {
                layout.removeTextContainer(at: containers.count - 1)
                containers.removeLast()
            }
        }
        var box = CGRect(origin: .zero, size: setup.paper)
        let info: [CFString: Any] = [
            kCGPDFContextTitle: title, kCGPDFContextCreator: "Edith Studio",
        ]
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        let appearance = NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        for (index, container) in containers.enumerated() {
            try Task.checkCancellation()
            context.beginPage(mediaBox: &box)
            context.saveGState()
            context.translateBy(x: 0, y: setup.paper.height)
            context.scaleBy(x: 1, y: -1)
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            appearance.performAsCurrentDrawingAppearance {
                let range = layout.glyphRange(for: container)
                let origin = CGPoint(x: setup.margins.left, y: setup.margins.top)
                layout.drawBackground(forGlyphRange: range, at: origin)
                layout.drawGlyphs(forGlyphRange: range, at: origin)
            }
            NSGraphicsContext.restoreGraphicsState()
            context.restoreGState()
            context.endPage()
            progress(Double(index + 1) / Double(containers.count))
        }
        context.closePDF()
        return containers.count
    }

    static func normalized(_ text: NSAttributedString) -> NSAttributedString {
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
        return copy
    }
}
