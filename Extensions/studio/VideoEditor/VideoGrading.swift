import CoreImage
import CoreVideo

enum VideoGrading {
    private static let video709 = CVImageBufferCreateColorSpaceFromAttachments(
        [
            kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_709_2,
            kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ] as CFDictionary)!.takeRetainedValue()

    private static let eq709 =
        (try? CIKernel.kernels(withMetalString: eq709Source))?.first as? CIColorKernel

    private static let eq709Source = """
        #include <CoreImage/CoreImage.h>
        using namespace metal;

        [[stitchable]] float4 eq709(coreimage::sample_t pixel, float4 coefficients) {
            float4 straight = coreimage::unpremultiply(pixel);
            float3 rgb = floor(clamp(straight.rgb, 0.0, 1.0) * 255.0 + 0.5);
            float y = floor((dot(rgb, float3(5983.0, 20127.0, 2032.0)) + 540928.5) / 32768.0);
            float u = floor((dot(rgb, float3(-3298.0, -11094.0, 14392.0)) + 4210944.5) / 32768.0);
            float v = floor((dot(rgb, float3(14392.0, -13073.0, -1320.0)) + 4210944.5) / 32768.0);
            y = clamp(floor(y * coefficients.x / 4096.0) + coefficients.y, 0.0, 255.0);
            u = clamp(floor(u * coefficients.z / 4096.0) + coefficients.w, 0.0, 255.0);
            v = clamp(floor(v * coefficients.z / 4096.0) + coefficients.w, 0.0, 255.0);
            float luma = (y - 16.0) * 9539.0 + 4096.0;
            float3 fixedRGB = float3(luma + (v - 128.0) * 14686.0,
                luma - (u - 128.0) * 1747.0 - (v - 128.0) * 4366.0,
                luma + (u - 128.0) * 17305.0);
            float3 result = clamp(floor(fixedRGB / 8192.0), 0.0, 255.0);
            result *= 1.0 - step(float3(4194304.0), fixedRGB);
            result /= 255.0;
            return coreimage::premultiply(float4(result, straight.a));
        }
        """

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
