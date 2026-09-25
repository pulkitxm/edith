import AppKit
import CoreGraphics
import CoreText
import Foundation

public struct StudioStamp {
    public enum Content {
        case text(String, font: String, color: StudioColor, bold: Bool)
        case image(CGImage)
    }

    public var content: Content
    public var anchor: StudioAnchor
    public var opacity: Double
    public var rotation: Double
    public var relativeSize: Double
    public var margin: Double

    public init(
        content: Content, anchor: StudioAnchor, opacity: Double, rotation: Double,
        relativeSize: Double, margin: Double
    ) {
        self.content = content
        self.anchor = anchor
        self.opacity = opacity
        self.rotation = rotation
        self.relativeSize = relativeSize
        self.margin = margin
    }

    public static func options(textDefault: String) -> [StudioOption] {
        [
            .choice(
                "kind", "Watermark",
                [StudioChoice("text", "Text"), StudioChoice("image", "Image")], default: "text"),
            .text(
                "text", "Text", placeholder: "CONFIDENTIAL", default: textDefault,
                when: .init("kind", ["text"]), required: true),
            .font(when: .init("kind", ["text"])),
            .toggle("bold", "Bold", default: true, when: .init("kind", ["text"])),
            .color("color", "Color", default: "#D0021B", when: .init("kind", ["text"])),
            .file(
                "image", "Image", kinds: [.image], when: .init("kind", ["image"]), required: true),
            .anchor(default: .center, includeTiled: true),
            .percent("size", "Size", 0.05...1, default: 0.4, help: "Relative to the page width."),
            .percent("opacity", "Opacity", 0.05...1, default: 0.35),
            .number("rotation", "Rotation", -180...180, step: 5, default: -30, unit: "°"),
        ]
    }

    public static func from(_ settings: StudioSettings) throws -> StudioStamp {
        let content: Content
        if settings.text("kind") == "image" {
            guard let url = settings.file("image") else {
                throw StudioError.invalidOption("image", "choose an image")
            }
            content = .image(try StudioImageIO.load(url, maxPixelSize: 2400))
        } else {
            let text = settings.trimmed("text")
            guard !text.isEmpty else { throw StudioError.invalidOption("text", "enter the text") }
            content = .text(
                text, font: settings.text("font"), color: settings.color("color"),
                bold: settings.bool("bold"))
        }
        return StudioStamp(
            content: content, anchor: settings.anchor(), opacity: settings.number("opacity"),
            rotation: settings.number("rotation"), relativeSize: settings.number("size"),
            margin: 0.04)
    }

    public func draw(in context: CGContext, size canvas: CGSize, flipped: Bool = false) {
        let width = max(8, canvas.width * relativeSize)
        let rendered = renderedSize(width: width)
        guard rendered.width > 0, rendered.height > 0 else { return }
        context.saveGState()
        context.setAlpha(opacity)
        let margin = min(canvas.width, canvas.height) * self.margin
        if anchor == .tiled {
            let stepX = rendered.width * 1.6
            let stepY = max(rendered.height * 3, rendered.width * 0.6)
            var row = 0
            var y = -canvas.height * 0.2
            while y < canvas.height * 1.2 {
                var x = -canvas.width * 0.2 + (row % 2 == 0 ? 0 : stepX / 2)
                while x < canvas.width * 1.2 {
                    drawOne(
                        in: context, center: CGPoint(x: x, y: y), size: rendered, flipped: flipped)
                    x += stepX
                }
                y += stepY
                row += 1
            }
        } else {
            let bounds = CGRect(origin: .zero, size: canvas)
            let rotatedBox = CGRect(origin: .zero, size: rendered).applying(
                CGAffineTransform(rotationAngle: rotation * .pi / 180))
            let placed = anchor.place(rotatedBox.size, in: bounds, margin: margin)
            let y = flipped ? placed.midY : canvas.height - placed.midY
            drawOne(
                in: context, center: CGPoint(x: placed.midX, y: y), size: rendered, flipped: flipped
            )
        }
        context.restoreGState()
    }

    func renderedSize(width: CGFloat) -> CGSize {
        switch content {
        case let .image(image):
            return CGSize(
                width: width, height: width * CGFloat(image.height) / CGFloat(max(image.width, 1)))
        case let .text(text, font, _, bold):
            let line = Self.line(text, font: font, size: 100, bold: bold, color: .black)
            let bounds = CTLineGetImageBounds(line, nil)
            let typographic = CTLineGetTypographicBounds(line, nil, nil, nil)
            let natural = max(CGFloat(typographic), bounds.width, 1)
            let scale = width / natural
            return CGSize(width: width, height: 100 * scale * 1.2)
        }
    }

    func drawOne(in context: CGContext, center: CGPoint, size: CGSize, flipped: Bool) {
        context.saveGState()
        context.translateBy(x: center.x, y: center.y)
        let angle = rotation * .pi / 180
        context.rotate(by: flipped ? angle : -angle)
        if flipped { context.scaleBy(x: 1, y: -1) }
        switch content {
        case let .image(image):
            context.interpolationQuality = .high
            context.draw(
                image,
                in: CGRect(
                    x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
            )
        case let .text(text, font, color, bold):
            let fontSize = size.height / 1.2
            let line = Self.line(text, font: font, size: fontSize, bold: bold, color: color)
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: -width / 2, y: -fontSize * 0.33)
            CTLineDraw(line, context)
        }
        context.restoreGState()
    }

    public static func font(named name: String, size: CGFloat, bold: Bool) -> CTFont {
        let base = NSFont(name: name, size: size) ?? NSFont.systemFont(ofSize: size)
        guard bold else { return base as CTFont }
        return NSFontManager.shared.convert(base, toHaveTrait: .boldFontMask) as CTFont
    }

    static func line(_ text: String, font: String, size: CGFloat, bold: Bool, color: StudioColor)
        -> CTLine
    {
        let attributed = NSAttributedString(
            string: text,
            attributes: [
                .font: Self.font(named: font, size: size, bold: bold),
                .foregroundColor: color.cgColor,
            ])
        return CTLineCreateWithAttributedString(attributed)
    }
}

public enum StudioText {
    public static func draw(
        _ text: String, in rect: CGRect, context: CGContext, font: CTFont, color: StudioColor,
        alignment: NSTextAlignment = .center, stroke: StudioColor? = nil, strokeWidth: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: color.cgColor, .paragraphStyle: paragraph,
        ]
        if let stroke, strokeWidth > 0 {
            attributes[.strokeColor] = stroke.cgColor
            attributes[.strokeWidth] = -strokeWidth
        }
        let attributed = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: rect, transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter, CFRange(location: 0, length: 0), path, nil)
        context.saveGState()
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    public static func fittingSize(
        _ text: String, font: CTFont, width: CGFloat
    ) -> CGSize {
        let attributed = NSAttributedString(string: text, attributes: [.font: font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        return CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(location: 0, length: 0), nil,
            CGSize(width: width, height: .greatestFiniteMagnitude), nil)
    }
}
