import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoDeliveryColorTests {
    @Test(arguments: [VideoDeliverySettings.Codec.hevc10, .proRes4444])
    func originalICCColorsSurviveProjectSelectedP3Delivery(_ codec: VideoDeliverySettings.Codec)
        async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("original-p3.png")
        let space = try #require(CGColorSpace(name: CGColorSpace.displayP3))
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let patches: [[CGFloat]] = [[0.9, 0.05, 0.02, 1], [0.03, 0.85, 0.06, 1]]
        for (index, components) in patches.enumerated() {
            context.setFillColor(try #require(CGColor(colorSpace: space, components: components)))
            context.fill(CGRect(x: index * 32, y: 0, width: 32, height: 64))
        }
        let destination = try #require(
            CGImageDestinationCreateWithURL(
                source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        try #require(CGImageDestinationFinalize(destination))
        let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        #expect(image.colorSpace?.name == CGColorSpace.displayP3)
        let original = try Data(contentsOf: source)
        let project = directory.appendingPathComponent("wide.openscreen")
        _ = try VideoEditorService.create(at: project, title: "Synthetic wide color")
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .videoSettings(
                    settings: VideoSettings(width: 64, height: 64, colorSpace: .displayP3)),
                .addStill(path: source.path, name: "original", duration: 0.25),
            ]), to: project, overwrite: true)
        let originalProject = try Data(contentsOf: project)
        let wideURL = directory.appendingPathComponent("wide.\(codec.fileExtension)")
        var settings =
            codec.isMaster ? VideoDeliverySettings.master(codec) : VideoDeliverySettings()
        settings.codec = codec
        let wide = try await VideoEditorService.render(project, to: wideURL, settings: settings)
        #expect(wide.videoReport?.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        #expect(wide.videoReport?.frameCount == 15)
        let pixels = try await Self.pixels(wideURL, in: space)
        for (pixel, expected) in zip(pixels, patches) {
            for channel in 0..<3 {
                #expect(abs(Double(pixel[channel]) / 255 - Double(expected[channel])) < 0.04)
            }
        }
        settings.colorSpace = .rec709
        let standardURL = directory.appendingPathComponent("standard.\(codec.fileExtension)")
        let standard = try await VideoEditorService.render(
            project, to: standardURL, settings: settings)
        #expect(standard.videoReport?.colorPrimaries == AVVideoColorPrimaries_ITU_R_709_2)
        let clipped = try await Self.pixels(standardURL, in: space)
        let wideChannels: [UInt8] = pixels.flatMap { $0.prefix(3) }
        let clippedChannels: [UInt8] = clipped.flatMap { $0.prefix(3) }
        let channelDifferences: [Int] = zip(wideChannels, clippedChannels).map { pair in
            let wideValue: Int = Int(pair.0)
            let clippedValue: Int = Int(pair.1)
            return abs(wideValue - clippedValue)
        }
        let gamutDifference: Int = channelDifferences.max() ?? 0
        #expect(gamutDifference > 12)
        #expect(try Data(contentsOf: source) == original)
        #expect(try Data(contentsOf: project) == originalProject)
    }

    private static func pixels(_ url: URL, in space: CGColorSpace) async throws -> [[UInt8]] {
        let asset = AVURLAsset(url: url)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: true,
            ])
        reader.add(output)
        try #require(reader.startReading())
        defer { reader.cancelReading() }
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        let context = CIContext()
        return [16, 48].map { x in
            var pixel = [UInt8](repeating: 0, count: 4)
            context.render(
                CIImage(cvPixelBuffer: buffer), toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: x, y: 32, width: 1, height: 1), format: .RGBA8,
                colorSpace: space)
            return pixel
        }
    }
}
