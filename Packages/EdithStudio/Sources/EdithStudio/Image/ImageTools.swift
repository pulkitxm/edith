import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageTools {
    static var all: [StudioTool] {
        [
            edit, compress, resize, crop, convert, rotate, ImageCreativeTools.watermark,
            ImageCreativeTools.removeBackground, ImageCreativeTools.blurFaces,
            ImageCreativeTools.upscale, ImageCreativeTools.adjust, ImageCreativeTools.meme,
            ImageCreativeTools.border, ImageCreativeTools.collage, ImageCreativeTools.makeGIF,
            metadata, toText, icon,
        ]
    }

    static let lossyFormats: Set<String> = ["jpg", "heic", "avif", "jp2"]

    static let edit = StudioTool(
        id: "image.edit", title: "Photo editor",
        summary:
            "Crop, straighten, adjust colors, apply filters, and add text, shapes, stickers and blur.",
        symbol: "slider.horizontal.below.rectangle", group: .edit, inputs: [.image],
        produces: .kind(.image), style: .editor(.image, pdfMode: nil),
        keywords: ["edit", "filters", "text", "stickers", "draw", "crop", "adjust", "photo"])

    static let compress = StudioTool(
        id: "image.compress", title: "Compress image",
        summary: "Shrink JPG, PNG, GIF, HEIC and SVG files while keeping them looking the same.",
        symbol: "arrow.down.right.and.arrow.up.left", group: .optimize, inputs: [.image],
        options: [
            .choice(
                "level", "Compression",
                [
                    StudioChoice("less", "Less"), StudioChoice("recommended", "Recommended"),
                    StudioChoice("extreme", "Extreme"),
                ], default: "recommended",
                help:
                    "Recommended keeps photos visually identical. Extreme gives the smallest files."
            ),
            .integer(
                "maxSize", "Longest side", 0...20000, default: 0, unit: "px",
                help: "0 keeps the original size."),
            .toggle("stripMetadata", "Remove camera and location data", default: true),
        ],
        keywords: ["reduce", "shrink", "smaller", "optimize", "size", "png", "jpg"],
        actionTitle: "Compress"
    ) { run in
        let input = run.input
        let level = run.settings.text("level")
        let strip = run.settings.bool("stripMetadata")
        let maxSize = run.settings.int("maxSize")
        let ext = input.pathExtension.lowercased()
        if ext == "svg" {
            guard StudioImageIO.info(input) != nil,
                let text = try? String(contentsOf: input, encoding: .utf8)
            else { throw StudioError.unreadable(input.lastPathComponent) }
            let output = run.output(for: input, suffix: "compressed", ext: "svg")
            try SVGMinifier.minify(text).write(to: output, atomically: true, encoding: .utf8)
            return [
                try ImageToolSupport.keepSmaller(
                    output, original: input, run: run, sameFormat: true)
            ]
        }
        let format = StudioImageFormat.of(input)
        if ImageToolSupport.isAnimated(input) {
            var frames = try StudioImageIO.frames(input)
            if maxSize > 0 {
                frames = frames.map {
                    (StudioImageOps.fitted($0.image, maxDimension: maxSize), $0.delay)
                }
            }
            let output = run.output(for: input, suffix: "compressed", ext: "gif")
            try StudioImageIO.writeAnimatedGIF(
                frames, to: output, loopCount: ImageToolSupport.loopCount(input))
            return [
                try ImageToolSupport.keepSmaller(
                    output, original: input, run: run, sameFormat: maxSize == 0,
                    stripMetadata: strip)
            ]
        }
        var image = try StudioImageIO.load(input)
        if maxSize > 0 { image = StudioImageOps.fitted(image, maxDimension: maxSize) }
        run.progress(0.3)
        let photoQuality = ["less": 0.85, "extreme": 0.5][level] ?? 0.72
        let modernQuality = ["less": 0.8, "extreme": 0.42][level] ?? 0.62
        let keep = strip ? nil : input
        let output: URL
        var sameFormat = true
        switch format {
        case .png?, .gif?:
            output = run.output(
                for: input, suffix: "compressed", ext: format?.fileExtension ?? "png")
            if level == "less" {
                try StudioImageIO.write(
                    image, to: output, format: format ?? .png,
                    options: .init(keepMetadataFrom: keep))
            } else if format == .gif {
                try StudioImageIO.write(image, to: output, format: .gif)
            } else {
                let colors = level == "extreme" ? 128 : 256
                try ImageQuantizer.quantize(image, colors: colors, dither: true).pngData().write(
                    to: output)
            }
        case .jpeg?:
            output = run.output(for: input, suffix: "compressed", ext: "jpg")
            try StudioImageIO.write(
                image, to: output, format: .jpeg,
                options: .init(quality: photoQuality, keepMetadataFrom: keep))
        case .heic?, .avif?, .jpeg2000?:
            let target = format ?? .heic
            output = run.output(for: input, suffix: "compressed", ext: target.fileExtension)
            try StudioImageIO.write(
                image, to: output, format: target,
                options: .init(quality: modernQuality, keepMetadataFrom: keep))
        case .tiff?:
            output = run.output(for: input, suffix: "compressed", ext: "tiff")
            try StudioImageIO.write(
                image, to: output, format: .tiff, options: .init(keepMetadataFrom: keep))
        default:
            sameFormat = false
            let alpha = StudioImageOps.hasTransparency(image)
            if alpha {
                output = run.output(for: input, suffix: "compressed", ext: "png")
                try ImageQuantizer.quantize(image, colors: 256, dither: true).pngData().write(
                    to: output)
            } else {
                output = run.output(for: input, suffix: "compressed", ext: "jpg")
                try StudioImageIO.write(
                    image, to: output, format: .jpeg, options: .init(quality: photoQuality))
            }
            let larger = StudioRunner.fileSize(output) >= StudioRunner.fileSize(input)
            let carriesMetadata = strip && !MetadataScrubber.isClean(input, everything: true)
            if maxSize == 0, larger, !carriesMetadata {
                try FileManager.default.removeItem(at: output)
                return [
                    try ImageToolSupport.copyUnchanged(
                        run, suffix: "compressed",
                        note:
                            "\(input.lastPathComponent) is already smaller than a \(output.pathExtension.uppercased()) copy would be, so it was kept as it was."
                    )
                ]
            }
            run.note(
                "Saved \(input.lastPathComponent) as \(output.pathExtension.uppercased()) because \(ext.uppercased()) files cannot be compressed in place."
            )
        }
        return [
            try ImageToolSupport.keepSmaller(
                output, original: input, run: run, sameFormat: sameFormat && maxSize == 0,
                stripMetadata: strip)
        ]
    }

    static let resize = StudioTool(
        id: "image.resize", title: "Resize image",
        summary: "Set exact pixels, a percentage or a longest side. Works on many images at once.",
        symbol: "arrow.up.left.and.arrow.down.right", group: .optimize, inputs: [.image],
        options: [
            .choice(
                "mode", "Resize",
                [
                    StudioChoice("pixels", "By pixels"), StudioChoice("percent", "By percentage"),
                    StudioChoice("longest", "Longest side"),
                ], default: "pixels"),
            .integer(
                "width", "Width", 0...30000, default: 1200, unit: "px",
                help: "Leave width or height at 0 to keep the proportions.",
                when: .init("mode", ["pixels"])),
            .integer(
                "height", "Height", 0...30000, default: 0, unit: "px",
                when: .init("mode", ["pixels"])),
            .toggle(
                "keepAspect", "Keep proportions", default: true,
                help: "Fits inside the width and height instead of stretching.",
                when: .init("mode", ["pixels"])),
            .integer(
                "percent", "Scale", 1...1000, default: 50, unit: "%",
                when: .init("mode", ["percent"])),
            .integer(
                "longest", "Longest side", 16...30000, default: 1920, unit: "px",
                when: .init("mode", ["longest"])),
            .toggle("noEnlarge", "Do not enlarge smaller images", default: true),
        ],
        keywords: ["scale", "dimensions", "shrink", "enlarge", "pixels", "percent"],
        actionTitle: "Resize"
    ) { run in
        let settings = run.settings
        let url = try ImageToolSupport.process(run, suffix: "resized") { image in
            let size = ImageSizing.target(
                for: CGSize(width: image.width, height: image.height), settings: settings)
            guard
                let resized = StudioImageOps.resized(image, width: size.width, height: size.height)
            else { throw StudioError.failed("The image could not be resized.") }
            return resized
        }
        return [url]
    }

    static let crop = StudioTool(
        id: "image.crop", title: "Crop image",
        summary: "Crop to an aspect ratio, an exact area, or trim plain borders automatically.",
        symbol: "crop", group: .edit, inputs: [.image],
        options: [
            .choice(
                "mode", "Crop",
                [
                    StudioChoice("aspect", "Aspect ratio"), StudioChoice("area", "Custom area"),
                    StudioChoice("trim", "Trim borders"),
                ], default: "aspect"),
            .choice(
                "aspect", "Ratio",
                ["1:1", "4:3", "3:4", "3:2", "2:3", "16:9", "9:16", "4:5", "5:4", "21:9"].map {
                    StudioChoice($0, $0)
                }, default: "1:1", when: .init("mode", ["aspect"])),
            .anchor(default: .center, when: .init("mode", ["aspect"])),
            .rect(
                "area", "Area", default: StudioRect(x: 0.1, y: 0.1, width: 0.8, height: 0.8),
                help: "Drag on the preview, or enter x, y, width and height between 0 and 1.",
                when: .init("mode", ["area"])),
            .percent(
                "tolerance", "Tolerance", 0...0.5, default: 0.08, when: .init("mode", ["trim"])),
        ],
        keywords: ["trim", "aspect", "square", "cut", "borders", "instagram"], actionTitle: "Crop"
    ) { run in
        let settings = run.settings
        if settings.text("mode") == "trim", ImageToolSupport.isAnimated(run.input) {
            let frames = try StudioImageIO.frames(run.input)
            guard
                let bounds = ImageTrim.bounds(
                    frames: frames.map(\.image), tolerance: settings.number("tolerance"))
            else {
                return [
                    try ImageToolSupport.copyUnchanged(
                        run, suffix: "cropped",
                        note: "\(run.input.lastPathComponent) has no plain border to trim.")
                ]
            }
            let url = try ImageToolSupport.process(run, suffix: "cropped") { image in
                guard let cropped = StudioImageOps.cropped(image, to: bounds) else {
                    throw StudioError.failed("The image could not be cropped.")
                }
                return cropped
            }
            return [url]
        }
        if settings.text("mode") == "trim" {
            let image = try StudioImageIO.load(run.input)
            guard let bounds = ImageTrim.bounds(image, tolerance: settings.number("tolerance"))
            else {
                return [
                    try ImageToolSupport.copyUnchanged(
                        run, suffix: "cropped",
                        note: "\(run.input.lastPathComponent) has no plain border to trim.")
                ]
            }
            guard let cropped = StudioImageOps.cropped(image, to: bounds) else {
                throw StudioError.failed("The image could not be cropped.")
            }
            return [try ImageToolSupport.write(cropped, run: run, suffix: "cropped")]
        }
        let url = try ImageToolSupport.process(run, suffix: "cropped") { image in
            let rect = ImageSizing.cropRect(
                for: CGSize(width: image.width, height: image.height), settings: settings)
            guard let cropped = StudioImageOps.cropped(image, to: rect) else {
                throw StudioError.failed("The crop area is empty.")
            }
            return cropped
        }
        return [url]
    }

    static var formatChoices: [StudioChoice] {
        StudioImageFormat.writable.map { StudioChoice($0.fileExtension, $0.title) }
    }

    static let convert = StudioTool(
        id: "image.convert", title: "Convert image",
        summary: "Turn PNG, HEIC, WEBP, SVG, PSD, RAW and more into JPG, PNG or any other format.",
        symbol: "arrow.triangle.2.circlepath", group: .convert, inputs: [.image],
        options: [
            .choice("format", "Convert to", formatChoices, default: "jpg"),
            .percent(
                "quality", "Quality", 0.1...1, default: 0.9,
                when: .init("format", ImageTools.lossyFormats)),
            .color(
                "background", "Background", default: "#FFFFFF",
                help: "Fills transparent areas in formats without transparency.",
                when: .init("format", ["jpg", "bmp"])),
            .toggle("keepMetadata", "Keep camera data", default: true),
        ],
        keywords: ["jpg", "png", "heic", "webp", "svg", "raw", "psd", "gif", "format", "export"],
        actionTitle: "Convert"
    ) { run in
        let settings = run.settings
        let format = StudioImageFormat(rawValue: settings.text("format")) ?? .jpeg
        let input = run.input
        let ext = input.pathExtension.lowercased() == format.fileExtension ? "converted" : nil
        let output = run.output(for: input, suffix: ext, ext: format.fileExtension)
        if format == .gif, ImageToolSupport.isAnimated(input) {
            try StudioImageIO.writeAnimatedGIF(
                try StudioImageIO.frames(input), to: output,
                loopCount: ImageToolSupport.loopCount(input))
            return [output]
        }
        let image = try StudioImageIO.load(input)
        run.progress(0.5)
        try StudioImageIO.write(
            image, to: output, format: format,
            options: .init(
                quality: settings.number("quality"),
                keepMetadataFrom: settings.bool("keepMetadata") ? input : nil,
                background: format.supportsAlpha
                    ? nil : settings.color("background", fallback: .white)))
        return [output]
    }

    static let rotate = StudioTool(
        id: "image.rotate", title: "Rotate image",
        summary:
            "Rotate, flip or straighten many images at once, or only the landscape or portrait ones.",
        symbol: "rotate.right", group: .edit, inputs: [.image],
        options: [
            .choice(
                "angle", "Rotate",
                [
                    StudioChoice("0", "None"), StudioChoice("90", "Right 90°"),
                    StudioChoice("180", "180°"), StudioChoice("270", "Left 90°"),
                ], default: "90"),
            .choice(
                "flip", "Flip",
                [
                    StudioChoice("none", "None"), StudioChoice("horizontal", "Horizontal"),
                    StudioChoice("vertical", "Vertical"),
                ], default: "none"),
            .choice(
                "only", "Apply to",
                [
                    StudioChoice("any", "Every image"), StudioChoice("landscape", "Landscape only"),
                    StudioChoice("portrait", "Portrait only"),
                ], default: "any"),
            .number(
                "straighten", "Straighten", -45...45, step: 0.5, default: 0, unit: "°",
                help: "Small angles level a horizon. Edges are cropped so no blank corners show."),
        ],
        keywords: ["turn", "flip", "mirror", "straighten", "orientation", "landscape", "portrait"],
        actionTitle: "Rotate"
    ) { run in
        let settings = run.settings
        let turns = (Int(settings.text("angle")) ?? 0) / 90
        let flip = settings.text("flip")
        let straighten = settings.number("straighten")
        guard turns != 0 || flip != "none" || abs(straighten) > 0.01 else {
            throw StudioError.invalidOption(
                "rotate", "choose an angle, a flip or a straighten amount")
        }
        let only = settings.text("only")
        if only != "any", let info = StudioImageIO.info(run.input) {
            let landscape = info.width > info.height
            if (only == "landscape") != landscape {
                let shape = landscape ? "landscape" : "portrait"
                return [
                    try ImageToolSupport.copyUnchanged(
                        run, suffix: "rotated",
                        note: "\(run.input.lastPathComponent) is \(shape), so it was not rotated.")
                ]
            }
        }
        var document = ImageEditDocument(source: run.input)
        document.quarterTurns = turns
        document.flipHorizontal = flip == "horizontal"
        document.flipVertical = flip == "vertical"
        document.straighten = straighten
        let url = try ImageToolSupport.process(run, suffix: "rotated") { image in
            try ImageEditRenderer.geometryImage(document: document, source: image)
        }
        return [url]
    }

    static let metadata = StudioTool(
        id: "image.metadata", title: "Remove metadata",
        summary:
            "Strip camera details and GPS location from photos before you share them, without recompressing.",
        symbol: "location.slash", group: .security, inputs: [.image],
        options: [
            .choice(
                "mode", "Remove",
                [
                    StudioChoice("all", "Everything"),
                    StudioChoice("location", "Location only"),
                ], default: "all")
        ],
        keywords: ["exif", "gps", "location", "privacy", "metadata", "camera"],
        actionTitle: "Remove metadata"
    ) { run in
        let (output, reencoded) = try MetadataScrubber.scrub(
            run, everything: run.settings.text("mode") == "all")
        if reencoded {
            run.note("\(run.input.lastPathComponent) had to be re-encoded to remove its metadata.")
        }
        return [output]
    }

    static let toText = StudioTool(
        id: "image.to-text", title: "Image to text",
        summary: "Read the text in screenshots, photos and scans with on-device recognition.",
        symbol: "text.viewfinder", group: .convert, inputs: [.image], produces: .kind(.document),
        options: [
            .choice("language", "Language", StudioVision.languageChoices, default: "auto"),
            .choice(
                "accuracy", "Recognition",
                [StudioChoice("accurate", "Accurate"), StudioChoice("fast", "Fast")],
                default: "accurate"),
        ],
        keywords: ["ocr", "extract text", "scan", "screenshot", "read", "copy"],
        actionTitle: "Extract text"
    ) { run in
        let image = try StudioImageIO.load(run.input, maxPixelSize: 6000)
        let name = run.input.lastPathComponent
        guard StudioVision.canAnalyze(image) else {
            throw StudioError.nothingToDo("\(name) is too small to contain readable text.")
        }
        let lines = try await StudioVision.reporting("Text recognition", for: name) {
            try await StudioVision.recognizeText(
                in: image, language: run.settings.text("language"),
                accurate: run.settings.text("accuracy") != "fast")
        }
        guard !lines.isEmpty else {
            throw StudioError.nothingToDo("No text was found in \(run.input.lastPathComponent).")
        }
        let output = run.output(for: run.input, suffix: nil, ext: "txt")
        try (StudioVision.text(of: lines) + "\n").write(
            to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static let icon = StudioTool(
        id: "image.icon", title: "Make an icon",
        summary: "Turn an image into a macOS .icns or Windows .ico file with every size included.",
        symbol: "app.dashed", group: .convert, inputs: [.image], produces: .kind(.image),
        options: [
            .choice(
                "format", "Format",
                [StudioChoice("icns", "macOS (.icns)"), StudioChoice("ico", "Windows (.ico)")],
                default: "icns"),
            .choice(
                "shape", "Shape",
                [StudioChoice("square", "As is"), StudioChoice("rounded", "Rounded square")],
                default: "square"),
            .toggle("margin", "Add a margin", default: false),
        ],
        keywords: ["icns", "ico", "favicon", "app icon"], actionTitle: "Make icon"
    ) { run in
        let format: StudioImageFormat = run.settings.text("format") == "ico" ? .ico : .icns
        let image = try StudioImageIO.load(run.input, maxPixelSize: 2048)
        let icon = try IconMaker.make(
            image, rounded: run.settings.text("shape") == "rounded",
            margin: run.settings.bool("margin"))
        let output = run.output(for: run.input, suffix: nil, ext: format.fileExtension)
        try StudioImageIO.write(icon, to: output, format: format)
        return [output]
    }
}

enum MetadataScrubber {
    static func scrub(_ run: StudioRun, everything: Bool) throws -> (URL, reencoded: Bool) {
        let input = run.input
        let output = run.output(for: input, suffix: "clean", ext: input.pathExtension)
        if try stripLosslessly(input, to: output, everything: everything) {
            return (output, false)
        }
        try? FileManager.default.removeItem(at: output)
        if isGIF(input) {
            try StudioImageIO.writeAnimatedGIF(
                try StudioImageIO.frames(input), to: output,
                loopCount: ImageToolSupport.loopCount(input))
            return (output, false)
        }
        let image = try StudioImageIO.load(input)
        let (format, note) = ImageToolSupport.outputFormat(
            for: input, hasAlpha: StudioImageOps.hasTransparency(image))
        if let note { run.note(note) }
        let target =
            StudioImageFormat.of(input) == format
            ? output : run.output(for: input, suffix: "clean", ext: format.fileExtension)
        try StudioImageIO.write(
            image, to: target, format: format,
            options: .init(
                quality: 0.95, keepMetadataFrom: everything ? nil : input, keepsLocation: false))
        return (target, format.isLossy)
    }

    static func stripLosslessly(_ input: URL, to output: URL, everything: Bool) throws -> Bool {
        let name = input.lastPathComponent
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
            CGImageSourceGetCount(source) > 0, let type = CGImageSourceGetType(source),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            properties[kCGImagePropertyPixelWidth] as? Int ?? 0 > 0
        else { throw StudioError.unreadable(name) }
        try StudioImageIntegrity.requireComplete(input, source: source)
        let orientation = ImageToolSupport.orientation(input)
        if everything,
            type as String == UTType.jpeg.identifier || type as String == UTType.png.identifier
        {
            let data = try Data(contentsOf: input)
            let stripped =
                type as String == UTType.jpeg.identifier
                ? try? JPEGMetadata.strip(data, orientation: orientation, name: name)
                : try? PNGMetadata.strip(data, orientation: orientation, name: name)
            if let stripped {
                try stripped.write(to: output)
                return true
            }
        }
        guard type as String != UTType.gif.identifier,
            let destination = CGImageDestinationCreateWithURL(output as CFURL, type, 1, nil),
            CGImageDestinationCopyImageSource(
                destination, source,
                options(source, everything: everything, orientation: orientation) as CFDictionary,
                nil)
        else { return false }
        return isClean(output, everything: everything)
    }

    static func isGIF(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let type = CGImageSourceGetType(source)
        else { return false }
        return type as String == UTType.gif.identifier
    }

    static let neutralExif: Set<CFString> = [
        kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
        kCGImagePropertyExifColorSpace, kCGImagePropertyExifVersion,
        kCGImagePropertyExifFlashPixVersion, kCGImagePropertyExifComponentsConfiguration,
    ]

    static let neutralTIFF: Set<CFString> = [
        kCGImagePropertyTIFFOrientation, kCGImagePropertyTIFFXResolution,
        kCGImagePropertyTIFFYResolution, kCGImagePropertyTIFFResolutionUnit,
        kCGImagePropertyTIFFCompression, kCGImagePropertyTIFFPhotometricInterpretation,
        kCGImagePropertyTIFFTileWidth, kCGImagePropertyTIFFTileLength,
    ]

    static func isClean(_ url: URL, everything: Bool) -> Bool {
        let properties = StudioImageIO.properties(url)
        if let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any], !gps.isEmpty {
            return false
        }
        guard everything else { return true }
        if let iptc = properties[kCGImagePropertyIPTCDictionary] as? [CFString: Any],
            !iptc.isEmpty
        {
            return false
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        return exif.keys.allSatisfy(neutralExif.contains)
            && tiff.keys.allSatisfy(neutralTIFF.contains)
    }

    static func options(_ source: CGImageSource, everything: Bool, orientation: Int) -> [CFString:
        Any]
    {
        guard everything else {
            var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
            if let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
                options[kCGImageDestinationMetadata] = metadata
                options[kCGImageDestinationMergeMetadata] = true
            }
            return options
        }
        let metadata = CGImageMetadataCreateMutable()
        if orientation != 1 {
            _ = CGImageMetadataSetValueMatchingImageProperty(
                metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation,
                orientation as CFNumber)
        }
        return [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: false]
    }
}

enum ImageSizing {
    struct Size: Equatable {
        let width: Int
        let height: Int
    }

    static func target(for size: CGSize, settings: StudioSettings) -> Size {
        let width = Double(size.width)
        let height = Double(size.height)
        var target: (Double, Double)
        switch settings.text("mode") {
        case "percent":
            let scale = settings.number("percent") / 100
            target = (width * scale, height * scale)
        case "longest":
            let scale = settings.number("longest") / max(width, height)
            target = (width * scale, height * scale)
        default:
            let requestedWidth = settings.number("width")
            let requestedHeight = settings.number("height")
            if requestedWidth <= 0, requestedHeight <= 0 {
                target = (width, height)
            } else if requestedHeight <= 0 {
                target = (requestedWidth, height * requestedWidth / width)
            } else if requestedWidth <= 0 {
                target = (width * requestedHeight / height, requestedHeight)
            } else if settings.bool("keepAspect") {
                let scale = min(requestedWidth / width, requestedHeight / height)
                target = (width * scale, height * scale)
            } else {
                target = (requestedWidth, requestedHeight)
            }
        }
        if settings.bool("noEnlarge"), target.0 > width || target.1 > height {
            let scale = min(width / target.0, height / target.1, 1)
            target = (target.0 * scale, target.1 * scale)
        }
        return Size(
            width: max(1, Int(target.0.rounded())), height: max(1, Int(target.1.rounded())))
    }

    static func ratio(_ text: String) -> Double? {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return parts[0] / parts[1]
    }

    static func cropRect(for size: CGSize, settings: StudioSettings) -> StudioRect {
        if settings.text("mode") == "area" { return settings.rect("area").clamped }
        let ratio = self.ratio(settings.text("aspect")) ?? 1
        let base = ImageEditGeometry.aspectCrop(ratio, in: size)
        var anchor = settings.anchor()
        if anchor == .tiled { anchor = .center }
        let unit = anchor.unit
        return StudioRect(
            x: (1 - base.width) * unit.x, y: (1 - base.height) * unit.y, width: base.width,
            height: base.height)
    }
}

enum IconMaker {
    static func make(_ image: CGImage, rounded: Bool, margin: Bool) throws -> CGImage {
        let side = 1024
        guard let context = StudioImageOps.context(width: side, height: side) else {
            throw StudioError.failed("Not enough memory to make the icon.")
        }
        context.clear(CGRect(x: 0, y: 0, width: side, height: side))
        let inset = margin ? CGFloat(side) * 0.1 : 0
        let area = CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: inset, dy: inset)
        if rounded {
            let radius = area.width * 0.225
            context.addPath(
                CGPath(roundedRect: area, cornerWidth: radius, cornerHeight: radius, transform: nil)
            )
            context.clip()
        }
        context.interpolationQuality = .high
        let fill =
            rounded
            ? fillRect(content: CGSize(width: image.width, height: image.height), in: area)
            : ImageEditGeometry.fittedRect(
                content: CGSize(width: image.width, height: image.height), in: area)
        context.draw(image, in: fill)
        guard let output = context.makeImage() else {
            throw StudioError.failed("The icon could not be drawn.")
        }
        return output
    }

    static func fillRect(content: CGSize, in bounds: CGRect) -> CGRect {
        guard content.width > 0, content.height > 0 else { return bounds }
        let scale = max(bounds.width / content.width, bounds.height / content.height)
        let size = CGSize(width: content.width * scale, height: content.height * scale)
        return CGRect(
            x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width,
            height: size.height)
    }
}
