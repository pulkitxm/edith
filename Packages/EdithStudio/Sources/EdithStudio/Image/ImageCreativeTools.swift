import AppKit
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreText
import Foundation

enum ImageCreativeTools {
    static let watermark = StudioTool(
        id: "image.watermark", title: "Watermark image",
        summary:
            "Stamp text or a logo over your images with the font, opacity and position you choose.",
        symbol: "drop.halffull", group: .edit, inputs: [.image],
        options: StudioStamp.options(textDefault: "© Your name"),
        keywords: ["stamp", "logo", "copyright", "brand", "protect"], actionTitle: "Add watermark"
    ) { run in
        let stamp = try StudioStamp.from(run.settings)
        let url = try ImageToolSupport.process(run, suffix: "watermarked") { image in
            guard let context = StudioImageOps.context(width: image.width, height: image.height)
            else {
                throw StudioError.failed("Not enough memory to watermark the image.")
            }
            let size = CGSize(width: image.width, height: image.height)
            context.draw(image, in: CGRect(origin: .zero, size: size))
            stamp.draw(in: context, size: size)
            guard let output = context.makeImage() else {
                throw StudioError.failed("The watermark could not be drawn.")
            }
            return output
        }
        return [url]
    }

    static let removeBackground = StudioTool(
        id: "image.remove-background", title: "Remove background",
        summary:
            "Cut out people, pets and objects on device, then keep them on transparency or a new background.",
        symbol: "person.and.background.dotted", group: .edit, inputs: [.image],
        options: [
            .choice(
                "background", "Background",
                [
                    StudioChoice("transparent", "Transparent"), StudioChoice("white", "White"),
                    StudioChoice("color", "Color"), StudioChoice("blur", "Blurred original"),
                ], default: "transparent"),
            .color("color", "Color", default: "#4A90E2", when: .init("background", ["color"])),
            .toggle("crop", "Crop to the subject", default: false),
            .choice(
                "format", "Save as",
                [StudioChoice("png", "PNG"), StudioChoice("heic", "HEIC")], default: "png"),
        ],
        keywords: ["cutout", "transparent", "subject", "remove bg", "isolate", "sticker"],
        actionTitle: "Remove background"
    ) { run in
        let image = try StudioImageIO.load(run.input, maxPixelSize: 6000)
        run.status("Finding the subject")
        guard let mask = try BackgroundRemoval.mask(for: image) else {
            throw StudioError.nothingToDo(
                "No clear subject was found in \(run.input.lastPathComponent).")
        }
        run.progress(0.6)
        var result = try BackgroundRemoval.composite(
            image, mask: mask, background: run.settings.text("background"),
            color: run.settings.color("color", fallback: .white))
        if run.settings.bool("crop"),
            let bounds = BackgroundRemoval.subjectBounds(mask, size: image)
        {
            result = StudioImageOps.cropped(result, to: bounds) ?? result
        }
        let format: StudioImageFormat = run.settings.text("format") == "heic" ? .heic : .png
        let output = run.output(for: run.input, suffix: "no-background", ext: format.fileExtension)
        try StudioImageIO.write(result, to: output, format: format, options: .init(quality: 0.9))
        return [output]
    }

    static let blurFaces = StudioTool(
        id: "image.blur-faces", title: "Blur faces",
        summary:
            "Hide faces automatically, and optionally text and license plates, before you share.",
        symbol: "eye.slash", group: .security, inputs: [.image],
        options: [
            .choice(
                "style", "Style",
                ImageRedactionStyle.allCases.map { StudioChoice($0.rawValue, $0.title) },
                default: "blur"),
            .percent("strength", "Strength", 0.1...1, default: 0.7),
            .percent(
                "margin", "Extra area", 0...0.6, default: 0.2,
                help: "Grows each box so hair and edges are covered."),
            .toggle(
                "text", "Also blur text and license plates", default: false,
                help: "Uses text recognition to find plates, signs and documents."),
        ],
        keywords: ["privacy", "anonymize", "faces", "license plate", "hide", "pixelate"],
        actionTitle: "Blur"
    ) { run in
        let image = try StudioImageIO.load(run.input)
        let margin = run.settings.number("margin")
        let faces = try StudioVision.faces(in: image)
        var rects = faces.map { FaceBlur.rect($0, margin: margin) }
        var textCount = 0
        if run.settings.bool("text") {
            let regions = try StudioVision.textRegions(in: image)
            textCount = regions.count
            rects += regions.map { FaceBlur.rect($0, margin: 0.15) }
        }
        guard !rects.isEmpty else {
            return [
                try ImageToolSupport.copyUnchanged(
                    run, suffix: "blurred",
                    note:
                        "No faces were found in \(run.input.lastPathComponent), so it was saved unchanged."
                )
            ]
        }
        let style = ImageRedaction(
            style: ImageRedactionStyle(rawValue: run.settings.text("style")) ?? .blur,
            strength: run.settings.number("strength"))
        let blurred = try ImageEditRenderer.redact(image, rects: rects, style: style)
        run.note(FaceBlur.summary(faces: faces.count, text: textCount))
        return [try ImageToolSupport.write(blurred, run: run, suffix: "blurred")]
    }

    static let upscale = StudioTool(
        id: "image.upscale", title: "Upscale image",
        summary:
            "Enlarge images 2x, 3x or 4x with high-quality resampling, noise reduction and sharpening.",
        symbol: "arrow.up.backward.and.arrow.down.forward", group: .optimize, inputs: [.image],
        options: [
            .choice(
                "scale", "Enlarge",
                [StudioChoice("2", "2x"), StudioChoice("3", "3x"), StudioChoice("4", "4x")],
                default: "2"),
            .toggle("denoise", "Reduce noise", default: true),
            .toggle("sharpen", "Sharpen", default: true),
        ],
        keywords: ["enlarge", "increase resolution", "bigger", "enhance", "hd"],
        actionTitle: "Upscale"
    ) { run in
        let scale = Double(run.settings.text("scale")) ?? 2
        let image = try StudioImageIO.load(run.input)
        let pixels = Double(image.width) * Double(image.height) * scale * scale
        guard pixels <= 200_000_000 else {
            throw StudioError.invalidOption(
                "enlarge",
                "\(run.input.lastPathComponent) would be too large, choose a smaller scale")
        }
        let upscaled = try Upscaler.upscale(
            image, scale: scale, denoise: run.settings.bool("denoise"),
            sharpen: run.settings.bool("sharpen"))
        return [
            try ImageToolSupport.write(upscaled, run: run, suffix: "\(Int(scale))x", quality: 0.95)
        ]
    }

    static var presetIntensityCondition: StudioOption.Condition {
        StudioOption.Condition(
            "filter", Set(ImageFilterPreset.allCases.filter { $0 != .none }.map(\.rawValue)))
    }

    static let adjust = StudioTool(
        id: "image.adjust", title: "Filters and adjustments",
        summary: "Apply the same filter and color adjustments to a whole batch of photos.",
        symbol: "camera.filters", group: .edit, inputs: [.image],
        options: [
            .choice("filter", "Filter", ImageFilterPreset.choices, default: "none"),
            .percent(
                "intensity", "Filter strength", 0...1, default: 1, when: presetIntensityCondition),
            .number("exposure", "Exposure", -1...1, step: 0.05, default: 0),
            .number("brightness", "Brightness", -1...1, step: 0.05, default: 0),
            .number("contrast", "Contrast", -1...1, step: 0.05, default: 0),
            .number("saturation", "Saturation", -1...1, step: 0.05, default: 0),
            .number("warmth", "Warmth", -1...1, step: 0.05, default: 0),
            .number("sharpness", "Sharpness", 0...1, step: 0.05, default: 0),
            .number("vignette", "Vignette", 0...1, step: 0.05, default: 0),
        ],
        keywords: ["filter", "brightness", "contrast", "saturation", "color", "effects", "batch"],
        actionTitle: "Apply"
    ) { run in
        var adjustments = ImageAdjustments()
        for key in [
            ImageAdjustments.Key.exposure, .brightness, .contrast, .saturation, .warmth, .sharpness,
            .vignette,
        ] {
            adjustments[key] = run.settings.number(key.rawValue)
        }
        let filter = ImageFilterPreset(rawValue: run.settings.text("filter")) ?? .none
        guard filter != .none || !adjustments.isNeutral else {
            throw StudioError.invalidOption("filter", "choose a filter or move a slider first")
        }
        let intensity = run.settings.number("intensity")
        let url = try ImageToolSupport.process(run, suffix: "edited") { image in
            try ImageEditRenderer.adjust(
                image, adjustments: adjustments, filter: filter, intensity: intensity)
        }
        return [url]
    }

    static let meme = StudioTool(
        id: "image.meme", title: "Meme generator",
        summary: "Add bold top and bottom captions in the classic meme style.",
        symbol: "face.smiling", group: .create, inputs: [.image],
        options: [
            .text("top", "Top text", placeholder: "When the build passes", default: ""),
            .text("bottom", "Bottom text", placeholder: "On the first try", default: ""),
            .font(default: "Impact"),
            .color("color", "Text color", default: "#FFFFFF"),
            .color("stroke", "Outline", default: "#000000"),
            .toggle("uppercase", "All caps", default: true),
        ],
        keywords: ["meme", "caption", "funny", "impact", "text"], actionTitle: "Make meme"
    ) { run in
        var top = run.settings.trimmed("top")
        var bottom = run.settings.trimmed("bottom")
        guard !top.isEmpty || !bottom.isEmpty else {
            throw StudioError.invalidOption("top text", "enter a top or bottom caption")
        }
        if run.settings.bool("uppercase") {
            top = top.uppercased()
            bottom = bottom.uppercased()
        }
        let image = try StudioImageIO.load(run.input, maxPixelSize: 4000)
        let result = try MemeMaker.render(
            image, top: top, bottom: bottom, font: run.settings.text("font"),
            color: run.settings.color("color", fallback: .white),
            stroke: run.settings.color("stroke", fallback: .black))
        return [try ImageToolSupport.write(result, run: run, suffix: "meme", keepMetadata: false)]
    }

    static let border = StudioTool(
        id: "image.border", title: "Add border",
        summary: "Frame images with a solid, rounded, polaroid or drop shadow border.",
        symbol: "square.dashed", group: .edit, inputs: [.image],
        options: [
            .choice(
                "style", "Style",
                ImageFrameKind.allCases.map { StudioChoice($0.rawValue, $0.title) },
                default: "solid"),
            .percent(
                "width", "Width", 0...0.3, default: 0.04, help: "Relative to the shorter side."),
            .color(
                "color", "Color", default: "#FFFFFF",
                when: .init("style", ["solid", "rounded", "polaroid"])),
            .percent(
                "radius", "Corner radius", 0...0.5, default: 0.08, when: .init("style", ["rounded"])
            ),
        ],
        keywords: ["frame", "polaroid", "rounded corners", "shadow", "padding"],
        actionTitle: "Add border"
    ) { run in
        let frame = ImageFrameStyle(
            kind: ImageFrameKind(rawValue: run.settings.text("style")) ?? .solid,
            width: run.settings.number("width"), color: run.settings.text("color"),
            cornerRadius: run.settings.number("radius"))
        let url = try ImageToolSupport.process(run, suffix: "framed") { image in
            guard let framed = ImageEditRenderer.applyFrame(frame, to: image) else {
                throw StudioError.failed("The border could not be drawn.")
            }
            return framed
        }
        return [url]
    }

    static let collage = StudioTool(
        id: "image.collage", title: "Photo collage",
        summary: "Combine several images into one grid, row or column with even spacing.",
        symbol: "square.grid.2x2", group: .create, inputs: [.image],
        arity: .combine(minimum: 2, maximum: nil),
        options: [
            .choice(
                "layout", "Layout",
                [
                    StudioChoice("grid", "Grid"), StudioChoice("horizontal", "Row"),
                    StudioChoice("vertical", "Column"),
                ], default: "grid"),
            .integer(
                "columns", "Columns", 0...12, default: 0, help: "0 picks a balanced grid.",
                when: .init("layout", ["grid"])),
            .toggle(
                "fill", "Crop to fill each cell", default: true, when: .init("layout", ["grid"])),
            .integer("spacing", "Spacing", 0...300, default: 16, unit: "px"),
            .color("background", "Background", default: "#FFFFFF"),
            .integer("width", "Width", 200...12000, default: 2400, unit: "px"),
            .choice(
                "format", "Save as", [StudioChoice("jpg", "JPG"), StudioChoice("png", "PNG")],
                default: "jpg"),
        ],
        keywords: ["combine", "grid", "merge images", "join", "montage", "stitch"],
        actionTitle: "Make collage", family: .image
    ) { run in
        var images: [CGImage] = []
        for (index, input) in run.inputs.enumerated() {
            images.append(try StudioImageIO.load(input, maxPixelSize: 4000))
            run.progress(Double(index + 1) / Double(run.inputs.count) * 0.6)
        }
        let collage = try CollageMaker.render(
            images, layout: run.settings.text("layout"), columns: run.settings.int("columns"),
            fill: run.settings.bool("fill"), spacing: Double(run.settings.int("spacing")),
            background: run.settings.color("background", fallback: .white),
            width: Double(run.settings.int("width")))
        let format: StudioImageFormat = run.settings.text("format") == "png" ? .png : .jpeg
        let output = run.output(for: run.inputs[0], suffix: "collage", ext: format.fileExtension)
        try StudioImageIO.write(collage, to: output, format: format, options: .init(quality: 0.9))
        return [output]
    }

    static let makeGIF = StudioTool(
        id: "image.make-gif", title: "Make a GIF",
        summary: "Turn a series of images into an animated GIF with your own timing.",
        symbol: "photo.stack", group: .create, inputs: [.image],
        arity: .combine(minimum: 2, maximum: nil), produces: .kind(.image),
        options: [
            .number("delay", "Time per frame", 0.02...5, step: 0.05, default: 0.5, unit: "s"),
            .toggle("loop", "Loop forever", default: true),
            .integer(
                "width", "Width", 0...2000, default: 640, unit: "px",
                help: "0 keeps the size of the first image."),
        ],
        keywords: ["animation", "animated", "gif", "slideshow", "frames"], actionTitle: "Make GIF",
        family: .image
    ) { run in
        var images: [CGImage] = []
        for input in run.inputs {
            images.append(try StudioImageIO.load(input, maxPixelSize: 2000))
        }
        let frames = try GIFMaker.frames(images, width: run.settings.int("width"))
        let delay = run.settings.number("delay")
        let output = run.output(for: run.inputs[0], suffix: "animation", ext: "gif")
        try StudioImageIO.writeAnimatedGIF(
            frames.map { ($0, delay) }, to: output, loopCount: run.settings.bool("loop") ? 0 : 1)
        return [output]
    }
}

enum BackgroundRemoval {
    static func mask(for image: CGImage) throws -> CIImage? {
        guard let mask = try StudioVision.foregroundMask(of: image) else { return nil }
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard mask.extent.width > 0, mask.extent.height > 0 else { return nil }
        return mask.transformed(
            by: CGAffineTransform(
                scaleX: extent.width / mask.extent.width, y: extent.height / mask.extent.height))
    }

    static func composite(
        _ image: CGImage, mask: CIImage, background: String, color: StudioColor
    ) throws -> CGImage {
        let original = CIImage(cgImage: image)
        let extent = original.extent
        let backdrop: CIImage
        switch background {
        case "white":
            backdrop = CIImage(color: .white).cropped(to: extent)
        case "color":
            backdrop = CIImage(color: CIColor(cgColor: color.cgColor)).cropped(to: extent)
        case "blur":
            backdrop = original.clampedToExtent()
                .applyingGaussianBlur(sigma: max(extent.width, extent.height) * 0.02)
                .cropped(to: extent)
        default:
            backdrop = CIImage(color: .clear).cropped(to: extent)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = original
        blend.backgroundImage = backdrop
        blend.maskImage = mask
        guard let output = blend.outputImage,
            let rendered = StudioImageOps.render(output, extent: extent)
        else { throw StudioError.failed("The background could not be removed.") }
        return rendered
    }

    static func subjectBounds(_ mask: CIImage, size image: CGImage) -> StudioRect? {
        let extent = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        guard let rendered = StudioImageOps.render(mask, extent: extent) else { return nil }
        let small = StudioImageOps.fitted(rendered, maxDimension: 512)
        let width = small.width
        let height = small.height
        guard let context = StudioImageOps.context(width: width, height: height, opaque: true),
            let data = context.data
        else { return nil }
        context.draw(small, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width where bytes[y * context.bytesPerRow + x * 4] > 127 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let pad = 0.02
        return StudioRect(
            x: max(0, Double(minX) / Double(width) - pad),
            y: max(0, Double(minY) / Double(height) - pad),
            width: min(1, Double(maxX - minX + 1) / Double(width) + pad * 2),
            height: min(1, Double(maxY - minY + 1) / Double(height) + pad * 2)
        ).clamped
    }
}

enum FaceBlur {
    static func rect(_ box: CGRect, margin: Double) -> StudioRect {
        let width = box.width * (1 + margin * 2)
        let height = box.height * (1 + margin * 2)
        return StudioRect(
            x: box.minX - box.width * margin, y: 1 - box.maxY - box.height * margin, width: width,
            height: height
        ).clamped
    }

    static func summary(faces: Int, text: Int) -> String {
        var parts: [String] = []
        if faces > 0 { parts.append("\(faces) face\(faces == 1 ? "" : "s")") }
        if text > 0 { parts.append("\(text) text area\(text == 1 ? "" : "s")") }
        return "Blurred " + parts.joined(separator: " and ") + "."
    }
}

enum Upscaler {
    static func upscale(_ image: CGImage, scale: Double, denoise: Bool, sharpen: Bool) throws
        -> CGImage
    {
        var working = CIImage(cgImage: image).clampedToExtent()
        if denoise {
            let noise = CIFilter.noiseReduction()
            noise.inputImage = working
            noise.noiseLevel = 0.015
            noise.sharpness = 0.4
            working = noise.outputImage ?? working
        }
        let lanczos = CIFilter.lanczosScaleTransform()
        lanczos.inputImage = working
        lanczos.scale = Float(scale)
        lanczos.aspectRatio = 1
        working = (lanczos.outputImage ?? working).clampedToExtent()
        if sharpen {
            let unsharp = CIFilter.unsharpMask()
            unsharp.inputImage = working
            unsharp.radius = Float(1.2 * scale)
            unsharp.intensity = 0.45
            working = unsharp.outputImage ?? working
        }
        let extent = CGRect(
            x: 0, y: 0, width: (Double(image.width) * scale).rounded(),
            height: (Double(image.height) * scale).rounded())
        guard let output = StudioImageOps.render(working.cropped(to: extent), extent: extent) else {
            throw StudioError.failed("The image could not be enlarged.")
        }
        return output
    }
}

enum MemeMaker {
    static func font(_ name: String, size: CGFloat) -> CTFont {
        for candidate in [name, "Impact", "HelveticaNeue-CondensedBlack", "Helvetica-Bold"] {
            if let font = NSFont(name: candidate, size: size) { return font as CTFont }
        }
        return NSFont.boldSystemFont(ofSize: size) as CTFont
    }

    static func fittedFont(_ text: String, name: String, width: CGFloat, maxHeight: CGFloat)
        -> (CTFont, CGSize)
    {
        var size = maxHeight * 0.5
        while size > 8 {
            let candidate = font(name, size: size)
            let fitted = StudioText.fittingSize(text, font: candidate, width: width)
            let lines = (fitted.height / (size * 1.25)).rounded()
            if fitted.height <= maxHeight, lines <= 3 { return (candidate, fitted) }
            size *= 0.92
        }
        let smallest = font(name, size: 8)
        return (smallest, StudioText.fittingSize(text, font: smallest, width: width))
    }

    static func render(
        _ image: CGImage, top: String, bottom: String, font name: String, color: StudioColor,
        stroke: StudioColor
    ) throws -> CGImage {
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)
        guard let context = StudioImageOps.context(width: image.width, height: image.height) else {
            throw StudioError.failed("Not enough memory to make the meme.")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let margin = min(width, height) * 0.03
        let textWidth = width - margin * 2
        let maxHeight = height * 0.3
        if !top.isEmpty {
            let (font, fitted) = fittedFont(top, name: name, width: textWidth, maxHeight: maxHeight)
            let rect = CGRect(
                x: margin, y: height - margin - fitted.height - 2, width: textWidth,
                height: fitted.height + 2)
            StudioText.draw(
                top, in: rect, context: context, font: font, color: color, stroke: stroke,
                strokeWidth: 7)
        }
        if !bottom.isEmpty {
            let (font, fitted) = fittedFont(
                bottom, name: name, width: textWidth, maxHeight: maxHeight)
            let rect = CGRect(x: margin, y: margin, width: textWidth, height: fitted.height + 2)
            StudioText.draw(
                bottom, in: rect, context: context, font: font, color: color, stroke: stroke,
                strokeWidth: 7)
        }
        guard let output = context.makeImage() else {
            throw StudioError.failed("The meme could not be drawn.")
        }
        return output
    }
}

enum CollageMaker {
    static func render(
        _ images: [CGImage], layout: String, columns: Int, fill: Bool, spacing: Double,
        background: StudioColor, width: Double
    ) throws -> CGImage {
        guard !images.isEmpty else { throw StudioError.needsMoreInputs(2) }
        let ratios = images.map { Double($0.width) / Double(max($0.height, 1)) }
        var frames: [CGRect] = []
        var canvas = CGSize(width: width, height: width)
        switch layout {
        case "horizontal":
            let rowHeight = max(
                1, (width - spacing * Double(images.count + 1)) / ratios.reduce(0, +))
            var x = spacing
            for ratio in ratios {
                frames.append(CGRect(x: x, y: spacing, width: rowHeight * ratio, height: rowHeight))
                x += rowHeight * ratio + spacing
            }
            canvas = CGSize(width: width, height: rowHeight + spacing * 2)
        case "vertical":
            let columnWidth = max(1, width - spacing * 2)
            var y = spacing
            for ratio in ratios {
                let height = columnWidth / ratio
                frames.append(CGRect(x: spacing, y: y, width: columnWidth, height: height))
                y += height + spacing
            }
            canvas = CGSize(width: width, height: y)
        default:
            let count = images.count
            let columnCount =
                columns > 0 ? min(columns, count) : Int(Double(count).squareRoot().rounded(.up))
            let rowCount = Int((Double(count) / Double(columnCount)).rounded(.up))
            let cellWidth = max(
                1, (width - spacing * Double(columnCount + 1)) / Double(columnCount))
            let averageRatio = ratios.reduce(0, +) / Double(ratios.count)
            let cellHeight = cellWidth / min(max(averageRatio, 0.5), 2)
            for index in 0..<count {
                let column = index % columnCount
                let row = index / columnCount
                frames.append(
                    CGRect(
                        x: spacing + Double(column) * (cellWidth + spacing),
                        y: spacing + Double(row) * (cellHeight + spacing), width: cellWidth,
                        height: cellHeight))
            }
            canvas = CGSize(
                width: width, height: spacing + Double(rowCount) * (cellHeight + spacing))
        }
        let pixelWidth = Int(canvas.width.rounded())
        let pixelHeight = Int(canvas.height.rounded())
        guard pixelWidth * pixelHeight < 250_000_000,
            let context = StudioImageOps.context(
                width: pixelWidth, height: pixelHeight, opaque: true)
        else { throw StudioError.failed("The collage would be too large. Choose a smaller width.") }
        context.setFillColor(background.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.interpolationQuality = .high
        for (image, frame) in zip(images, frames) {
            let flipped = CGRect(
                x: frame.minX, y: canvas.height - frame.maxY, width: frame.width,
                height: frame.height)
            let content = CGSize(width: image.width, height: image.height)
            context.saveGState()
            context.clip(to: flipped)
            let target =
                layout == "grid" || layout.isEmpty
                ? (fill
                    ? IconMaker.fillRect(content: content, in: flipped)
                    : ImageEditGeometry.fittedRect(content: content, in: flipped))
                : flipped
            context.draw(image, in: target)
            context.restoreGState()
        }
        guard let output = context.makeImage() else {
            throw StudioError.failed("The collage could not be drawn.")
        }
        return output
    }
}

enum GIFMaker {
    static func frames(_ images: [CGImage], width: Int) throws -> [CGImage] {
        guard let first = images.first else { throw StudioError.needsMoreInputs(2) }
        let targetWidth = width > 0 ? width : first.width
        let targetHeight = max(
            1, Int((Double(targetWidth) * Double(first.height) / Double(first.width)).rounded()))
        return try images.map { image in
            guard
                let context = StudioImageOps.context(
                    width: targetWidth, height: targetHeight, opaque: true)
            else { throw StudioError.failed("Not enough memory to make the GIF.") }
            let bounds = CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)
            context.setFillColor(StudioColor.white.cgColor)
            context.fill(bounds)
            context.interpolationQuality = .high
            context.draw(
                image,
                in: ImageEditGeometry.fittedRect(
                    content: CGSize(width: image.width, height: image.height), in: bounds))
            guard let frame = context.makeImage() else {
                throw StudioError.failed("A GIF frame could not be drawn.")
            }
            return frame
        }
    }
}
