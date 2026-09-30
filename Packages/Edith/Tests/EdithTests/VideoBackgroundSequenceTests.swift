import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoBackgroundSequenceTests {
    @Test func eighteenOriginalsRetainFullWidthAndSinglePixelDetailAtNativeResolution() async throws
    {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 2160, height: 3840)
        var checksums: [SHA256.Digest] = []
        for index in 0..<18 {
            let height = 1080 + index * 60
            let bounds = CGRect(x: 0, y: 0, width: 2160, height: height)
            var image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: bounds)
            for (color, rect) in [
                (CIColor.red, CGRect(x: 0, y: 0, width: 20, height: height)),
                (.blue, CGRect(x: 2140, y: 0, width: 20, height: height)),
                (.green, CGRect(x: 20, y: height - 20, width: 2120, height: 20)),
                (.yellow, CGRect(x: 20, y: 0, width: 2120, height: 20)),
                (.white, CGRect(x: 720, y: 20, width: 1, height: height - 40)),
            ] {
                image = CIImage(color: color).cropped(to: rect).composited(over: image)
            }
            let url = directory.appendingPathComponent("photo-\(index).png")
            try VideoImageContext.shared.writePNGRepresentation(
                of: image, to: url, format: .RGBA8, colorSpace: colorSpace)
            checksums.append(SHA256.hash(data: try Data(contentsOf: url)))
            try project.addStillAsset(
                url, duration: 0.1, metadata: VideoStillMedia.metadata(at: url))
            try project.setVisualEffects(
                .init(framing: .fullWidth, background: .init(blurRadius: 65)),
                clipID: project.clips[index].id)
        }
        let projectURL = directory.appendingPathComponent("eighteen.openscreen")
        try project.save(to: projectURL)
        let restored = try VideoProject.open(projectURL)
        #expect(restored.clips.count == 18)
        let pipeline = try await VideoRenderPipeline.make(project: restored)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        for index in 0..<18 {
            let frame = try generator.copyCGImage(
                at: CMTime(value: Int64(index * 3 + 1), timescale: 30), actualTime: nil)
            #expect(frame.width == 2160 && frame.height == 3840)
            let image = CIImage(cgImage: frame)
            let height = 1080 + index * 60
            let bottom = (3840 - height) / 2
            for (x, y, expected) in [
                (4, 1920, [255, 0, 0]), (2156, 1920, [0, 0, 255]),
                (1080, bottom + 4, [255, 255, 0]),
                (1080, bottom + height - 4, [0, 255, 0]),
                (720, 1920, [255, 255, 255]),
            ] {
                var pixel = [UInt8](repeating: 0, count: 4)
                VideoImageContext.shared.render(
                    image, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                    colorSpace: colorSpace)
                #expect(zip(pixel.prefix(3), expected).allSatisfy { abs(Int($0) - $1) <= 8 })
            }
            var neighbors = [UInt8](repeating: 0, count: 12)
            VideoImageContext.shared.render(
                image, toBitmap: &neighbors, rowBytes: 12,
                bounds: CGRect(x: 719, y: 1920, width: 3, height: 1), format: .RGBA8,
                colorSpace: colorSpace)
            #expect(neighbors[0] < 80 && neighbors[4] > 240 && neighbors[8] < 80)
            #expect(
                SHA256.hash(data: try Data(contentsOf: restored.assets[index].url))
                    == checksums[index])
        }
    }

    @Test func orientedP3OriginalFeedsBothLayersAndEncodedExport() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("oriented.tiff")
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 128, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            try #require(CGColor(colorSpace: colorSpace, components: [0.9, 0.05, 0.02, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 128))
        context.setFillColor(
            try #require(CGColor(colorSpace: colorSpace, components: [0.02, 0.05, 0.9, 1])))
        context.fill(CGRect(x: 0, y: 64, width: 64, height: 64))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 128, height: 256, colorSpace: .displayP3)
        try project.addStillAsset(url, duration: 0.1, metadata: VideoStillMedia.metadata(at: url))
        try project.setVisualEffects(
            .init(framing: .fullWidth, background: .init(focalX: 0, blurRadius: 2)),
            clipID: project.clips[0].id)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let output = directory.appendingPathComponent("result.mp4")
        let projectURL = directory.appendingPathComponent("wide.openscreen")
        try project.save(to: projectURL)
        var settings = VideoDeliverySettings()
        settings.codec = .hevc10
        let result = try await VideoEditorService.render(projectURL, to: output, settings: settings)
        #expect(result.videoReport?.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        let native = CIImage(cgImage: try generator.copyCGImage(at: .zero, actualTime: nil))
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
        let srgbClippedBackgroundInP3 = [230, 50, 35]
        for (index, frame) in [native, CIImage(cvPixelBuffer: buffer)].enumerated() {
            for (x, y, expected) in [
                (16, 128, [230, 13, 5]), (112, 128, [5, 13, 230]),
                (16, 16, srgbClippedBackgroundInP3),
            ] {
                var pixel = [UInt8](repeating: 0, count: 4)
                VideoImageContext.shared.render(
                    frame, toBitmap: &pixel, rowBytes: 4,
                    bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                    colorSpace: colorSpace)
                #expect(
                    zip(pixel.prefix(3), expected).allSatisfy { abs(Int($0) - $1) <= 12 },
                    "output \(index), pixel \(x),\(y): \(pixel), expected \(expected)")
            }
        }
    }
}
