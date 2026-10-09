import CoreGraphics
import CoreText
import CoreVideo
import Foundation

public enum VirtualCameraPlaceholder {
    public struct Card: Equatable, Sendable {
        public let title: String
        public let detail: String

        public init(title: String, detail: String) {
            self.title = title
            self.detail = detail
        }
    }

    public static func card(for feed: VirtualCameraRelay.Feed) -> Card {
        switch feed {
        case .offline:
            Card(
                title: "Edith Camera is off",
                detail: "Turn on Virtual Camera in Edith to send your camera here.")
        case .starting:
            Card(title: "Starting your camera", detail: "Edith is getting the picture ready.")
        case .stalled:
            Card(
                title: "Camera paused",
                detail: "Edith stopped sending frames. The picture returns on its own.")
        case .live:
            Card(title: "", detail: "")
        }
    }

    public static func makeBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &buffer)
        return status == kCVReturnSuccess ? buffer : nil
    }

    @discardableResult
    public static func render(_ card: Card, into buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA else {
            return false
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard
            let context = CGContext(
                data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return false }
        draw(card, in: context, size: CGSize(width: width, height: height))
        return true
    }

    static func draw(_ card: Card, in context: CGContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        let top = CGColor(srgbRed: 0.13, green: 0.13, blue: 0.16, alpha: 1)
        let bottom = CGColor(srgbRed: 0.04, green: 0.04, blue: 0.05, alpha: 1)
        if let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [top, bottom] as CFArray, locations: [0, 1])
        {
            context.drawLinearGradient(
                gradient, start: CGPoint(x: 0, y: size.height), end: .zero, options: [])
        } else {
            context.setFillColor(bottom)
            context.fill(bounds)
        }
        let unit = size.height / 1080
        let center = CGPoint(x: size.width / 2, y: size.height * 0.56)
        drawCameraGlyph(in: context, center: center, unit: unit)
        drawLine(
            card.title, in: context, size: 54 * unit, weight: .semibold,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.95),
            centerX: size.width / 2, baseline: size.height * 0.40)
        drawLine(
            card.detail, in: context, size: 30 * unit, weight: .regular,
            color: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.6),
            centerX: size.width / 2, baseline: size.height * 0.40 - 56 * unit)
    }

    static func drawCameraGlyph(in context: CGContext, center: CGPoint, unit: CGFloat) {
        let body = CGRect(
            x: center.x - 120 * unit, y: center.y - 70 * unit, width: 170 * unit,
            height: 140 * unit)
        let color = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85)
        context.setFillColor(color)
        context.addPath(
            CGPath(
                roundedRect: body, cornerWidth: 28 * unit, cornerHeight: 28 * unit,
                transform: nil))
        context.fillPath()
        context.beginPath()
        context.move(to: CGPoint(x: body.maxX + 14 * unit, y: center.y))
        context.addLine(to: CGPoint(x: body.maxX + 80 * unit, y: center.y + 52 * unit))
        context.addLine(to: CGPoint(x: body.maxX + 80 * unit, y: center.y - 52 * unit))
        context.closePath()
        context.fillPath()
        context.setFillColor(CGColor(srgbRed: 0.08, green: 0.08, blue: 0.1, alpha: 1))
        context.fillEllipse(
            in: CGRect(
                x: body.midX - 38 * unit, y: body.midY - 38 * unit, width: 76 * unit,
                height: 76 * unit))
    }

    enum Weight {
        case regular
        case semibold
    }

    static func drawLine(
        _ text: String, in context: CGContext, size: CGFloat, weight: Weight, color: CGColor,
        centerX: CGFloat, baseline: CGFloat
    ) {
        guard !text.isEmpty else { return }
        let base =
            CTFontCreateUIFontForLanguage(.system, size, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let font =
            weight == .semibold
            ? CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitBold, .traitBold) ?? base
            : base
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: centerX - CGFloat(width) / 2, y: baseline)
        CTLineDraw(line, context)
    }
}
