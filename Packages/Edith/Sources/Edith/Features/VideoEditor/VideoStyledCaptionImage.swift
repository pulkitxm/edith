import AppKit
import CoreImage
import CoreText

enum VideoStyledCaptionImage {
    struct Line {
        let text: CTLine
        let baseline: CGPoint
    }

    static func rect(_ text: String, style: VideoCaptionStyle) throws -> CGRect {
        let lines = try layout(text, style: style)
        let font = try style.font()
        let height =
            CTFontGetAscent(font) + CTFontGetDescent(font)
            + Double(max(0, lines.count - 1)) * style.lineAdvance
        return CGRect(
            x: (style.x
                - (style.alignment == .center
                    ? style.width / 2 : style.alignment == .right ? style.width : 0))
                / style.canvasWidth,
            y: (style.y
                - (style.anchor == .center ? height / 2 : style.anchor == .bottom ? height : 0))
                / style.canvasHeight,
            width: style.width / style.canvasWidth, height: height / style.canvasHeight)
    }

    static func layout(_ text: String, style: VideoCaptionStyle) throws -> [Line] {
        try style.validate()
        let font = try style.font()
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
        ]
        var lines: [CTLine] = []
        for paragraph in text.components(separatedBy: "\n") {
            let attributed = NSAttributedString(string: paragraph, attributes: attributes)
            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            if attributed.length == 0 { lines.append(CTLineCreateWithAttributedString(attributed)) }
            var offset = 0
            while offset < attributed.length {
                let length = CTTypesetterSuggestLineBreak(typesetter, offset, style.width)
                try VideoCaptionStyle.require(length > 0, "Caption width cannot fit a glyph.")
                lines.append(
                    CTTypesetterCreateLine(typesetter, CFRange(location: offset, length: length)))
                offset += length
            }
        }
        let ascent = CTFontGetAscent(font)
        let height =
            ascent + CTFontGetDescent(font) + Double(max(0, lines.count - 1)) * style.lineAdvance
        let left =
            style.x
            - (style.alignment == .center
                ? style.width / 2 : style.alignment == .right ? style.width : 0)
        let top =
            style.y - (style.anchor == .center ? height / 2 : style.anchor == .bottom ? height : 0)
        try VideoCaptionStyle.require(
            left >= 0 && left + style.width <= style.canvasWidth && top >= 0
                && top + height <= style.canvasHeight,
            "Caption layout exceeds the reference canvas; adjust position, width, size or line advance."
        )
        return try lines.enumerated().map { index, line in
            let width =
                CTLineGetTypographicBounds(line, nil, nil, nil)
                - CTLineGetTrailingWhitespaceWidth(line)
            try VideoCaptionStyle.require(
                width <= style.width + 0.01, "Caption width cannot fit a glyph.")
            let x =
                left
                + (style.alignment == .center
                    ? (style.width - width) / 2
                    : style.alignment == .right ? style.width - width : 0)
            return Line(
                text: line,
                baseline: CGPoint(
                    x: x, y: style.canvasHeight - top - ascent - Double(index) * style.lineAdvance))
        }
    }

    static func make(_ annotation: VideoProject.Annotation, style: VideoCaptionStyle, size: CGSize)
        -> CIImage?
    {
        guard let lines = try? layout(annotation.text, style: style),
            let context = CGContext(
                data: nil, width: Int(size.width), height: Int(size.height),
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: size.width / style.canvasWidth, y: size.height / style.canvasHeight)
        if let gradient = style.gradient,
            let ramp = CGGradient(
                colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                colors: gradient.stops.map { $0.color.cgColor } as CFArray,
                locations: gradient.stops.map { CGFloat($0.location) })
        {
            context.drawLinearGradient(
                ramp,
                start: CGPoint(x: 0, y: style.canvasHeight - gradient.startY),
                end: CGPoint(x: 0, y: style.canvasHeight - gradient.endY),
                options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let bounds = CGRect(origin: .zero, size: size)
        let referenceBounds = CGRect(
            x: 0, y: 0, width: style.canvasWidth, height: style.canvasHeight)
        guard let background = context.makeImage() else { return nil }
        var backdrop = CIImage(cgImage: background)
        context.clear(referenceBounds)
        if let shadow = style.shadow {
            context.saveGState()
            context.setAlpha(shadow.color.alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            let color = shadow.color.cgColor.copy(alpha: 1)!
            draw(lines, context: context, stroke: shadow.strokeWidth, color: color)
            draw(lines, context: context, stroke: 0, color: color)
            context.endTransparencyLayer()
            context.restoreGState()
            if let raster = context.makeImage() {
                let scaleX = size.width / style.canvasWidth
                let scaleY = size.height / style.canvasHeight
                let shade = CIImage(cgImage: raster)
                    .transformed(by: CGAffineTransform(scaleX: 1 / scaleX, y: 1 / scaleY))
                    .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: shadow.blur])
                    .transformed(by: CGAffineTransform(translationX: shadow.x, y: -shadow.y))
                    .transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                backdrop = shade.composited(over: backdrop).cropped(to: bounds)
            }
            context.clear(referenceBounds)
        }
        if let outline = style.outline, outline.width > 0 {
            draw(lines, context: context, stroke: outline.width, color: outline.color.cgColor)
        }
        draw(lines, context: context, stroke: 0, color: style.fill.cgColor)
        return context.makeImage().map {
            CIImage(cgImage: $0).composited(over: backdrop).cropped(to: bounds)
        }
    }

    private static func draw(_ lines: [Line], context: CGContext, stroke: Double, color: CGColor) {
        context.setTextDrawingMode(stroke > 0 ? .stroke : .fill)
        context.setLineWidth(stroke * 2)
        context.setLineJoin(.round)
        context.setStrokeColor(color)
        context.setFillColor(color)
        for line in lines {
            context.textPosition = line.baseline
            CTLineDraw(line.text, context)
        }
    }
}
