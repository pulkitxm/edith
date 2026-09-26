import CoreImage
import Foundation

public enum VirtualCameraLooks {
    public static func apply(_ look: VirtualCameraLook, to image: CIImage) -> CIImage {
        let look = look.sanitized()
        let extent = image.extent
        var result = preset(look.preset, image)
        if look.preset != .natural, look.intensity < 1 {
            result = dissolve(from: image, to: result, amount: look.intensity)
        }
        if look.exposure != 0 {
            result = result.applyingFilter(
                "CIExposureAdjust", parameters: ["inputEV": look.exposure])
        }
        if look.brightness != 0 || look.contrast != 1 || look.saturation != 1 {
            result = result.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputBrightnessKey: look.brightness,
                    kCIInputContrastKey: look.contrast,
                    kCIInputSaturationKey: look.saturation,
                ])
        }
        if look.warmth != 0 || look.tint != 0 {
            result = temperature(result, warmth: look.warmth, tint: look.tint)
        }
        if look.smoothing > 0 {
            result = result.applyingFilter(
                "CINoiseReduction",
                parameters: [
                    "inputNoiseLevel": 0.01 + look.smoothing * 0.05,
                    kCIInputSharpnessKey: 0.2,
                ])
        }
        if look.sharpness > 0 {
            result = result.applyingFilter(
                "CISharpenLuminance",
                parameters: [kCIInputSharpnessKey: look.sharpness * 0.8, kCIInputRadiusKey: 1.6])
        }
        if look.vignette > 0 {
            result = result.applyingFilter(
                "CIVignette",
                parameters: [
                    kCIInputIntensityKey: look.vignette * 1.4,
                    kCIInputRadiusKey: max(extent.width, extent.height) / 900,
                ])
        }
        return result.cropped(to: extent)
    }

    public static func thumbnails(
        from reference: CGImage, renderer: VirtualCameraRenderer
    ) -> [VirtualCameraLookPreset: CGImage] {
        let image = CIImage(cgImage: reference)
        let size = CGSize(width: reference.width, height: reference.height)
        var result: [VirtualCameraLookPreset: CGImage] = [:]
        for preset in VirtualCameraLookPreset.allCases {
            let styled = apply(VirtualCameraLook(preset: preset), to: image)
            result[preset] = renderer.cgImage(styled, size: size)
        }
        return result
    }

    public static func preset(_ preset: VirtualCameraLookPreset, _ image: CIImage) -> CIImage {
        switch preset {
        case .natural:
            return image
        case .bright:
            return
                image
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.3])
                .applyingFilter(
                    "CIHighlightShadowAdjust",
                    parameters: ["inputShadowAmount": 0.5, "inputHighlightAmount": 0.9])
        case .studio:
            return
                image
                .applyingFilter("CIExposureAdjust", parameters: ["inputEV": 0.15])
                .applyingFilter("CIHighlightShadowAdjust", parameters: ["inputShadowAmount": 0.35])
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.25])
        case .warm:
            return temperature(image, warmth: 0.55, tint: 0.05)
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.1])
        case .cool:
            return temperature(image, warmth: -0.5, tint: 0)
        case .vivid:
            return
                image
                .applyingFilter("CIVibrance", parameters: ["inputAmount": 0.8])
                .applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
        case .muted:
            return image.applyingFilter(
                "CIColorControls",
                parameters: [kCIInputSaturationKey: 0.62, kCIInputContrastKey: 0.94])
        case .film:
            return temperature(image.applyingFilter("CIPhotoEffectFade"), warmth: 0.25, tint: 0)
        case .mono:
            return image.applyingFilter("CIPhotoEffectMono")
        case .noir:
            return image.applyingFilter("CIPhotoEffectNoir")
        }
    }

    public static func temperature(_ image: CIImage, warmth: Double, tint: Double) -> CIImage {
        image.applyingFilter(
            "CITemperatureAndTint",
            parameters: [
                "inputNeutral": CIVector(x: 6500 + warmth * 2600, y: tint * 60),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
    }

    public static func dissolve(from: CIImage, to: CIImage, amount: Double) -> CIImage {
        from.applyingFilter(
            "CIDissolveTransition",
            parameters: [kCIInputTargetImageKey: to, kCIInputTimeKey: amount])
    }
}
