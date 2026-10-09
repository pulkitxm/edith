import CoreImage
import CoreVideo

enum VideoGrading {
    private static let video709 = CVImageBufferCreateColorSpaceFromAttachments(
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary)!.takeRetainedValue()

    private static let eq709 = CIColorKernel(
        source: """
            kernel vec4 eq709(__sample pixel, vec4 coefficients) {
                vec4 straight = unpremultiply(pixel);
                vec3 rgb = floor(clamp(straight.rgb, 0.0, 1.0) * 255.0 + 0.5);
                float y = floor((dot(rgb, vec3(5983.0, 20127.0, 2032.0)) + 540928.5) / 32768.0);
                float u = floor((dot(rgb, vec3(-3298.0, -11094.0, 14392.0)) + 4210944.5) / 32768.0);
                float v = floor((dot(rgb, vec3(14392.0, -13073.0, -1320.0)) + 4210944.5) / 32768.0);
                y = clamp(floor(y * coefficients.x / 4096.0) + coefficients.y, 0.0, 255.0);
                u = clamp(floor(u * coefficients.z / 4096.0) + coefficients.w, 0.0, 255.0);
                v = clamp(floor(v * coefficients.z / 4096.0) + coefficients.w, 0.0, 255.0);
                float luma = (y - 16.0) * 9539.0 + 4096.0;
                vec3 fixedRGB = vec3(luma + (v - 128.0) * 14686.0,
                    luma - (u - 128.0) * 1747.0 - (v - 128.0) * 4366.0,
                    luma + (u - 128.0) * 17305.0);
                vec3 result = clamp(floor(fixedRGB / 8192.0), 0.0, 255.0);
                result *= 1.0 - step(vec3(4194304.0), fixedRGB);
                result /= 255.0;
                return premultiply(vec4(result, straight.a));
            }
            """)

    static func apply(_ image: CIImage, effects: VideoVisualEffects) -> CIImage? {
        let contrast = Double(Float(effects.contrast))
        let brightness = Double(Float(effects.brightness))
        let saturation = Double(Float(effects.saturation))
        let lumaScale = Int(contrast * 4096)
        let chromaScale = Int(saturation * 4096)
        let lumaOffset =
            contrast == 1 && brightness == 0
            ? 0
            : Int(100 * brightness + 100) * 511 / 200 - 128 - lumaScale / 32
        let chromaOffset = saturation == 1 ? 0 : 127 - chromaScale / 32
        let encoded: CIImage
        if effects.gradingDomain == .srgb {
            encoded = image.applyingFilter("CILinearToSRGBToneCurve")
        } else {
            guard let matched = image.matchedFromWorkingSpace(to: video709) else { return nil }
            encoded = matched
        }
        guard
            let graded = eq709?.apply(
                extent: image.extent,
                arguments: [
                    encoded,
                    CIVector(
                        x: CGFloat(lumaScale), y: CGFloat(lumaOffset),
                        z: CGFloat(chromaScale), w: CGFloat(chromaOffset)),
                ])
        else { return nil }
        if effects.gradingDomain == .bt709 {
            return graded.matchedToWorkingSpace(from: video709)
        }
        return graded.applyingFilter("CISRGBToneCurveToLinear")
    }
}
