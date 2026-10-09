import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

@testable import EdithStudio

struct AuditRGB: Equatable, CustomStringConvertible {
    let r: Int
    let g: Int
    let b: Int

    init(_ r: Int, _ g: Int, _ b: Int) {
        self.r = r
        self.g = g
        self.b = b
    }

    static let red = AuditRGB(214, 48, 49)
    static let green = AuditRGB(46, 160, 67)
    static let blue = AuditRGB(40, 80, 200)
    static let yellow = AuditRGB(236, 200, 40)
    static let white = AuditRGB(255, 255, 255)
    static let black = AuditRGB(0, 0, 0)

    var cgColor: CGColor {
        CGColor(
            srgbRed: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255, alpha: 1)
    }

    func distance(to other: AuditRGB) -> Int {
        max(abs(r - other.r), abs(g - other.g), abs(b - other.b))
    }

    func isClose(to other: AuditRGB, tolerance: Int = 40) -> Bool {
        distance(to: other) <= tolerance
    }

    var description: String { "(\(r),\(g),\(b))" }
}

enum AuditLayout {
    static let upright: [AuditRGB] = [.red, .green, .blue, .yellow]
    static let clockwise: [AuditRGB] = [.blue, .red, .yellow, .green]
    static let counterClockwise: [AuditRGB] = [.green, .yellow, .red, .blue]
    static let halfTurn: [AuditRGB] = [.yellow, .blue, .green, .red]
    static let mirrored: [AuditRGB] = [.green, .red, .yellow, .blue]
    static let upsideDown: [AuditRGB] = [.blue, .yellow, .red, .green]
}

struct AuditBitmap {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: image.width * image.height * 4)
        buffer.withUnsafeMutableBytes { raw in
            let context = CGContext(
                data: raw.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        bytes = buffer
    }

    init(url: URL) throws {
        self.init(try StudioImageIO.load(url))
    }

    func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    func alpha(_ x: Int, _ y: Int) -> Int {
        guard contains(x, y) else { return -1 }
        return Int(bytes[(y * width + x) * 4 + 3])
    }

    func rgb(_ x: Int, _ y: Int) -> AuditRGB {
        guard contains(x, y) else { return AuditRGB(-1, -1, -1) }
        let offset = (y * width + x) * 4
        let a = Int(bytes[offset + 3])
        guard a > 0 else { return AuditRGB(0, 0, 0) }
        func channel(_ value: UInt8) -> Int { min(255, (Int(value) * 255 + a / 2) / a) }
        return AuditRGB(
            channel(bytes[offset]), channel(bytes[offset + 1]), channel(bytes[offset + 2]))
    }

    func rgb(unit x: Double, _ y: Double) -> AuditRGB {
        rgb(
            min(width - 1, max(0, Int(x * Double(width)))),
            min(height - 1, max(0, Int(y * Double(height)))))
    }

    func quadrants(inset: CGRect? = nil, rows: (Double, Double) = (0.25, 0.75)) -> [AuditRGB] {
        let area = inset ?? CGRect(x: 0, y: 0, width: width, height: height)
        func sample(_ ux: Double, _ uy: Double) -> AuditRGB {
            average(
                around: CGPoint(
                    x: area.minX + ux * area.width, y: area.minY + uy * area.height), radius: 2)
        }
        return [
            sample(0.25, rows.0), sample(0.75, rows.0), sample(0.25, rows.1), sample(0.75, rows.1),
        ]
    }

    func matches(_ layout: [AuditRGB], inset: CGRect? = nil, tolerance: Int = 40) -> Bool {
        zip(quadrants(inset: inset), layout).allSatisfy { $0.isClose(to: $1, tolerance: tolerance) }
    }

    func average(around point: CGPoint, radius: Int) -> AuditRGB {
        let cx = Int(point.x)
        let cy = Int(point.y)
        var total = (0, 0, 0)
        var count = 0
        for y in max(0, cy - radius)...min(height - 1, cy + radius) {
            for x in max(0, cx - radius)...min(width - 1, cx + radius) {
                let pixel = rgb(x, y)
                total = (total.0 + pixel.r, total.1 + pixel.g, total.2 + pixel.b)
                count += 1
            }
        }
        return AuditRGB(total.0 / count, total.1 / count, total.2 / count)
    }

    func count(in rect: CGRect, step: Int = 1, where predicate: (AuditRGB, Int) -> Bool) -> Int {
        var total = 0
        let minX = max(0, Int(rect.minX))
        let maxX = min(width, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(height, Int(rect.maxY))
        guard minX < maxX, minY < maxY else { return 0 }
        for y in stride(from: minY, to: maxY, by: step) {
            for x in stride(from: minX, to: maxX, by: step) where predicate(rgb(x, y), alpha(x, y))
            {
                total += 1
            }
        }
        return total
    }

    func detail(in rect: CGRect) -> Double {
        var total = 0
        var count = 0
        let minX = max(0, Int(rect.minX))
        let maxX = min(width - 1, Int(rect.maxX))
        let minY = max(0, Int(rect.minY))
        let maxY = min(height, Int(rect.maxY))
        for y in minY..<maxY {
            for x in minX..<maxX {
                let a = rgb(x, y)
                let b = rgb(x + 1, y)
                total += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                count += 1
            }
        }
        return count == 0 ? 0 : Double(total) / Double(count)
    }

    func meanDifference(_ other: AuditBitmap) -> Double {
        guard other.width == width, other.height == height else { return .infinity }
        var total = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            total +=
                abs(Int(bytes[index]) - Int(other.bytes[index]))
                + abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1]))
                + abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2]))
                + abs(Int(bytes[index + 3]) - Int(other.bytes[index + 3]))
        }
        return Double(total) / Double(bytes.count)
    }
}

enum AuditImages {
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

    static func context(
        _ width: Int, _ height: Int, space: CGColorSpace = sRGB, alpha: Bool = false
    ) -> CGContext {
        CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: space,
            bitmapInfo: alpha
                ? CGImageAlphaInfo.premultipliedLast.rawValue
                : CGImageAlphaInfo.noneSkipLast.rawValue)!
    }

    static func quadrants(
        width: Int = 120, height: Int = 80, colors: [AuditRGB] = AuditLayout.upright
    ) -> CGImage {
        let context = context(width, height)
        paintQuadrants(context, width: width, height: height, colors: colors.map(\.cgColor))
        return context.makeImage()!
    }

    static func paintQuadrants(
        _ context: CGContext, width: Int, height: Int, colors: [CGColor]
    ) {
        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        let rects = [
            CGRect(x: 0, y: halfHeight, width: halfWidth, height: CGFloat(height) - halfHeight),
            CGRect(
                x: halfWidth, y: halfHeight, width: CGFloat(width) - halfWidth,
                height: CGFloat(height) - halfHeight),
            CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight),
            CGRect(x: halfWidth, y: 0, width: CGFloat(width) - halfWidth, height: halfHeight),
        ]
        for (rect, color) in zip(rects, colors) {
            context.setFillColor(color)
            context.fill(rect)
        }
    }

    static func transparentCorner(width: Int = 120, height: Int = 80) -> CGImage {
        let context = context(width, height, alpha: true)
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        paintQuadrants(
            context, width: width, height: height,
            colors: [
                AuditRGB.red.cgColor, AuditRGB.green.cgColor, AuditRGB.blue.cgColor,
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            ])
        context.clear(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2))
        return context.makeImage()!
    }

    static func stored(_ upright: CGImage, orientation: Int) -> CGImage {
        let source = AuditBitmap(upright)
        let swaps = orientation >= 5
        let storedWidth = swaps ? source.height : source.width
        let storedHeight = swaps ? source.width : source.height
        var bytes = [UInt8](repeating: 0, count: storedWidth * storedHeight * 4)
        for sy in 0..<storedHeight {
            for sx in 0..<storedWidth {
                let (dx, dy): (Int, Int)
                switch orientation {
                case 2: (dx, dy) = (storedWidth - 1 - sx, sy)
                case 3: (dx, dy) = (storedWidth - 1 - sx, storedHeight - 1 - sy)
                case 4: (dx, dy) = (sx, storedHeight - 1 - sy)
                case 5: (dx, dy) = (sy, sx)
                case 6: (dx, dy) = (storedHeight - 1 - sy, sx)
                case 7: (dx, dy) = (storedHeight - 1 - sy, storedWidth - 1 - sx)
                case 8: (dx, dy) = (sy, storedWidth - 1 - sx)
                default: (dx, dy) = (sx, sy)
                }
                let from = (dy * source.width + dx) * 4
                let to = (sy * storedWidth + sx) * 4
                for channel in 0..<4 { bytes[to + channel] = source.bytes[from + channel] }
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: storedWidth, height: storedHeight, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: storedWidth * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func write(
        _ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:],
        quality: Double = 0.95
    ) throws {
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, type.identifier as CFString, 1, nil)
        else { throw StudioError.failed("fixture destination \(type.identifier)") }
        var merged = properties
        merged[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(destination, image, merged as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.failed("fixture write \(url.lastPathComponent)")
        }
    }

    static func cameraProperties(orientation: Int = 1) -> [CFString: Any] {
        [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 48.8584, kCGImagePropertyGPSLatitudeRef: "N",
                kCGImagePropertyGPSLongitude: 2.2945, kCGImagePropertyGPSLongitudeRef: "E",
            ],
            kCGImagePropertyExifDictionary: [
                kCGImagePropertyExifUserComment: "secret",
                kCGImagePropertyExifDateTimeOriginal: "2024:05:01 10:00:00",
                kCGImagePropertyExifLensModel: "Wide 26mm",
            ],
            kCGImagePropertyTIFFDictionary: [
                kCGImagePropertyTIFFMake: "Acme", kCGImagePropertyTIFFModel: "Snap 1",
                kCGImagePropertyTIFFOrientation: orientation,
            ],
        ]
    }

    static func photo(
        at url: URL, orientation: Int = 1, type: UTType = .jpeg, width: Int = 120,
        height: Int = 80, camera: Bool = false, upright: CGImage? = nil
    ) throws {
        let image = upright ?? quadrants(width: width, height: height)
        var properties: [CFString: Any] =
            camera ? cameraProperties(orientation: orientation) : [:]
        if orientation != 1 { properties[kCGImagePropertyOrientation] = orientation }
        try write(
            stored(image, orientation: orientation), to: url, type: type, properties: properties)
    }

    static func cmykJPEG(at url: URL, width: Int = 120, height: Int = 80) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.genericCMYK)!,
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        context.draw(
            quadrants(width: width, height: height),
            in: CGRect(x: 0, y: 0, width: width, height: height))
        try write(context.makeImage()!, to: url, type: .jpeg)
    }

    static func displayP3(at url: URL, type: UTType, width: Int = 120, height: Int = 80) throws {
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = context(width, height, space: p3)
        paintQuadrants(
            context, width: width, height: height,
            colors: AuditLayout.upright.map {
                $0.cgColor.converted(to: p3, intent: .defaultIntent, options: nil)!
            })
        try write(context.makeImage()!, to: url, type: type)
    }

    static let grayLevels = [40, 100, 170, 230]

    static func grayscale(at url: URL, type: UTType, width: Int = 120, height: Int = 80) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.genericGrayGamma2_2)!,
            bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        paintQuadrants(
            context, width: width, height: height,
            colors: grayLevels.map { CGColor(gray: Double($0) / 255, alpha: 1) })
        try write(context.makeImage()!, to: url, type: type)
    }

    static func sixteenBitPNG(at url: URL, width: Int = 120, height: Int = 80) throws {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
            space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder16Little.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        paintQuadrants(
            context, width: width, height: height,
            colors: [
                AuditRGB.red.cgColor, AuditRGB.green.cgColor, AuditRGB.blue.cgColor,
                CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0),
            ])
        context.clear(CGRect(x: width / 2, y: 0, width: width - width / 2, height: height / 2))
        try write(context.makeImage()!, to: url, type: .png)
    }

    static func palettePNG(at url: URL, width: Int = 120, height: Int = 80) throws {
        let quantized = try ImageQuantizer.quantize(
            transparentCorner(width: width, height: height), colors: 16, dither: false)
        try quantized.pngData().write(to: url)
    }

    static func animatedGIF(at url: URL, delays: [Double], size: (Int, Int) = (60, 40)) throws {
        let colors: [AuditRGB] = [.red, .green, .blue, .yellow, .white]
        let frames = delays.enumerated().map { index, delay -> (image: CGImage, delay: Double) in
            let context = context(size.0, size.1)
            context.setFillColor(colors[index % colors.count].cgColor)
            context.fill(CGRect(x: 0, y: 0, width: size.0, height: size.1))
            return (context.makeImage()!, delay)
        }
        try StudioImageIO.writeAnimatedGIF(frames, to: url)
    }

    static func pixelGrid(_ colors: [[AuditRGB]]) -> CGImage {
        let height = colors.count
        let width = colors[0].count
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for (y, row) in colors.enumerated() {
            for (x, color) in row.enumerated() {
                let offset = (y * width + x) * 4
                bytes[offset] = UInt8(color.r)
                bytes[offset + 1] = UInt8(color.g)
                bytes[offset + 2] = UInt8(color.b)
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: sRGB,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func textPhoto(_ text: String, width: Int = 900, height: Int = 300) -> CGImage {
        let context = context(width, height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        Fixtures.line(
            text, x: 40, y: CGFloat(height) / 2 - 30, size: 90, bold: true, context: context)
        return context.makeImage()!
    }

    static func faceScene(width: Int = 600, height: Int = 400) -> CGImage {
        let context = context(width, height)
        context.setFillColor(CGColor(srgbRed: 0.6, green: 0.75, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("AppleColorEmoji" as CFString, 220, nil)
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: "🧑", attributes: [.font: font]))
        context.textPosition = CGPoint(x: 60, y: 100)
        CTLineDraw(line, context)
        return context.makeImage()!
    }
}

enum AuditFiles {
    static func snapshot(_ urls: [URL]) throws -> [Data] {
        try urls.map { try Data(contentsOf: $0) }
    }

    static func properties(_ url: URL, index: Int = 0) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil)
                as? [CFString: Any]
        else { return [:] }
        return properties
    }

    static func gps(_ url: URL) -> [CFString: Any]? {
        guard let gps = properties(url)[kCGImagePropertyGPSDictionary] as? [CFString: Any],
            !gps.isEmpty
        else { return nil }
        return gps
    }

    static func exifValue(_ url: URL, _ key: CFString) -> Any? {
        (properties(url)[kCGImagePropertyExifDictionary] as? [CFString: Any])?[key]
    }

    static func tiffValue(_ url: URL, _ key: CFString) -> Any? {
        (properties(url)[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[key]
    }

    static func orientation(_ url: URL) -> Int {
        properties(url)[kCGImagePropertyOrientation] as? Int ?? 1
    }

    static func frameSizes(_ url: URL) -> [Int] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).compactMap {
            properties(url, index: $0)[kCGImagePropertyPixelWidth] as? Int
        }
    }

    static func frameDelays(_ url: URL) -> [Double] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return [] }
        return (0..<CGImageSourceGetCount(source)).map { index in
            let gif =
                properties(url, index: index)[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            return gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
        }
    }

    static func largestFrame(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        var best: CGImage?
        for index in 0..<CGImageSourceGetCount(source) {
            if let image = CGImageSourceCreateImageAtIndex(source, index, nil),
                image.width > (best?.width ?? 0)
            {
                best = image
            }
        }
        return try requireFixture(best)
    }
}

extension StudioRunResult {
    func output(from source: URL) throws -> URL {
        guard let match = outputs.first(where: { $0.source == source }) else {
            throw StudioError.failed("no output for \(source.lastPathComponent)")
        }
        return match.url
    }
}
