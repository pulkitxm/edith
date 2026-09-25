import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum ImageToolSupport {
    static let keptFormats: Set<StudioImageFormat> = [
        .jpeg, .png, .heic, .avif, .gif, .tiff, .bmp, .jpeg2000,
    ]

    static func outputFormat(for input: URL, hasAlpha: Bool) -> (StudioImageFormat, String?) {
        let writable = Set(StudioImageFormat.writable)
        if let format = StudioImageFormat.of(input), keptFormats.contains(format),
            writable.contains(format)
        {
            if format.supportsAlpha || !hasAlpha { return (format, nil) }
            return (.png, "Saved \(input.lastPathComponent) as PNG to keep its transparency.")
        }
        let fallback: StudioImageFormat = hasAlpha ? .png : .jpeg
        let original = input.pathExtension.uppercased()
        return (
            fallback,
            "Saved \(input.lastPathComponent) as \(fallback.title) because \(original) files cannot be written on this Mac."
        )
    }

    static func isAnimated(_ url: URL) -> Bool {
        guard StudioImageFormat.of(url) == .gif,
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return false }
        return CGImageSourceGetCount(source) > 1
    }

    static func process(
        _ run: StudioRun, suffix: String, keepMetadata: Bool = true, quality: Double = 0.92,
        transform: (CGImage) throws -> CGImage
    ) throws -> URL {
        let input = run.input
        if isAnimated(input) {
            let frames = try StudioImageIO.frames(input)
            var output: [(image: CGImage, delay: Double)] = []
            for (index, frame) in frames.enumerated() {
                try run.checkCancellation()
                output.append((try transform(frame.image), frame.delay))
                run.progress(Double(index + 1) / Double(frames.count) * 0.9)
            }
            let url = run.output(for: input, suffix: suffix, ext: "gif")
            try StudioImageIO.writeAnimatedGIF(output, to: url, loopCount: loopCount(input))
            return url
        }
        let image = try StudioImageIO.load(input)
        run.progress(0.2)
        let result = try transform(image)
        run.progress(0.8)
        return try write(
            result, run: run, suffix: suffix, keepMetadata: keepMetadata, quality: quality)
    }

    static func write(
        _ image: CGImage, run: StudioRun, suffix: String?, keepMetadata: Bool = true,
        quality: Double = 0.92, format requested: StudioImageFormat? = nil
    ) throws -> URL {
        let format: StudioImageFormat
        if let requested {
            format = requested
        } else {
            let (resolved, note) = outputFormat(
                for: run.input, hasAlpha: StudioImageOps.hasTransparency(image))
            format = resolved
            if let note { run.note(note) }
        }
        let url = run.output(for: run.input, suffix: suffix, ext: format.fileExtension)
        try StudioImageIO.write(
            image, to: url, format: format,
            options: .init(quality: quality, keepMetadataFrom: keepMetadata ? run.input : nil))
        return url
    }

    static func loopCount(_ url: URL) -> Int {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any],
            let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0 }
        return gif[kCGImagePropertyGIFLoopCount] as? Int ?? 0
    }

    static func copyUnchanged(_ run: StudioRun, suffix: String, note: String) throws -> URL {
        let url = run.output(for: run.input, suffix: suffix, ext: run.input.pathExtension)
        try FileManager.default.copyItem(at: run.input, to: url)
        run.note(note)
        return url
    }

    static func keepSmaller(
        _ candidate: URL, original: URL, run: StudioRun, sameFormat: Bool
    ) throws -> URL {
        let before = StudioRunner.fileSize(original)
        let after = StudioRunner.fileSize(candidate)
        guard sameFormat, after >= before else { return candidate }
        try FileManager.default.removeItem(at: candidate)
        try FileManager.default.copyItem(at: original, to: candidate)
        run.note(
            "\(original.lastPathComponent) is already well optimized, so it was kept as it was.")
        return candidate
    }

    static func orientation(_ url: URL) -> Int {
        StudioImageIO.properties(url)[kCGImagePropertyOrientation] as? Int ?? 1
    }
}

enum JPEGMetadata {
    static func strip(_ data: Data, orientation: Int) throws -> Data {
        let bytes = [UInt8](data)
        guard bytes.count > 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else {
            throw StudioError.failed("The JPEG could not be read.")
        }
        var output: [UInt8] = [0xFF, 0xD8]
        var pendingOrientation = orientation != 1
        var index = 2
        while index + 4 <= bytes.count {
            guard bytes[index] == 0xFF else {
                throw StudioError.failed("The JPEG has an unexpected structure.")
            }
            let marker = bytes[index + 1]
            if marker == 0xFF {
                index += 1
                continue
            }
            if pendingOrientation, marker != 0xE0 {
                output += orientationSegment(orientation)
                pendingOrientation = false
            }
            if marker == 0xDA || marker == 0xD9 {
                output += bytes[index...]
                return Data(output)
            }
            if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                output += bytes[index..<(index + 2)]
                index += 2
                continue
            }
            let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
            let end = index + 2 + length
            guard length >= 2, end <= bytes.count else {
                throw StudioError.failed("The JPEG has an unexpected structure.")
            }
            let drop =
                marker == 0xE1 || marker == 0xED || marker == 0xFE || marker == 0xEF
                || (0xE3...0xEC).contains(marker)
            if !drop { output += bytes[index..<end] }
            index = end
        }
        throw StudioError.failed("The JPEG ended unexpectedly.")
    }

    static func orientationSegment(_ orientation: Int) -> [UInt8] {
        let tiff: [UInt8] = [
            0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
            0x00, 0x01,
            0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(orientation), 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00,
        ]
        let payload: [UInt8] = Array("Exif".utf8) + [0, 0] + tiff
        let length = payload.count + 2
        return [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
    }
}

enum SVGMinifier {
    static func minify(_ text: String) -> String {
        var result = text
        let replacements: [(String, String)] = [
            (#"<!--[\s\S]*?-->"#, ""),
            (#"<metadata[\s\S]*?</metadata>"#, ""),
            (#"<sodipodi:namedview[\s\S]*?(/>|</sodipodi:namedview>)"#, ""),
            (#">\s+<"#, "><"),
            (#"(\d+\.\d{3})\d+"#, "$1"),
            (#"[ \t]{2,}"#, " "),
            (#"\n+"#, " "),
        ]
        for (pattern, template) in replacements {
            result = result.replacingOccurrences(
                of: pattern, with: template, options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ImageTrim {
    static func bounds(_ image: CGImage, tolerance: Double) -> StudioRect? {
        let sample = StudioImageOps.fitted(image, maxDimension: 1200)
        let width = sample.width
        let height = sample.height
        guard let context = StudioImageOps.context(width: width, height: height),
            let data = context.data
        else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(sample, in: CGRect(x: 0, y: 0, width: width, height: height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
        let row = context.bytesPerRow
        let reference = (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
        let limit = Int(tolerance * 255)
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = y * row + x * 4
                let differs =
                    abs(Int(bytes[offset]) - reference.0) > limit
                    || abs(Int(bytes[offset + 1]) - reference.1) > limit
                    || abs(Int(bytes[offset + 2]) - reference.2) > limit
                    || abs(Int(bytes[offset + 3]) - reference.3) > limit
                if differs {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        let rect = StudioRect(
            x: Double(minX) / Double(width), y: Double(minY) / Double(height),
            width: Double(maxX - minX + 1) / Double(width),
            height: Double(maxY - minY + 1) / Double(height))
        return rect.isFull ? nil : rect
    }
}
