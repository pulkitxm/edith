import CoreImage
import Foundation

struct VideoPresentation: Codable, Equatable, Sendable {
    var gradient = false
    var gradientEnd = "#7654C4"
    var cornerRadius = 0.0
    var shadow = 0.0
    var backgroundBlur = 0.0
    var cameraRoundness = 12.0
    var cameraShadow = 0.0
    var cameraMargin = 2.0
    var cameraZoomReactive = false
    var cursorVisible = false
    var cursorSize = 1.0
    var cursorSmoothing = false

    mutating func normalize() {
        cornerRadius = bounded(cornerRadius, maximum: 20)
        shadow = bounded(shadow, maximum: 100)
        backgroundBlur = bounded(backgroundBlur, maximum: 50)
        cameraRoundness = bounded(cameraRoundness, maximum: 50)
        cameraShadow = bounded(cameraShadow, maximum: 100)
        cameraMargin = bounded(cameraMargin, maximum: 20)
        cursorSize = max(0.5, bounded(cursorSize, maximum: 4))
    }

    private func bounded(_ value: Double, maximum: Double) -> Double {
        value.isFinite ? min(maximum, max(0, value)) : 0
    }

    func backdrop(color: CIColor, wallpaper: CIImage?, bounds: CGRect) -> CIImage {
        var image = CIImage(color: color).cropped(to: bounds)
        if gradient {
            image =
                CIFilter(
                    name: "CILinearGradient",
                    parameters: [
                        "inputPoint0": CIVector(x: 0, y: bounds.height),
                        "inputPoint1": CIVector(x: bounds.width, y: 0),
                        "inputColor0": color, "inputColor1": CIColor(hex: gradientEnd),
                    ])?.outputImage?.cropped(to: bounds) ?? image
        } else if let wallpaper, wallpaper.extent.width > 0, wallpaper.extent.height > 0 {
            let fill = max(
                bounds.width / wallpaper.extent.width, bounds.height / wallpaper.extent.height)
            let scaled = wallpaper.transformed(by: CGAffineTransform(scaleX: fill, y: fill))
            image = scaled.transformed(
                by: CGAffineTransform(
                    translationX: bounds.midX - scaled.extent.midX,
                    y: bounds.midY - scaled.extent.midY)
            ).cropped(to: bounds)
        }
        return image.clampedToExtent().applyingFilter(
            "CIGaussianBlur", parameters: [kCIInputRadiusKey: backgroundBlur * bounds.width / 1920]
        ).cropped(to: bounds)
    }

    static func framed(
        _ image: CIImage, rect: CGRect, radius: Double, shadow: Double, over background: CIImage
    ) -> CIImage {
        let bounds = background.extent
        guard
            let shape = CIFilter(
                name: "CIRoundedRectangleGenerator",
                parameters: [
                    "inputExtent": CIVector(cgRect: rect),
                    "inputRadius": min(rect.width, rect.height) * radius / 100,
                    "inputColor": CIColor.white,
                ])?.outputImage
        else { return image.composited(over: background).cropped(to: bounds) }
        let mask = shape.composited(over: CIImage(color: .black).cropped(to: bounds)).cropped(
            to: bounds)
        var backdrop = background
        if shadow > 0 {
            let shade = shape.applyingFilter(
                "CIColorMatrix",
                parameters: [
                    "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
                    "inputAVector": CIVector(x: 0, y: 0, z: 0, w: shadow / 100),
                ]
            ).applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: bounds.width / 70])
                .transformed(by: CGAffineTransform(translationX: 0, y: -bounds.height / 100))
            backdrop = shade.composited(over: backdrop).cropped(to: bounds)
        }
        return image.applyingFilter(
            "CIBlendWithMask",
            parameters: [kCIInputBackgroundImageKey: backdrop, kCIInputMaskImageKey: mask]
        ).cropped(to: bounds)
    }
}

extension VideoProject {
    var presentation: VideoPresentation {
        get {
            guard let raw = root["presentation"],
                let data = try? JSONSerialization.data(withJSONObject: raw),
                var settings = try? JSONDecoder().decode(VideoPresentation.self, from: data)
            else { return VideoPresentation() }
            settings.normalize()
            return settings
        }
        set {
            var settings = newValue
            settings.normalize()
            guard let data = try? JSONEncoder().encode(settings),
                let raw = try? JSONSerialization.jsonObject(with: data)
            else { return }
            root["presentation"] = raw
        }
    }
}
