import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Metal

public struct VirtualCameraAssets: @unchecked Sendable {
    public var logo: CIImage?
    public var background: CIImage?

    public init(logo: CIImage? = nil, background: CIImage? = nil) {
        self.logo = logo
        self.background = background
    }

    public static let none = VirtualCameraAssets()

    public static func load(for composition: VirtualCameraComposition) -> VirtualCameraAssets {
        VirtualCameraAssets(
            logo: composition.overlays.logo.isVisible
                ? image(at: composition.overlays.logo.imagePath) : nil,
            background: composition.background.mode == .image
                ? image(at: composition.background.imagePath) : nil)
    }

    public static func image(at path: String?) -> CIImage? {
        guard let path, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        return CIImage(contentsOf: url, options: [.applyOrientationProperty: true])
    }
}

public struct VirtualCameraFrameInput: @unchecked Sendable {
    public var image: CIImage
    public var composition: VirtualCameraComposition
    public var framing: VirtualCameraFraming?
    public var mask: CIImage?
    public var date: Date
    public var assets: VirtualCameraAssets

    public init(
        image: CIImage, composition: VirtualCameraComposition,
        framing: VirtualCameraFraming? = nil, mask: CIImage? = nil, date: Date = Date(),
        assets: VirtualCameraAssets = .none
    ) {
        self.image = image
        self.composition = composition
        self.framing = framing
        self.mask = mask
        self.date = date
        self.assets = assets
    }
}

public final class VirtualCameraRenderer: @unchecked Sendable {
    public let context: CIContext
    let art = VirtualCameraOverlayArt()
    public let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    public init(context: CIContext = VirtualCameraRenderer.makeContext()) {
        self.context = context
    }

    public static func makeContext() -> CIContext {
        let options: [CIContextOption: Any] = [
            .cacheIntermediates: false,
            .name: "Edith Virtual Camera",
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }

    public static func normalized(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin != .zero else { return image }
        return image.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y))
    }

    public static func oriented(_ image: CIImage, framing: VirtualCameraFraming) -> CIImage {
        var result = normalized(image)
        let turns = ((framing.quarterTurns % 4) + 4) % 4
        if turns > 0 {
            result = normalized(
                result.transformed(by: CGAffineTransform(rotationAngle: -CGFloat(turns) * .pi / 2)))
        }
        if framing.flipHorizontal {
            result = normalized(result.transformed(by: CGAffineTransform(scaleX: -1, y: 1)))
        }
        if framing.flipVertical {
            result = normalized(result.transformed(by: CGAffineTransform(scaleX: 1, y: -1)))
        }
        return result
    }

    public static func framed(
        _ image: CIImage, framing: VirtualCameraFraming, output: CGSize
    ) -> CIImage {
        let source = image.extent.size
        let crop = VirtualCameraGeometry.crop(source: source, output: output, framing: framing)
        guard crop.size.width > 0, crop.size.height > 0 else {
            return CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: output))
        }
        let scale = output.width / crop.size.width
        let transform = CGAffineTransform(
            translationX: -crop.center.x, y: -(source.height - crop.center.y)
        )
        .concatenating(CGAffineTransform(rotationAngle: -CGFloat(crop.angle) * .pi / 180))
        .concatenating(CGAffineTransform(scaleX: scale, y: scale))
        .concatenating(CGAffineTransform(translationX: output.width / 2, y: output.height / 2))
        return image.clampedToExtent().transformed(by: transform)
            .cropped(to: CGRect(origin: .zero, size: output))
    }

    public static func backgroundReplaced(
        _ image: CIImage, mask: CIImage?, background: VirtualCameraBackground,
        assets: VirtualCameraAssets
    ) -> CIImage {
        guard background.mode != .none, let mask else { return image }
        let extent = image.extent
        let maskExtent = mask.extent
        guard maskExtent.width > 0, maskExtent.height > 0 else { return image }
        let scaledMask = normalized(mask)
            .transformed(
                by: CGAffineTransform(
                    scaleX: extent.width / maskExtent.width, y: extent.height / maskExtent.height)
            )
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(extent.height / 540, 1))
            .cropped(to: extent)
        let backdrop: CIImage
        switch background.mode {
        case .none:
            return image
        case .blur:
            backdrop = blurred(image, amount: background.blur)
        case .color:
            backdrop = CIImage(color: CIColor(cgColor: background.color.cgColor)).cropped(
                to: extent)
        case .image:
            guard let picture = assets.background else { return image }
            backdrop = aspectFilled(picture, into: extent)
        }
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: scaledMask])
    }

    public static func blurred(_ image: CIImage, amount: Double) -> CIImage {
        let extent = image.extent
        let downscale: CGFloat = 0.25
        let sigma = (4 + amount * 36) * Double(extent.height) / 1080 * Double(downscale)
        return
            image
            .transformed(by: CGAffineTransform(scaleX: downscale, y: downscale))
            .clampedToExtent()
            .applyingGaussianBlur(sigma: max(sigma, 0.5))
            .transformed(by: CGAffineTransform(scaleX: 1 / downscale, y: 1 / downscale))
            .cropped(to: extent)
    }

    public static func aspectFilled(_ image: CIImage, into rect: CGRect) -> CIImage {
        let source = normalized(image)
        let size = source.extent.size
        guard size.width > 0, size.height > 0 else {
            return CIImage(color: .black).cropped(to: rect)
        }
        let scale = max(rect.width / size.width, rect.height / size.height)
        let scaledWidth = size.width * scale
        let scaledHeight = size.height * scale
        return source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(
                by: CGAffineTransform(
                    translationX: rect.minX + (rect.width - scaledWidth) / 2,
                    y: rect.minY + (rect.height - scaledHeight) / 2)
            )
            .cropped(to: rect)
    }

    public static func pictureRect(output: CGSize, border: VirtualCameraBorder) -> CGRect {
        let bounds = CGRect(origin: .zero, size: output)
        guard border.enabled else { return bounds }
        let inset = output.height * border.inset
        return bounds.insetBy(dx: inset, dy: inset)
    }

    public static func bordered(_ picture: CIImage, border: VirtualCameraBorder, output: CGSize)
        -> CIImage
    {
        let border = border.sanitized()
        guard border.enabled else { return picture }
        let bounds = CGRect(origin: .zero, size: output)
        let rect = pictureRect(output: output, border: border)
        let scaleX = rect.width / output.width
        let scaleY = rect.height / output.height
        let placed = picture.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
        let radius = output.height * border.cornerRadius
        let matte = CIImage(color: CIColor(cgColor: border.matte.cgColor)).cropped(to: bounds)
        let shape = roundedRect(rect, radius: radius)
        var result = placed.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: matte, kCIInputMaskImageKey: shape])
        let strokeWidth = output.height * border.width
        if strokeWidth > 0.5 {
            let inner = roundedRect(
                rect.insetBy(dx: strokeWidth, dy: strokeWidth),
                radius: max(radius - strokeWidth, 0))
            let ring = shape.applyingFilter(
                "CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: inner])
            let color = CIImage(color: CIColor(cgColor: border.color.cgColor)).cropped(to: bounds)
            result = color.applyingFilter(
                "CIBlendWithAlphaMask",
                parameters: [kCIInputBackgroundImageKey: result, kCIInputMaskImageKey: ring])
        }
        return result.cropped(to: bounds)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat) -> CIImage {
        let clampedRadius = min(radius, min(rect.width, rect.height) / 2)
        guard
            let filter = CIFilter(
                name: "CIRoundedRectangleGenerator",
                parameters: [
                    "inputExtent": CIVector(cgRect: rect), kCIInputRadiusKey: clampedRadius,
                    kCIInputColorKey: CIColor.white,
                ]),
            let image = filter.outputImage
        else { return CIImage(color: .white).cropped(to: rect) }
        return image
    }

    public static func placement(
        of size: CGSize, corner: VirtualCameraCorner, in rect: CGRect, margin: CGFloat
    ) -> CGPoint {
        let x = corner.isLeading ? rect.minX + margin : rect.maxX - margin - size.width
        let y = corner.isTop ? rect.maxY - margin - size.height : rect.minY + margin
        return CGPoint(x: x, y: y)
    }

    func overlaid(
        _ image: CIImage, overlays: VirtualCameraOverlays, output: CGSize, date: Date,
        assets: VirtualCameraAssets
    ) -> CIImage {
        var result = image
        let area = Self.pictureRect(output: output, border: overlays.border)
        let margin = output.height * 0.04
        if overlays.logo.isVisible, let logo = assets.logo {
            let normalizedLogo = Self.normalized(logo)
            let logoSize = normalizedLogo.extent.size
            if logoSize.width > 0, logoSize.height > 0 {
                let height = output.height * overlays.logo.size
                let scale = height / logoSize.height
                let size = CGSize(width: logoSize.width * scale, height: height)
                let origin = Self.placement(
                    of: size, corner: overlays.logo.corner, in: area, margin: margin)
                let faded = normalizedLogo.transformed(
                    by: CGAffineTransform(scaleX: scale, y: scale)
                )
                .applyingFilter(
                    "CIColorMatrix",
                    parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: overlays.logo.opacity)
                    ]
                )
                .transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                result = faded.composited(over: result)
            }
        }
        if overlays.clock.enabled,
            let clock = art.clock(overlays.clock.text(for: date), outputHeight: output.height)
        {
            let origin = Self.placement(
                of: clock.extent.size, corner: overlays.clock.corner, in: area, margin: margin)
            result = clock.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                .composited(over: result)
        }
        if let tag = art.nameTag(overlays.nameTag, outputHeight: output.height) {
            let origin = Self.placement(
                of: tag.extent.size, corner: overlays.nameTag.corner, in: area,
                margin: margin * 1.2)
            result = tag.transformed(by: CGAffineTransform(translationX: origin.x, y: origin.y))
                .composited(over: result)
        }
        return result.cropped(to: CGRect(origin: .zero, size: output))
    }

    public func compose(_ input: VirtualCameraFrameInput, output: CGSize) -> CIImage {
        let composition = input.composition
        let framing = (input.framing ?? composition.framing).sanitized()
        let oriented = Self.oriented(input.image, framing: framing)
        let replaced = Self.backgroundReplaced(
            oriented, mask: input.mask, background: composition.background, assets: input.assets)
        let framed = Self.framed(replaced, framing: framing, output: output)
        let looked = VirtualCameraLooks.apply(composition.look, to: framed)
        let bordered = Self.bordered(looked, border: composition.overlays.border, output: output)
        return overlaid(
            bordered, overlays: composition.overlays, output: output, date: input.date,
            assets: input.assets)
    }

    public func privacyImage(
        _ privacy: VirtualCameraPrivacy, message: String, backdrop: CIImage?, output: CGSize
    ) -> CIImage {
        let bounds = CGRect(origin: .zero, size: output)
        let black = CIImage(color: .black).cropped(to: bounds)
        switch privacy {
        case .live, .freeze:
            return backdrop?.cropped(to: bounds) ?? black
        case .blank:
            return black
        case .card:
            let base =
                backdrop.map {
                    Self.blurred($0.cropped(to: bounds), amount: 1)
                        .applyingFilter("CIExposureAdjust", parameters: ["inputEV": -1.4])
                        .cropped(to: bounds)
                }
                ?? CIImage(color: CIColor(red: 0.08, green: 0.08, blue: 0.1)).cropped(to: bounds)
            guard let card = art.card(message: message, size: output) else { return base }
            return card.composited(over: base).cropped(to: bounds)
        }
    }

    public func render(_ image: CIImage, into buffer: CVPixelBuffer) {
        let bounds = CGRect(
            x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)
        )
        context.render(
            image.cropped(to: bounds), to: buffer, bounds: bounds, colorSpace: colorSpace)
    }

    public func cgImage(_ image: CIImage, size: CGSize) -> CGImage? {
        context.createCGImage(
            image, from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: colorSpace)
    }
}
