import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

public enum ImageEditRenderer {
    public static func loadSource(_ document: ImageEditDocument) throws -> CGImage {
        try StudioImageIO.load(document.sourceURL)
    }

    public static func render(document: ImageEditDocument, maxPixelSize: Int? = nil) throws
        -> CGImage
    {
        try render(document: document, source: loadSource(document), maxPixelSize: maxPixelSize)
    }

    public static func render(
        document: ImageEditDocument, source: CGImage, maxPixelSize: Int? = nil
    ) throws -> CGImage {
        let scaled = previewSource(document: document, source: source, maxPixelSize: maxPixelSize)
        let geometry = try geometryImage(document: document, source: scaled)
        guard let cropped = StudioImageOps.cropped(geometry, to: document.crop.clamped) else {
            throw StudioError.failed("The crop area is empty.")
        }
        var working = CIImage(cgImage: cropped)
        working = adjust(
            working, adjustments: document.adjustments, filter: document.filter,
            intensity: document.filterIntensity)
        let size = CGSize(width: cropped.width, height: cropped.height)
        for layer in document.layers where layer.isRedaction && !layer.isHidden {
            if case let .redaction(style) = layer.content {
                working = redact(working, rect: layer.frame, style: style, canvas: size)
            }
        }
        guard
            let adjusted = StudioImageOps.render(working, extent: CGRect(origin: .zero, size: size))
        else { throw StudioError.failed("The image could not be rendered.") }
        var composed = try drawLayers(
            document.layers.filter { !$0.isRedaction && !$0.isHidden }, over: adjusted)
        if let frame = document.frame {
            composed = applyFrame(frame, to: composed) ?? composed
        }
        if let maximum = document.export.maxDimension, maximum > 0 {
            composed = StudioImageOps.fitted(composed, maxDimension: maximum)
        }
        if let maxPixelSize, maxPixelSize > 0 {
            composed = StudioImageOps.fitted(composed, maxDimension: maxPixelSize)
        }
        return composed
    }

    public static func geometryPreview(
        document: ImageEditDocument, source: CGImage, maxPixelSize: Int? = nil
    ) throws -> CGImage {
        var full = document
        full.crop = .full
        let scaled = previewSource(document: full, source: source, maxPixelSize: maxPixelSize)
        let geometry = try geometryImage(document: document, source: scaled)
        let adjusted = adjust(
            CIImage(cgImage: geometry), adjustments: document.adjustments,
            filter: document.filter, intensity: document.filterIntensity)
        return StudioImageOps.render(
            adjusted, extent: CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
            ?? geometry
    }

    public static func export(document: ImageEditDocument, to url: URL) throws {
        let image = try render(document: document)
        let format = StudioImageFormat.of(url) ?? document.outputFormat
        try StudioImageIO.write(
            image, to: url, format: format, options: .init(quality: document.export.quality))
    }

    static func previewSource(
        document: ImageEditDocument, source: CGImage, maxPixelSize: Int?
    ) -> CGImage {
        guard let maxPixelSize, maxPixelSize > 0 else { return source }
        let sourceSize = CGSize(width: source.width, height: source.height)
        let canvas = document.canvasSize(for: sourceSize)
        let longest = max(canvas.width, canvas.height)
        guard longest > CGFloat(maxPixelSize) else { return source }
        let scale = CGFloat(maxPixelSize) / longest
        let target = Int((CGFloat(max(source.width, source.height)) * scale).rounded())
        return StudioImageOps.fitted(source, maxDimension: max(target, 1))
    }

    public static func geometryImage(document: ImageEditDocument, source: CGImage) throws
        -> CGImage
    {
        var image = source
        if document.quarterTurns % 4 != 0 {
            guard let turned = StudioImageOps.rotated(image, quarterTurns: document.quarterTurns)
            else { throw StudioError.failed("The image could not be rotated.") }
            image = turned
        }
        if document.flipHorizontal || document.flipVertical {
            guard
                let flipped = StudioImageOps.flipped(
                    image, horizontal: document.flipHorizontal, vertical: document.flipVertical)
            else { throw StudioError.failed("The image could not be flipped.") }
            image = flipped
        }
        if abs(document.straighten) > 0.01 {
            image = try straightened(image, degrees: document.straighten)
        }
        return image
    }

    public static func straightened(_ image: CGImage, degrees: Double) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        let scale = ImageEditGeometry.straightenScale(size: size, degrees: degrees)
        let input = CIImage(cgImage: image).clampedToExtent()
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let transform = CGAffineTransform(translationX: center.x, y: center.y)
            .rotated(by: -degrees * .pi / 180)
            .translatedBy(x: -center.x, y: -center.y)
        let rotated = input.transformed(by: transform)
        let width = (size.width * scale).rounded()
        let height = (size.height * scale).rounded()
        let rect = CGRect(
            x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
        let cropped = rotated.cropped(to: rect).transformed(
            by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        guard
            let result = StudioImageOps.render(
                cropped, extent: CGRect(origin: .zero, size: rect.size))
        else { throw StudioError.failed("The image could not be straightened.") }
        return result
    }

    public static func adjust(
        _ image: CGImage, adjustments: ImageAdjustments, filter: ImageFilterPreset,
        intensity: Double = 1
    ) throws -> CGImage {
        let output = adjust(
            CIImage(cgImage: image), adjustments: adjustments, filter: filter, intensity: intensity)
        guard
            let rendered = StudioImageOps.render(
                output, extent: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        else { throw StudioError.failed("The adjustments could not be applied.") }
        return rendered
    }

    static func adjust(
        _ input: CIImage, adjustments: ImageAdjustments, filter: ImageFilterPreset,
        intensity: Double
    ) -> CIImage {
        let extent = input.extent
        var image = input
        if abs(adjustments.exposure) > 0.001 {
            let exposure = CIFilter.exposureAdjust()
            exposure.inputImage = image
            exposure.ev = Float(adjustments.exposure * 2)
            image = exposure.outputImage ?? image
        }
        if abs(adjustments.brightness) > 0.001 || abs(adjustments.contrast) > 0.001
            || abs(adjustments.saturation) > 0.001
        {
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.brightness = Float(adjustments.brightness * 0.25)
            controls.contrast = Float(1 + adjustments.contrast * 0.5)
            controls.saturation = Float(1 + adjustments.saturation)
            image = controls.outputImage ?? image
        }
        if abs(adjustments.vibrance) > 0.001 {
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = image
            vibrance.amount = Float(adjustments.vibrance)
            image = vibrance.outputImage ?? image
        }
        if abs(adjustments.warmth) > 0.001 || abs(adjustments.tint) > 0.001 {
            image = temperature(image, warmth: adjustments.warmth, tint: adjustments.tint)
        }
        if adjustments.highlights < -0.001 || abs(adjustments.shadows) > 0.001 {
            let tones = CIFilter.highlightShadowAdjust()
            tones.inputImage = image
            tones.highlightAmount = Float(1 + min(adjustments.highlights, 0) * 0.8)
            tones.shadowAmount = Float(adjustments.shadows)
            image = tones.outputImage ?? image
        }
        if adjustments.highlights > 0.001 {
            let curve = CIFilter.toneCurve()
            curve.inputImage = image
            let lift = CGFloat(adjustments.highlights * 0.12)
            curve.point0 = CGPoint(x: 0, y: 0)
            curve.point1 = CGPoint(x: 0.25, y: 0.25)
            curve.point2 = CGPoint(x: 0.5, y: 0.5 + lift * 0.4)
            curve.point3 = CGPoint(x: 0.75, y: min(0.75 + lift, 0.98))
            curve.point4 = CGPoint(x: 1, y: 1)
            image = curve.outputImage ?? image
        }
        if adjustments.sharpness > 0.001 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = image
            sharpen.sharpness = Float(adjustments.sharpness * 1.2)
            sharpen.radius = 1.6
            image = sharpen.outputImage ?? image
        }
        image = applyPreset(filter, to: image, intensity: intensity)
        if adjustments.vignette > 0.001 {
            let vignette = CIFilter.vignette()
            vignette.inputImage = image
            vignette.intensity = Float(adjustments.vignette * 1.6)
            vignette.radius = 1.6
            image = vignette.outputImage ?? image
        }
        if adjustments.grain > 0.001 {
            image = grain(image, amount: adjustments.grain, extent: extent)
        }
        return image.cropped(to: extent)
    }

    static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        let filter = CIFilter.temperatureAndTint()
        filter.inputImage = image
        filter.neutral = CIVector(x: 6500, y: 0)
        filter.targetNeutral = CIVector(x: 6500 - warmth * 2600, y: tint * 60)
        return filter.outputImage ?? image
    }

    static func applyPreset(_ preset: ImageFilterPreset, to image: CIImage, intensity: Double)
        -> CIImage
    {
        let filtered: CIImage?
        switch preset {
        case .none:
            return image
        case .mono: filtered = named("CIPhotoEffectMono", image)
        case .noir: filtered = named("CIPhotoEffectNoir", image)
        case .chrome: filtered = named("CIPhotoEffectChrome", image)
        case .fade: filtered = named("CIPhotoEffectFade", image)
        case .instant: filtered = named("CIPhotoEffectInstant", image)
        case .process: filtered = named("CIPhotoEffectProcess", image)
        case .tonal: filtered = named("CIPhotoEffectTonal", image)
        case .transfer: filtered = named("CIPhotoEffectTransfer", image)
        case .sepia:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.9
            filtered = sepia.outputImage
        case .vivid:
            let controls = CIFilter.colorControls()
            controls.inputImage = image
            controls.saturation = 1.35
            controls.contrast = 1.08
            let vibrance = CIFilter.vibrance()
            vibrance.inputImage = controls.outputImage
            vibrance.amount = 0.4
            filtered = vibrance.outputImage
        case .warm:
            filtered = temperature(image, warmth: 0.6, tint: 0.1)
        case .cool:
            filtered = temperature(image, warmth: -0.6, tint: -0.05)
        case .vintage:
            let sepia = CIFilter.sepiaTone()
            sepia.inputImage = image
            sepia.intensity = 0.35
            let faded = named("CIPhotoEffectFade", sepia.outputImage ?? image)
            let vignette = CIFilter.vignette()
            vignette.inputImage = faded
            vignette.intensity = 0.8
            vignette.radius = 1.5
            filtered = vignette.outputImage
        }
        guard let filtered else { return image }
        let amount = min(max(intensity, 0), 1)
        guard amount < 0.999 else { return filtered }
        let blend = CIFilter.dissolveTransition()
        blend.inputImage = image
        blend.targetImage = filtered
        blend.time = Float(amount)
        return blend.outputImage ?? filtered
    }

    static func named(_ name: String, _ image: CIImage) -> CIImage? {
        guard let filter = CIFilter(name: name) else { return nil }
        filter.setValue(image, forKey: kCIInputImageKey)
        return filter.outputImage
    }

    static func grain(_ image: CIImage, amount: Double, extent: CGRect) -> CIImage {
        guard let noise = CIFilter.randomGenerator().outputImage else { return image }
        let mono = CIFilter.colorMatrix()
        mono.inputImage = noise
        let weight = CGFloat(amount * 0.25)
        mono.rVector = CIVector(x: weight, y: 0, z: 0, w: 0)
        mono.gVector = CIVector(x: weight, y: 0, z: 0, w: 0)
        mono.bVector = CIVector(x: weight, y: 0, z: 0, w: 0)
        mono.aVector = CIVector(x: 0, y: 0, z: 0, w: 0)
        mono.biasVector = CIVector(x: -weight / 2, y: -weight / 2, z: -weight / 2, w: 1)
        guard let texture = mono.outputImage?.cropped(to: extent) else { return image }
        let add = CIFilter.additionCompositing()
        add.inputImage = texture
        add.backgroundImage = image
        return add.outputImage?.cropped(to: extent) ?? image
    }

    static func ciRect(_ rect: StudioRect, canvas: CGSize) -> CGRect {
        let pixels = rect.canvasRect(in: canvas)
        return CGRect(
            x: pixels.minX, y: canvas.height - pixels.maxY, width: pixels.width,
            height: pixels.height
        ).intersection(CGRect(origin: .zero, size: canvas))
    }

    public static func redact(
        _ image: CGImage, rects: [StudioRect], style: ImageRedaction
    ) throws -> CGImage {
        let size = CGSize(width: image.width, height: image.height)
        var working = CIImage(cgImage: image)
        for rect in rects {
            working = redact(working, rect: rect, style: style, canvas: size)
        }
        guard let output = StudioImageOps.render(working, extent: CGRect(origin: .zero, size: size))
        else { throw StudioError.failed("The image could not be redacted.") }
        return output
    }

    static func redact(
        _ image: CIImage, rect: StudioRect, style: ImageRedaction, canvas: CGSize
    ) -> CIImage {
        let area = ciRect(rect, canvas: canvas)
        guard area.width >= 1, area.height >= 1 else { return image }
        let strength = min(max(style.strength, 0), 1)
        let patch: CIImage?
        switch style.style {
        case .solid:
            let color = StudioColor(hex: style.color) ?? .black
            patch = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: area)
        case .pixelate:
            let pixel = CIFilter.pixellate()
            pixel.inputImage = image.clampedToExtent()
            pixel.center = CGPoint(x: area.minX, y: area.minY)
            pixel.scale = Float(max(4, min(area.width, area.height) * (0.06 + 0.2 * strength)))
            patch = pixel.outputImage?.cropped(to: area)
        case .blur:
            let region = image.cropped(to: area).clampedToExtent()
            let blur = CIFilter.gaussianBlur()
            blur.inputImage = region
            blur.radius = Float(max(4, min(area.width, area.height) * (0.08 + 0.25 * strength)))
            patch = blur.outputImage?.cropped(to: area)
        }
        guard let patch else { return image }
        return patch.composited(over: image)
    }

    public static func drawLayers(_ layers: [ImageLayer], over image: CGImage) throws -> CGImage {
        guard !layers.isEmpty else { return image }
        let width = image.width
        let height = image.height
        guard let context = StudioImageOps.context(width: width, height: height) else {
            throw StudioError.failed("Not enough memory to draw the layers.")
        }
        let canvas = CGSize(width: width, height: height)
        context.draw(image, in: CGRect(origin: .zero, size: canvas))
        for layer in layers {
            draw(layer, in: context, canvas: canvas)
        }
        guard let output = context.makeImage() else {
            throw StudioError.failed("The layers could not be drawn.")
        }
        return output
    }

    static func cgRect(_ frame: StudioRect, canvas: CGSize) -> CGRect {
        let rect = frame.canvasRect(in: canvas)
        return CGRect(
            x: rect.minX, y: canvas.height - rect.maxY, width: rect.width, height: rect.height)
    }

    static func point(_ unit: ImagePoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width, y: rect.maxY - unit.y * rect.height)
    }

    static func draw(_ layer: ImageLayer, in context: CGContext, canvas: CGSize) {
        let rect = cgRect(layer.frame, canvas: canvas)
        let base = min(canvas.width, canvas.height)
        context.saveGState()
        context.setAlpha(min(max(layer.opacity, 0), 1))
        if abs(layer.rotation) > 0.001 {
            context.translateBy(x: rect.midX, y: rect.midY)
            context.rotate(by: -layer.rotation * .pi / 180)
            context.translateBy(x: -rect.midX, y: -rect.midY)
        }
        switch layer.content {
        case let .text(style):
            drawText(style, in: rect, canvas: canvas, context: context)
        case let .shape(style):
            drawShape(style, in: rect, base: base, context: context)
        case let .drawing(drawing):
            drawStrokes(drawing, in: rect, base: base, context: context)
        case let .sticker(value):
            drawSticker(value, in: rect, context: context)
        case let .image(path):
            if let image = LayerImageCache.image(path) {
                context.interpolationQuality = .high
                context.draw(
                    image,
                    in: ImageEditGeometry.fittedRect(
                        content: CGSize(width: image.width, height: image.height), in: rect))
            }
        case .redaction:
            break
        }
        context.restoreGState()
    }

    public static func textFont(_ style: ImageTextStyle, size: CGFloat) -> CTFont {
        var font = StudioStamp.font(named: style.font, size: size, bold: style.bold) as NSFont
        if style.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        return font as CTFont
    }

    static func drawText(
        _ style: ImageTextStyle, in rect: CGRect, canvas: CGSize, context: CGContext
    ) {
        let size = max(1, CGFloat(style.size) * canvas.height)
        let font = textFont(style, size: size)
        if let background = style.background.flatMap(StudioColor.init(hex:)) {
            context.setFillColor(background.cgColor)
            let radius = min(rect.height / 2, size * 0.3)
            context.addPath(
                CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            context.fillPath()
        }
        let alignment: NSTextAlignment =
            switch style.alignment {
            case .left: .left
            case .center: .center
            case .right: .right
            }
        let fitted = StudioText.fittingSize(style.text, font: font, width: rect.width)
        let height = max(fitted.height, size * 1.2)
        let box = CGRect(x: rect.minX, y: rect.midY - height / 2, width: rect.width, height: height)
        if style.shadow {
            context.setShadow(
                offset: CGSize(width: 0, height: -size * 0.04), blur: size * 0.14,
                color: CGColor(gray: 0, alpha: 0.55))
        }
        let stroke = style.strokeColor.flatMap(StudioColor.init(hex:))
        StudioText.draw(
            style.text, in: box, context: context, font: font,
            color: StudioColor(hex: style.color) ?? .white, alignment: alignment, stroke: stroke,
            strokeWidth: stroke == nil ? 0 : CGFloat(style.strokeWidth * 100))
    }

    static func drawShape(
        _ style: ImageShapeStyle, in rect: CGRect, base: CGFloat, context: CGContext
    ) {
        let lineWidth = max(1, CGFloat(style.strokeWidth) * base)
        let stroke = StudioColor(hex: style.strokeColor) ?? .black
        context.setStrokeColor(stroke.cgColor)
        context.setLineWidth(lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        switch style.shape {
        case .rectangle, .ellipse:
            let inset = rect.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            let path: CGPath
            if style.shape == .ellipse {
                path = CGPath(ellipseIn: inset, transform: nil)
            } else {
                let radius = min(
                    CGFloat(style.cornerRadius) * min(inset.width, inset.height),
                    min(inset.width, inset.height) / 2)
                path = CGPath(
                    roundedRect: inset, cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            if let fill = style.fillColor.flatMap(StudioColor.init(hex:)) {
                context.setFillColor(fill.cgColor)
                context.addPath(path)
                context.fillPath()
            }
            context.addPath(path)
            context.strokePath()
        case .line, .arrow:
            let start = point(style.start, in: rect)
            let end = point(style.end, in: rect)
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
            guard style.shape == .arrow else { return }
            let angle = atan2(end.y - start.y, end.x - start.x)
            let length = max(lineWidth * 4, 10)
            let spread = CGFloat.pi / 7
            let left = CGPoint(
                x: end.x - length * cos(angle - spread), y: end.y - length * sin(angle - spread))
            let right = CGPoint(
                x: end.x - length * cos(angle + spread), y: end.y - length * sin(angle + spread))
            context.setFillColor(stroke.cgColor)
            context.move(to: end)
            context.addLine(to: left)
            context.addLine(to: right)
            context.closePath()
            context.fillPath()
        }
    }

    static func drawStrokes(
        _ drawing: ImageDrawing, in rect: CGRect, base: CGFloat, context: CGContext
    ) {
        let color = StudioColor(hex: drawing.color) ?? .black
        let width = max(1, CGFloat(drawing.width) * base * (drawing.highlighter ? 2.5 : 1))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width)
        context.setLineCap(drawing.highlighter ? .square : .round)
        context.setLineJoin(.round)
        if drawing.highlighter { context.setAlpha(0.4) }
        for stroke in drawing.strokes {
            guard let first = stroke.first else { continue }
            if stroke.count == 1 {
                let center = point(first, in: rect)
                context.setFillColor(color.cgColor)
                context.fillEllipse(
                    in: CGRect(
                        x: center.x - width / 2, y: center.y - width / 2, width: width,
                        height: width))
                continue
            }
            context.move(to: point(first, in: rect))
            for next in stroke.dropFirst() { context.addLine(to: point(next, in: rect)) }
            context.strokePath()
        }
    }

    static func drawSticker(_ value: String, in rect: CGRect, context: CGContext) {
        let size = max(1, rect.height * 0.82)
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, size, nil)
        let attributed = NSAttributedString(string: value, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, context)
        let width = max(bounds.width, 1)
        let scale = min(1, rect.width / width)
        context.saveGState()
        context.translateBy(x: rect.midX, y: rect.midY)
        context.scaleBy(x: scale, y: scale)
        context.textMatrix = .identity
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    public static func applyFrame(_ frame: ImageFrameStyle, to image: CGImage) -> CGImage? {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        let base = min(width, height)
        let border = max(0, CGFloat(frame.width) * base).rounded()
        let color = StudioColor(hex: frame.color) ?? .white
        switch frame.kind {
        case .solid, .polaroid:
            let bottom = frame.kind == .polaroid ? max(border * 3.5, base * 0.12) : border
            let side = frame.kind == .polaroid ? max(border, base * 0.035) : border
            let canvas = CGSize(width: width + side * 2, height: height + side + bottom)
            guard
                let context = StudioImageOps.context(
                    width: Int(canvas.width), height: Int(canvas.height), opaque: true)
            else { return nil }
            context.setFillColor(color.cgColor)
            context.fill(CGRect(origin: .zero, size: canvas))
            context.draw(image, in: CGRect(x: side, y: bottom, width: width, height: height))
            return context.makeImage()
        case .rounded:
            let canvas = CGSize(width: width + border * 2, height: height + border * 2)
            guard
                let context = StudioImageOps.context(
                    width: Int(canvas.width), height: Int(canvas.height))
            else { return nil }
            context.clear(CGRect(origin: .zero, size: canvas))
            let radius = CGFloat(frame.cornerRadius) * min(canvas.width, canvas.height)
            let outer = CGRect(origin: .zero, size: canvas)
            if border > 0 {
                context.setFillColor(color.cgColor)
                context.addPath(
                    CGPath(
                        roundedRect: outer, cornerWidth: radius, cornerHeight: radius,
                        transform: nil))
                context.fillPath()
            }
            let inner = outer.insetBy(dx: border, dy: border)
            let innerRadius = max(0, radius - border)
            context.addPath(
                CGPath(
                    roundedRect: inner, cornerWidth: innerRadius, cornerHeight: innerRadius,
                    transform: nil))
            context.clip()
            context.draw(image, in: inner)
            return context.makeImage()
        case .shadow:
            let padding = max(border, base * 0.05).rounded()
            let canvas = CGSize(width: width + padding * 2, height: height + padding * 2)
            guard
                let context = StudioImageOps.context(
                    width: Int(canvas.width), height: Int(canvas.height))
            else { return nil }
            context.clear(CGRect(origin: .zero, size: canvas))
            context.setShadow(
                offset: CGSize(width: 0, height: -padding * 0.25), blur: padding * 0.7,
                color: CGColor(gray: 0, alpha: 0.5))
            context.draw(image, in: CGRect(x: padding, y: padding, width: width, height: height))
            return context.makeImage()
        }
    }
}

enum LayerImageCache {
    private static let cache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.countLimit = 24
        return cache
    }()

    static func image(_ path: String) -> CGImage? {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        guard let image = try? StudioImageIO.load(URL(fileURLWithPath: path), maxPixelSize: 2048)
        else { return nil }
        cache.setObject(image, forKey: path as NSString)
        return image
    }
}
