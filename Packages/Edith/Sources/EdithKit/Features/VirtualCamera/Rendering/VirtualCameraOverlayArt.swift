import CoreGraphics
import CoreImage
import CoreText
import Foundation

final class VirtualCameraOverlayArt: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: CIImage] = [:]
    private var order: [String] = []
    private let capacity = 24

    func nameTag(_ tag: VirtualCameraNameTag, outputHeight: CGFloat) -> CIImage? {
        guard tag.isVisible else { return nil }
        let key = "tag|\(tag.title)|\(tag.subtitle)|\(tag.style)|\(tag.accent.hex)|\(outputHeight)"
        return cached(key) { Self.drawNameTag(tag, outputHeight: outputHeight) }
    }

    func clock(_ text: String, outputHeight: CGFloat) -> CIImage? {
        cached("clock|\(text)|\(outputHeight)") {
            Self.drawPill(text: text, outputHeight: outputHeight)
        }
    }

    func card(message: String, size: CGSize) -> CIImage? {
        cached("card|\(message)|\(size.width)x\(size.height)") {
            Self.drawCard(message: message, size: size)
        }
    }

    private func cached(_ key: String, make: () -> CGImage?) -> CIImage? {
        lock.lock()
        if let hit = cache[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        guard let image = make() else { return nil }
        let result = CIImage(cgImage: image)
        lock.lock()
        cache[key] = result
        order.append(key)
        while order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        lock.unlock()
        return result
    }

    static func font(size: CGFloat, bold: Bool) -> CTFont {
        let base =
            CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        guard bold else { return base }
        return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
    }

    static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
    }

    static func width(of line: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    static func context(size: CGSize) -> CGContext? {
        let width = max(Int(size.width.rounded(.up)), 1)
        let height = max(Int(size.height.rounded(.up)), 1)
        return CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func drawNameTag(_ tag: VirtualCameraNameTag, outputHeight: CGFloat) -> CGImage? {
        let unit = outputHeight / 1080
        let title = tag.title.trimmingCharacters(in: .whitespaces)
        let subtitle = tag.subtitle.trimmingCharacters(in: .whitespaces)
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        let soft = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.74)
        let titleLine =
            title.isEmpty ? nil : line(title, font: font(size: 40 * unit, bold: true), color: white)
        let subtitleLine =
            subtitle.isEmpty
            ? nil : line(subtitle, font: font(size: 28 * unit, bold: false), color: soft)
        let textWidth = max(titleLine.map(width) ?? 0, subtitleLine.map(width) ?? 0)
        let padding = 22 * unit
        let strip = tag.style == .bar ? 8 * unit : 0
        let lines = (titleLine == nil ? 0 : 1) + (subtitleLine == nil ? 0 : 1)
        let height =
            padding * 2 + CGFloat(lines) * 40 * unit + CGFloat(max(lines - 1, 0)) * 6 * unit
        let size = CGSize(
            width: textWidth + padding * 2 + strip + (strip > 0 ? 6 * unit : 0), height: height)
        guard let context = context(size: size) else { return nil }
        let bounds = CGRect(origin: .zero, size: size)
        switch tag.style {
        case .bar:
            context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.72))
            context.addPath(
                CGPath(
                    roundedRect: bounds, cornerWidth: 10 * unit, cornerHeight: 10 * unit,
                    transform: nil))
            context.fillPath()
            context.setFillColor(tag.accent.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: strip, height: size.height))
        case .pill:
            context.setFillColor(tag.accent.cgColor)
            let radius = min(size.height / 2, 40 * unit)
            context.addPath(
                CGPath(
                    roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.fillPath()
        case .minimal:
            context.setShadow(
                offset: CGSize(width: 0, height: -2 * unit), blur: 10 * unit,
                color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.7))
        }
        let textX = padding + strip + (strip > 0 ? 6 * unit : 0)
        var baseline = size.height - padding - 32 * unit
        if let titleLine {
            context.textPosition = CGPoint(x: textX, y: baseline)
            CTLineDraw(titleLine, context)
            baseline -= 46 * unit
        }
        if let subtitleLine {
            context.textPosition = CGPoint(
                x: textX, y: baseline + (titleLine == nil ? 0 : 4 * unit))
            CTLineDraw(subtitleLine, context)
        }
        return context.makeImage()
    }

    static func drawPill(text: String, outputHeight: CGFloat) -> CGImage? {
        let unit = outputHeight / 1080
        let textLine = line(
            text, font: font(size: 30 * unit, bold: true),
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95))
        let padding = 18 * unit
        let size = CGSize(width: width(of: textLine) + padding * 2, height: 56 * unit)
        guard let context = context(size: size) else { return nil }
        context.setFillColor(CGColor(srgbRed: 0.05, green: 0.05, blue: 0.07, alpha: 0.6))
        let radius = size.height / 2
        context.addPath(
            CGPath(
                roundedRect: CGRect(origin: .zero, size: size), cornerWidth: radius,
                cornerHeight: radius, transform: nil))
        context.fillPath()
        context.textPosition = CGPoint(x: padding, y: size.height / 2 - 10 * unit)
        CTLineDraw(textLine, context)
        return context.makeImage()
    }

    static func drawCard(message: String, size: CGSize) -> CGImage? {
        guard let context = context(size: size) else { return nil }
        let unit = size.height / 1080
        let panel = CGRect(
            x: size.width / 2 - 420 * unit, y: size.height / 2 - 120 * unit, width: 840 * unit,
            height: 240 * unit)
        context.setFillColor(CGColor(srgbRed: 0.04, green: 0.04, blue: 0.06, alpha: 0.72))
        context.addPath(
            CGPath(
                roundedRect: panel, cornerWidth: 36 * unit, cornerHeight: 36 * unit, transform: nil)
        )
        context.fillPath()
        let title = line(
            message, font: font(size: 64 * unit, bold: true),
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.96))
        context.textPosition = CGPoint(
            x: size.width / 2 - width(of: title) / 2, y: panel.midY - 4 * unit)
        CTLineDraw(title, context)
        let detail = line(
            "Camera paused", font: font(size: 30 * unit, bold: false),
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6))
        context.textPosition = CGPoint(
            x: size.width / 2 - width(of: detail) / 2, y: panel.midY - 64 * unit)
        CTLineDraw(detail, context)
        return context.makeImage()
    }
}
