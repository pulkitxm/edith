import AVFoundation
import CoreImage
import Testing
@testable import Edith

@Suite struct VideoVisualTimingTests {
    @Test func everyFrameBoundarySelectsTheIncomingStill() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "visual-boundaries-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = ["red.png", "blue.png"].map { directory.appendingPathComponent($0) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        for (url, color) in zip(urls, [CIColor.red, .blue]) {
            try VideoImageContext.shared.writePNGRepresentation(
                of: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
                to: url, format: .RGBA8, colorSpace: colorSpace)
        }
        for (numerator, denominator) in [(60000, 1001), (120, 1)] {
            var project = VideoProject.create()
            project.videoSettings = VideoSettings(
                width: 64, height: 64,
                frameRateNumerator: numerator, frameRateDenominator: denominator)
            for index in 0..<40 {
                let url = urls[index % 2]
                try project.addStillAsset(
                    url, duration: project.frameDuration.seconds,
                    metadata: VideoStillMedia.metadata(at: url))
            }
            let pipeline = try await VideoRenderPipeline.make(project: project)
            let reader = try AVAssetReader(asset: pipeline.composition)
            let output = AVAssetReaderVideoCompositionOutput(
                videoTracks: try await pipeline.composition.loadTracks(withMediaType: .video),
                videoSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ])
            output.videoComposition = pipeline.videoComposition
            reader.add(output)
            #expect(reader.startReading())
            var index = 0
            while let sample = output.copyNextSampleBuffer() {
                guard CMSampleBufferGetNumSamples(sample) > 0 else { continue }
                let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
                #expect(
                    timestamp == CMTimeMultiply(project.frameDuration, multiplier: Int32(index)))
                let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
                var pixel = [UInt8](repeating: 0, count: 4)
                VideoImageContext.shared.render(
                    CIImage(cvPixelBuffer: buffer), toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: 32, y: 32, width: 1, height: 1),
                    format: .RGBA8, colorSpace: colorSpace)
                #expect(
                    pixel[index % 2 == 0 ? 0 : 2] > 220,
                    "Frame \(index) at \(numerator)/\(denominator)")
                #expect(
                    pixel[index % 2 == 0 ? 2 : 0] < 30,
                    "Frame \(index) at \(numerator)/\(denominator)")
                index += 1
            }
            #expect(reader.status == .completed)
            #expect(index == 40)
        }
    }
}
