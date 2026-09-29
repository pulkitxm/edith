import AVFoundation

enum VideoSourceMetadata {
    static func make(
        width: Int, height: Int, fps: Double,
        frameDuration: CMTime, format: CMFormatDescription?
    ) -> [String: Any] {
        var result: [String: Any] = ["width": width, "height": height]
        if fps.isFinite, fps > 0 { result["fps"] = fps }
        if frameDuration.isNumeric, frameDuration.value > 0, frameDuration.timescale > 0 {
            result["frameRateNumerator"] = Int(frameDuration.timescale)
            result["frameRateDenominator"] = frameDuration.value
        }
        if let format {
            let codec = CMFormatDescriptionGetMediaSubType(format)
            result["codec"] =
                String(
                    bytes: [24, 16, 8, 0].map {
                        UInt8(truncatingIfNeeded: codec >> $0)
                    }, encoding: .ascii) ?? String(codec)
            let extensions = CMFormatDescriptionGetExtensions(format) as NSDictionary? ?? [:]
            for (key, name) in [
                (kCMFormatDescriptionExtension_ColorPrimaries, "colorPrimaries"),
                (kCMFormatDescriptionExtension_TransferFunction, "transferFunction"),
                (kCMFormatDescriptionExtension_YCbCrMatrix, "yCbCrMatrix"),
            ] {
                if let value = extensions[key] as? String { result[name] = value }
            }
        }
        return result
    }
}
