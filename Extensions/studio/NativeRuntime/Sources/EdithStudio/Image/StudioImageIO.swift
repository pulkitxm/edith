import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum StudioImageFormat: String, CaseIterable, Codable, Sendable {
    case jpeg = "jpg"
    case png
    case heic
    case avif
    case gif
    case tiff
    case bmp
    case jpeg2000 = "jp2"
    case ico
    case icns
    case psd
    case pdf

    public var title: String {
        switch self {
        case .jpeg: "JPG"
        case .png: "PNG"
        case .heic: "HEIC"
        case .avif: "AVIF"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .jpeg2000: "JPEG 2000"
        case .ico: "ICO"
        case .icns: "ICNS"
        case .psd: "PSD"
        case .pdf: "PDF"
        }
    }

    public var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .png: .png
        case .heic: .heic
        case .avif: UTType("public.avif") ?? .image
        case .gif: .gif
        case .tiff: .tiff
        case .bmp: .bmp
        case .jpeg2000: UTType("public.jpeg-2000") ?? .image
        case .ico: .ico
        case .icns: .icns
        case .psd: UTType("com.adobe.photoshop-image") ?? .image
        case .pdf: .pdf
        }
    }

    public var fileExtension: String { rawValue }

    public var isLossy: Bool { [.jpeg, .heic, .avif, .jpeg2000].contains(self) }

    public var supportsAlpha: Bool { ![.jpeg, .bmp].contains(self) }

    public static func of(_ url: URL) -> StudioImageFormat? {
        switch url.pathExtension.lowercased() {
        case "jpg", "jpeg", "jpe", "jfif": .jpeg
        case "png": .png
        case "heic", "heif": .heic
        case "avif": .avif
        case "gif": .gif
        case "tif", "tiff": .tiff
        case "bmp": .bmp
        case "jp2", "j2k": .jpeg2000
        case "ico": .ico
        case "icns": .icns
        case "psd": .psd
        case "pdf": .pdf
        default: nil
        }
    }

    public static var writable: [StudioImageFormat] {
        let supported = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return allCases.filter { supported.contains($0.utType.identifier) }
    }
}

public struct StudioImageInfo: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let frames: Int
    public let hasAlpha: Bool
    public let dpi: Double?
}

public enum StudioImageIO {
    public static func info(_ url: URL) -> StudioImageInfo? {
        if url.pathExtension.lowercased() == "svg" {
            guard let image = NSImage(contentsOf: url) else { return nil }
            return StudioImageInfo(
                width: Int(image.size.width), height: Int(image.size.height), frames: 1,
                hasAlpha: true, dpi: nil)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        var width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        var height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let orientation = properties[kCGImagePropertyOrientation] as? UInt32 ?? 1
        if orientation >= 5 { swap(&width, &height) }
        return StudioImageInfo(
            width: width, height: height, frames: CGImageSourceGetCount(source),
            hasAlpha: properties[kCGImagePropertyHasAlpha] as? Bool ?? false,
            dpi: properties[kCGImagePropertyDPIWidth] as? Double)
    }

    public static func load(_ url: URL, maxPixelSize: Int? = nil) throws -> CGImage {
        if url.pathExtension.lowercased() == "svg" {
            return try rasterizeVector(url, maxPixelSize: maxPixelSize ?? 4096)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            CGImageSourceGetCount(source) > 0
        else {
            if url.pathExtension.lowercased() == "pdf" {
                return try rasterizeVector(url, maxPixelSize: maxPixelSize ?? 3000)
            }
            throw StudioError.unreadable(url.lastPathComponent)
        }
        try StudioImageIntegrity.requireComplete(url, source: source)
        return try load(source, name: url.lastPathComponent, maxPixelSize: maxPixelSize)
    }

    public static func load(_ source: CGImageSource, name: String, maxPixelSize: Int? = nil)
        throws -> CGImage
    {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longest = max(width, height)
        let target = min(maxPixelSize ?? longest, longest)
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(target, 1),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        if longest > 0,
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        {
            return image
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw StudioError.unreadable(name)
        }
        return image
    }

    public static func frames(_ url: URL) throws -> [(image: CGImage, delay: Double)] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        var frames: [(CGImage, Double)] = []
        for index in 0..<CGImageSourceGetCount(source) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else { continue }
            let properties =
                CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
            let gif = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
            let delay =
                gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double
                ?? gif?[kCGImagePropertyGIFDelayTime] as? Double ?? 0.1
            frames.append((image, delay > 0.01 ? delay : 0.1))
        }
        guard !frames.isEmpty else { throw StudioError.unreadable(url.lastPathComponent) }
        return frames
    }

    static func rasterizeVector(_ url: URL, maxPixelSize: Int) throws -> CGImage {
        guard let image = NSImage(contentsOf: url) else {
            throw StudioError.unreadable(url.lastPathComponent)
        }
        var size = image.size
        if size.width < 1 || size.height < 1 { size = CGSize(width: 1024, height: 1024) }
        let scale = Double(maxPixelSize) / max(size.width, size.height)
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw StudioError.failed("Not enough memory to draw \(url.lastPathComponent).") }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(
            in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .copy,
            fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = context.makeImage() else {
            throw StudioError.failed("\(url.lastPathComponent) could not be drawn.")
        }
        return result
    }

    public static func properties(_ url: URL) -> [CFString: Any] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return [:] }
        return properties
    }

    public struct WriteOptions {
        public var quality: Double?
        public var keepMetadataFrom: URL?
        public var keepsLocation: Bool
        public var background: StudioColor?
        public var dpi: Double?

        public init(
            quality: Double? = nil, keepMetadataFrom: URL? = nil, keepsLocation: Bool = true,
            background: StudioColor? = nil, dpi: Double? = nil
        ) {
            self.quality = quality
            self.keepMetadataFrom = keepMetadataFrom
            self.keepsLocation = keepsLocation
            self.background = background
            self.dpi = dpi
        }
    }

    public static func encode(
        _ image: CGImage, format: StudioImageFormat, options: WriteOptions = WriteOptions()
    ) throws -> Data {
        let data = NSMutableData()
        try write(image, format: format, options: options) { type in
            CGImageDestinationCreateWithData(data, type, 1, nil)
        }
        return data as Data
    }

    public static func write(
        _ image: CGImage, to url: URL, format: StudioImageFormat,
        options: WriteOptions = WriteOptions()
    ) throws {
        if format == .pdf {
            try writePDF(image, to: url, dpi: options.dpi ?? 72)
            return
        }
        if format == .icns || format == .ico {
            try writeIcon(image, to: url, format: format)
            return
        }
        try write(image, format: format, options: options) { type in
            CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil)
        }
    }

    private static func write(
        _ image: CGImage, format: StudioImageFormat, options: WriteOptions,
        make: (CFString) -> CGImageDestination?
    ) throws {
        guard let destination = make(format.utType.identifier as CFString) else {
            throw StudioError.unavailable("This Mac cannot write \(format.title) images.")
        }
        var prepared = image
        if !format.supportsAlpha || options.background != nil,
            image.alphaInfo != .none && image.alphaInfo != .noneSkipLast
                && image.alphaInfo != .noneSkipFirst
        {
            prepared = StudioImageOps.flatten(image, on: options.background ?? .white) ?? image
        }
        var properties: [CFString: Any] = [:]
        if let source = options.keepMetadataFrom {
            var original = self.properties(source)
            original[kCGImagePropertyOrientation] = 1
            if var tiff = original[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                tiff[kCGImagePropertyTIFFOrientation] = 1
                original[kCGImagePropertyTIFFDictionary] = tiff
            }
            for key in [
                kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary,
                kCGImagePropertyTIFFDictionary, kCGImagePropertyIPTCDictionary,
                kCGImagePropertyOrientation,
            ] where options.keepsLocation || key != kCGImagePropertyGPSDictionary {
                if let value = original[key] { properties[key] = value }
            }
        }
        if let quality = options.quality, format.isLossy {
            properties[kCGImageDestinationLossyCompressionQuality] = min(max(quality, 0), 1)
        }
        if let dpi = options.dpi {
            properties[kCGImagePropertyDPIWidth] = dpi
            properties[kCGImagePropertyDPIHeight] = dpi
        }
        if format == .tiff {
            var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            tiff[kCGImagePropertyTIFFCompression] = 5
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        CGImageDestinationAddImage(destination, prepared, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.failed("The \(format.title) image could not be written.")
        }
    }

    static func writePDF(_ image: CGImage, to url: URL, dpi: Double) throws {
        let size = CGSize(
            width: Double(image.width) * 72 / dpi, height: Double(image.height) * 72 / dpi)
        var box = CGRect(origin: .zero, size: size)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        context.beginPage(mediaBox: &box)
        context.interpolationQuality = .high
        context.draw(image, in: box)
        context.endPage()
        context.closePDF()
    }

    static let icnsEntries: [(size: Int, dpi: Double)] = [
        (16, 72), (32, 144), (32, 72), (64, 144), (128, 72), (256, 144), (256, 72), (512, 144),
        (512, 72), (1024, 144),
    ]

    static let icoSizes = [16, 24, 32, 48, 64, 256]

    static func writeIcon(_ image: CGImage, to url: URL, format: StudioImageFormat) throws {
        let square = StudioImageOps.squared(image) ?? image
        let entries = format == .icns ? icnsEntries : icoSizes.map { (size: $0, dpi: 72.0) }
        guard
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, format.utType.identifier as CFString, entries.count, nil)
        else { throw StudioError.unavailable("This Mac cannot write \(format.title) icons.") }
        for entry in entries {
            guard
                let scaled = StudioImageOps.resized(square, width: entry.size, height: entry.size)
            else { continue }
            let properties: [CFString: Any]? =
                format == .icns
                ? [kCGImagePropertyDPIWidth: entry.dpi, kCGImagePropertyDPIHeight: entry.dpi]
                : nil
            CGImageDestinationAddImage(destination, scaled, properties as CFDictionary?)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.failed("The icon could not be written.")
        }
    }

    public static func writeAnimatedGIF(
        _ frames: [(image: CGImage, delay: Double)], to url: URL, loopCount: Int = 0
    ) throws {
        guard !frames.isEmpty,
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL, UTType.gif.identifier as CFString, frames.count, nil)
        else { throw StudioError.failed("The GIF could not be created.") }
        CGImageDestinationSetProperties(
            destination,
            [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loopCount]
            ] as CFDictionary)
        for frame in frames {
            CGImageDestinationAddImage(
                destination, frame.image,
                [
                    kCGImagePropertyGIFDictionary: [
                        kCGImagePropertyGIFDelayTime: frame.delay,
                        kCGImagePropertyGIFUnclampedDelayTime: frame.delay,
                    ]
                ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else {
            throw StudioError.failed("The GIF could not be written.")
        }
    }
}

enum StudioImageIntegrity {
    static func requireComplete(_ url: URL, source: CGImageSource) throws {
        guard let type = CGImageSourceGetType(source) as String?,
            type == UTType.jpeg.identifier || type == UTType.png.identifier,
            let data = try? Data(contentsOf: url, options: .alwaysMapped)
        else { return }
        let complete = type == UTType.png.identifier ? pngIsComplete(data) : jpegIsComplete(data)
        guard complete else {
            throw StudioError.failed(
                "\(url.lastPathComponent) is incomplete. It may not have finished downloading or copying."
            )
        }
    }

    static func pngIsComplete(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 8
            while index + 12 <= bytes.count {
                let length =
                    Int(bytes[index]) << 24 | Int(bytes[index + 1]) << 16
                    | Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                if bytes[index + 4] == 0x49, bytes[index + 5] == 0x45, bytes[index + 6] == 0x4E,
                    bytes[index + 7] == 0x44
                {
                    return true
                }
                index += 12 + length
            }
            return false
        }
    }

    static func jpegIsComplete(_ data: Data) -> Bool {
        let scanStart: Int? = data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var index = 2
            while index + 4 <= bytes.count {
                guard bytes[index] == 0xFF else { return nil }
                let marker = bytes[index + 1]
                if marker == 0xFF {
                    index += 1
                    continue
                }
                if marker == 0xD9 { return index }
                if (0xD0...0xD7).contains(marker) || marker == 0x01 {
                    index += 2
                    continue
                }
                let length = Int(bytes[index + 2]) << 8 | Int(bytes[index + 3])
                if marker == 0xDA { return index + 2 + length }
                index += 2 + length
            }
            return bytes.count
        }
        guard let scanStart else { return true }
        guard scanStart < data.count else { return false }
        return data.range(of: Data([0xFF, 0xD9]), in: scanStart..<data.count) != nil
    }
}
