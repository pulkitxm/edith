import AVFoundation

enum VideoSourceMetadata {
    static func probe(_ track: AVAssetTrack) async throws -> [String: Any] {
        let size = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = CGRect(origin: .zero, size: size).applying(transform).size
        guard displayed.width.isFinite, displayed.height.isFinite,
            abs(displayed.width) >= 1, abs(displayed.height) >= 1,
            abs(displayed.width) <= 16384, abs(displayed.height) <= 16384
        else {
            throw VideoEditorService.Failure(
                "unsupported_media", "Invalid displayed video dimensions.")
        }
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await track.load(.minFrameDuration)
        let formats = try await track.load(.formatDescriptions)
        return make(
            width: Int(abs(displayed.width)), height: Int(abs(displayed.height)),
            fps: Double(fps), frameDuration: duration, format: formats.first)
    }

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
