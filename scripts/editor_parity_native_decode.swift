import AVFoundation
import CoreImage
import Foundation

@main struct NativeAppearanceDecoder {
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 5, let width = Int(arguments[2]), let height = Int(arguments[3]),
            width > 0, height > 0
        else { throw failure("Invalid appearance decoder arguments") }
        let frames = try JSONDecoder().decode([Int].self, from: Data(arguments[4].utf8))
        guard let last = frames.max(), frames == frames.sorted(), Set(frames).count == frames.count,
            frames.allSatisfy({ $0 >= 0 })
        else { throw failure("Invalid appearance frame selection") }
        let asset = AVURLAsset(url: URL(fileURLWithPath: arguments[1]))
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw failure("Missing video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: true,
            ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? failure("Native decode failed") }
        defer { reader.cancelReading() }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: space])
        let selected = Set(frames)
        var index = 0
        var emitted = 0
        while index <= last, let sample = output.copyNextSampleBuffer() {
            defer { index += 1 }
            guard selected.contains(index) else { continue }
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                throw failure("Missing decoded image buffer")
            }
            let image = CIImage(cvPixelBuffer: buffer)
            let scale = Double(height) / image.extent.height
            let scaled = image.applyingFilter(
                "CILanczosScaleTransform",
                parameters: [
                    kCIInputScaleKey: scale,
                    kCIInputAspectRatioKey: Double(width) / image.extent.width / scale,
                ])
            guard
                let raster = context.createCGImage(
                    scaled, from: CGRect(x: 0, y: 0, width: width, height: height),
                    format: .RGBA8, colorSpace: space),
                let bytes = raster.dataProvider?.data
            else { throw failure("Could not normalize decoded appearance to sRGB") }
            let source = CFDataGetBytePtr(bytes)!
            var rgb = [UInt8](repeating: 0, count: width * height * 3)
            for row in 0..<height {
                for column in 0..<width {
                    let offset = row * raster.bytesPerRow + column * 4
                    let target = (row * width + column) * 3
                    rgb[target] = source[offset]
                    rgb[target + 1] = source[offset + 1]
                    rgb[target + 2] = source[offset + 2]
                }
            }
            try FileHandle.standardOutput.write(contentsOf: Data(rgb))
            emitted += 1
        }
        guard reader.status != .failed, emitted == frames.count else {
            throw reader.error ?? failure("Native decode did not produce every selected frame")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(
            domain: "NativeAppearanceDecoder", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message])
    }
}
