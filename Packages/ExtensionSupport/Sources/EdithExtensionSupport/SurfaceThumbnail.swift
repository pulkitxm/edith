import CoreGraphics
import Foundation
import ImageIO

public struct SurfaceThumbnail: Codable, Equatable, Sendable {
    public let data: Data
    public let accessibilityLabel: String
    public let field: String?

    public init(data: Data, accessibilityLabel: String = "Thumbnail", field: String? = nil) {
        self.data = data; self.accessibilityLabel = accessibilityLabel; self.field = field
    }

    public func validate() throws {
        _ = try validatedSource()
    }

    public func decodedImage(maximumDimension: Int = 160) throws -> CGImage {
        guard (1...1024).contains(maximumDimension) else { throw ExtensionPeerError.invalidRequest }
        let source = try validatedSource()
        let options: CFDictionary =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension,
                kCGImageSourceShouldCacheImmediately: true,
            ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            throw ExtensionPeerError.invalidRequest
        }
        return image
    }

    private func completeContainer(type: String) -> Bool {
        if type == "public.jpeg" { return data.suffix(2) == Data([255, 217]) }
        return data.suffix(12) == Data([0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130])
    }

    private func validatedSource() throws -> CGImageSource {
        guard !data.isEmpty, data.count <= 131_072,
            SurfaceSnapshot.validText(accessibilityLabel, maximum: 256),
            field.map({ SurfaceSnapshot.validText($0, maximum: 80) }) ?? true,
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            let type = CGImageSourceGetType(source) as String?,
            ["public.png", "public.jpeg"].contains(type),
            completeContainer(type: type),
            CGImageSourceGetCount(source) == 1,
            CGImageSourceGetStatus(source) == .statusComplete,
            CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
            let properties = CGImageSourceCopyPropertiesAtIndex(
                source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            (1...1024).contains(width), (1...1024).contains(height), width * height <= 1_000_000
        else { throw ExtensionPeerError.invalidRequest }
        return source
    }
}
