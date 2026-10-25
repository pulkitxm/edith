import CoreImage

enum VideoTransitionImage {
    static let kinds = ["fade", "flash", "blur", "zoom"]

    static func apply(_ image: CIImage, kind: String, intensity: Double) -> CIImage {
        let amount = min(1, max(0, intensity))
        let eased = amount * amount * (3 - 2 * amount)
        let bounds = image.extent
        var output = image
        if kind == "blur" {
            output = image.clampedToExtent().applyingFilter(
                "CIGaussianBlur",
                parameters: [kCIInputRadiusKey: max(bounds.width, bounds.height) * 0.025 * eased]
            ).cropped(to: bounds)
        } else if kind == "zoom" {
            let scale = 1 + 0.2 * eased
            output = image.transformed(
                by: CGAffineTransform(translationX: bounds.midX, y: bounds.midY)
                    .scaledBy(x: scale, y: scale)
                    .translatedBy(x: -bounds.midX, y: -bounds.midY)
            ).cropped(to: bounds)
        }
        let color = kind == "flash" ? CIColor.white : CIColor.black
        return output.applyingFilter(
            "CIDissolveTransition",
            parameters: [
                kCIInputTargetImageKey: CIImage(color: color).cropped(to: bounds),
                kCIInputTimeKey: amount,
            ]
        ).cropped(to: bounds)
    }
}
