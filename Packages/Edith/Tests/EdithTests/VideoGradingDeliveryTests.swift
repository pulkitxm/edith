import AVFoundation
import CoreImage
import Testing
@testable import Edith

@Suite struct VideoGradingDeliveryTests {
    @Test(arguments: [false, true])
    func deliveryRetainsGradedImageAndUngradedCaptionColors(_ neutral: Bool) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("synthetic.png")
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: CIColor(red: 0.6, green: 0.3, blue: 0.1, colorSpace: space)!)
                .cropped(to: CGRect(x: 0, y: 0, width: 320, height: 180)),
            to: source, format: .RGBA16, colorSpace: space)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 320, height: 480, colorSpace: .displayP3)
        try project.addStillAsset(
            source, duration: 0.1, metadata: VideoStillMedia.metadata(at: source))
        project.addText("synthetic", startMs: 0, endMs: 100)
        let annotation = try #require(project.annotations.first)
        project.setAnnotationStyle(annotation.id, key: "backgroundColor", value: "#c86496")
        let effects = VideoVisualEffects(
            framing: .fullWidth, brightness: neutral ? 0 : 0.03,
            contrast: neutral ? 1 : 1.1, saturation: neutral ? 1 : 1.2,
            background: .init(blurRadius: 65), gradingMode: .ffmpeg709)
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        let url = directory.appendingPathComponent("synthetic.openscreen")
        let output = directory.appendingPathComponent("graded.mp4")
        try project.save(to: url)
        project = try VideoProject.open(url)
        let harness = VideoGradingRenderTests()
        let native = try await harness.frame(project, dimension: 480)
        let nativeBytes = VideoGradingTests().pixels(native, width: 320, height: 480)
        let captionPixels = stride(from: 0, to: nativeBytes.count, by: 4).filter {
            abs(Int(nativeBytes[$0]) - 200) <= 2 && abs(Int(nativeBytes[$0 + 1]) - 100) <= 2
                && abs(Int(nativeBytes[$0 + 2]) - 150) <= 2
        }
        #expect(captionPixels.count > 100)
        var delivery = VideoDeliverySettings()
        delivery.codec = .hevc10
        let report = try await VideoEditorService.render(url, to: output, settings: delivery)
        #expect(report.videoReport?.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        let asset = AVURLAsset(url: output)
        let reader = try AVAssetReader(asset: asset)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let decoded = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: true,
            ])
        reader.add(decoded)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try #require(decoded.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let encoded = CIImage(cvPixelBuffer: buffer)
        for (x, y) in [(160, 240), (160, 16), (100, 96)] {
            var original = [UInt8](repeating: 0, count: 4)
            var restored = original
            let bounds = CGRect(x: x, y: y, width: 1, height: 1)
            let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
            VideoImageContext.shared.render(
                native, toBitmap: &original, rowBytes: 4, bounds: bounds, format: .RGBA8,
                colorSpace: srgb)
            VideoImageContext.shared.render(
                encoded, toBitmap: &restored, rowBytes: 4, bounds: bounds, format: .RGBA8,
                colorSpace: srgb)
            let error = zip(original.prefix(3), restored.prefix(3)).map { abs(Int($0) - Int($1)) }
                .max()!
            print(
                "HEVC10 neutral=\(neutral) graded/caption sample \(x),\(y): max RGB8 difference \(error)"
            )
            #expect(error <= 4)
        }
    }
}
