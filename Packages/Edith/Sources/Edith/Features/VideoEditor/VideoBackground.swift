import CoreImage
import Foundation

public struct VideoBackground: Codable, Equatable, Sendable {
    public struct Crop: Codable, Equatable, Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }

        var isValid: Bool {
            [x, y, width, height].allSatisfy(\.isFinite)
                && (0...0.95).contains(x) && (0...0.95).contains(y)
                && (0.05...1).contains(width) && (0.05...1).contains(height)
                && x + width <= 1 && y + height <= 1
        }

        func rect(in extent: CGRect) -> CGRect {
            CGRect(
                x: extent.minX + extent.width * x,
                y: extent.minY + extent.height * (1 - y - height),
                width: extent.width * width, height: extent.height * height)
        }
    }

    public var framing: VideoVisualEffects.Framing
    public var focalX: Double
    public var focalY: Double
    public var blurRadius: Double
    public var sourceCrop: Crop?

    public init(
        framing: VideoVisualEffects.Framing = .fill, focalX: Double = 0.5,
        focalY: Double = 0.5, blurRadius: Double = 65, sourceCrop: Crop? = nil
    ) {
        self.framing = framing
        self.focalX = focalX
        self.focalY = focalY
        self.blurRadius = blurRadius
        self.sourceCrop = sourceCrop
    }

    private enum CodingKeys: String, CodingKey {
        case framing, focalX, focalY, blurRadius, sourceCrop
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            framing: try values.decodeIfPresent(VideoVisualEffects.Framing.self, forKey: .framing)
                ?? .fill,
            focalX: try values.decodeIfPresent(Double.self, forKey: .focalX) ?? 0.5,
            focalY: try values.decodeIfPresent(Double.self, forKey: .focalY) ?? 0.5,
            blurRadius: try values.decodeIfPresent(Double.self, forKey: .blurRadius) ?? 65,
            sourceCrop: try values.decodeIfPresent(Crop.self, forKey: .sourceCrop))
    }

    var isValid: Bool {
        [focalX, focalY, blurRadius].allSatisfy(\.isFinite)
            && (0...1).contains(focalX) && (0...1).contains(focalY)
            && (0...1000).contains(blurRadius) && (sourceCrop?.isValid ?? true)
    }

    func render(original: CIImage, canvas: CGSize, nativeCanvas: CGSize) -> CIImage {
        let source = sourceCrop?.rect(in: original.extent) ?? original.extent
        let image = original.cropped(to: source).transformed(
            by: CGAffineTransform(translationX: -source.minX, y: -source.minY))
        let placement = VideoVisualEffects(framing: framing, focalX: focalX, focalY: focalY)
        let placed = image.transformed(
            by: placement.transform(source: source.size, canvas: canvas, padding: 0, at: 0))
        let bounds = CGRect(origin: .zero, size: canvas)
        let visible = placed.extent.intersection(bounds)
        let radius =
            blurRadius
            * min(
                canvas.width / nativeCanvas.width, canvas.height / nativeCanvas.height)
        return placed.clampedToExtent().applyingFilter(
            "CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]
        ).cropped(to: visible)
    }
}
