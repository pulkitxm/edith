import CoreGraphics
import EdithKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

private final class ClipboardQuickLookRequest: @unchecked Sendable {
    let request: QLThumbnailGenerator.Request

    init(_ url: URL) {
        request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: 40, height: 40), scale: 2,
            representationTypes: [.thumbnail, .icon])
    }

    func cancel() { QLThumbnailGenerator.shared.cancel(request) }
}

public enum ClipboardThumbnailRenderer {
    public static func render(_ payload: ClipboardStoredPayload) async throws -> Data? {
        try Task.checkCancellation()
        switch payload.entry.kind {
        case .image:
            return image(payload.data)
        case .file:
            guard payload.data.count <= 16_384,
                let text = String(data: payload.data, encoding: .utf8),
                let url = URL(string: text), url.isFileURL
            else { return nil }
            let request = ClipboardQuickLookRequest(url)
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let representation = try? await QLThumbnailGenerator.shared
                    .generateBestRepresentation(for: request.request)
                try Task.checkCancellation()
                return representation.flatMap { png($0.cgImage) }
            } onCancel: {
                request.cancel()
            }
        default: return nil
        }
    }

    static func image(_ data: Data) -> Data? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int,
            width > 0, height > 0, width <= 32768, height <= 32768,
            Int64(width) * Int64(height) <= 100_000_000
        else { return nil }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let visibleWidth = rotated ? height : width
        let visibleHeight = rotated ? width : height
        let ratio = min(1, min(680 / Double(visibleWidth), 80 / Double(visibleHeight)))
        let pixels = max(1, Int(ceil(Double(max(width, height)) * ratio)))
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source, 0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: pixels,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary)
        else { return nil }
        return png(image)
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination),
            output.length <= ClipboardThumbnailSnapshot.maximumBytes
        else { return nil }
        return output as Data
    }
}
