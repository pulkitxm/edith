import AVFoundation
import AppKit
import CoreImage
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoVisualTests {
    @Test func rotatedMoviesMatchDisplayOrientationAcrossMixedTimeline() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transforms: [CGAffineTransform] = [
            .identity,
            .init(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0),
            .init(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 128),
            .init(a: -1, b: 0, c: 0, d: -1, tx: 128, ty: 64),
        ]
        let redPoints = [(16, 64), (64, 16), (64, 112), (112, 64)]
        let bluePoints = [(112, 64), (64, 112), (64, 16), (16, 64)]
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 128, height: 128)
        for (index, transform) in transforms.enumerated() {
            let url = directory.appendingPathComponent("orientation-\(index).mov")
            try await writeAsymmetricMovie(to: url, transform: transform)
            project.addAsset(url, duration: 1, width: 128, height: 64)
        }
        for order in [Array(0..<4), [1, 0, 3, 2]] {
            var reordered = project
            reordered.setClips(order.map { project.clips[$0] })
            let pipeline = try await VideoRenderPipeline.make(project: reordered)
            for (position, index) in order.enumerated() {
                let frame = try renderedFrame(pipeline, at: Double(position) + 0.5)
                let red = redPoints[index]
                let blue = bluePoints[index]
                #expect(try pixel(frame, x: red.0, y: red.1).redComponent > 0.8)
                #expect(try pixel(frame, x: blue.0, y: blue.1).blueComponent > 0.8)
                let generator = AVAssetImageGenerator(
                    asset: AVURLAsset(url: project.assets[index].url))
                generator.appliesPreferredTrackTransform = true
                let reference = try generator.copyCGImage(at: .zero, actualTime: nil)
                let offsetX = (128 - reference.width) / 2
                let offsetY = (128 - reference.height) / 2
                #expect(
                    try pixel(reference, x: red.0 - offsetX, y: red.1 - offsetY).redComponent > 0.8)
                #expect(
                    try pixel(reference, x: blue.0 - offsetX, y: blue.1 - offsetY).blueComponent
                        > 0.8)
            }
        }
    }

    private func writeAsymmetricMovie(to url: URL, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 128, AVVideoHeightKey: 64,
            ])
        input.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 128,
                kCVPixelBufferHeightKey as String: 64,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 64)
        let image = CIImage(color: .blue).cropped(to: CGRect(x: 64, y: 0, width: 64, height: 64))
            .composited(over: CIImage(color: .red).cropped(to: bounds))
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(5))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, try #require(adaptor.pixelBufferPool), &buffer)
            let pixelBuffer = try #require(buffer)
            VideoImageContext.shared.render(
                image, to: pixelBuffer, bounds: bounds,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            #expect(
                adaptor.append(
                    pixelBuffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)))
        }
        input.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    @Test func embeddedDisplayP3ColorSurvivesNativeRendering() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("wide-color.png")
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = try #require(
            CGContext(
                data: nil, width: 64, height: 64,
                bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(
            try #require(CGColor(colorSpace: colorSpace, components: [0.9, 0.05, 0.02, 1])))
        context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try #require(context.makeImage()), nil)
        #expect(CGImageDestinationFinalize(destination))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 64, height: 64, colorSpace: .displayP3)
        try project.addStillAsset(url, duration: 1, metadata: VideoStillMedia.metadata(at: url))
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(pipeline.videoComposition.colorPrimaries == AVVideoColorPrimaries_P3_D65)
        let frame = try renderedFrame(pipeline, at: 0)
        var pixel = [UInt8](repeating: 0, count: 4)
        VideoImageContext.shared.render(
            CIImage(cgImage: frame), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8,
            colorSpace: colorSpace)
        #expect(abs(Int(pixel[0]) - 230) < 10)
        #expect(abs(Int(pixel[1]) - 13) < 10)
        #expect(abs(Int(pixel[2]) - 5) < 10)
        let reader = try AVAssetReader(asset: pipeline.composition)
        let output = AVAssetReaderVideoCompositionOutput(
            videoTracks: try await pipeline.composition.loadTracks(withMediaType: .video),
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                AVVideoAllowWideColorKey: true,
            ])
        output.videoComposition = pipeline.videoComposition
        reader.add(output)
        #expect(reader.startReading())
        let sample = try #require(output.copyNextSampleBuffer())
        let buffer = try #require(CMSampleBufferGetImageBuffer(sample))
        VideoImageContext.shared.render(
            CIImage(cvPixelBuffer: buffer), toBitmap: &pixel, rowBytes: 4,
            bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8,
            colorSpace: colorSpace)
        #expect(abs(Int(pixel[0]) - 230) < 10)
        #expect(abs(Int(pixel[1]) - 13) < 10)
        #expect(abs(Int(pixel[2]) - 5) < 10)
        reader.cancelReading()
    }

    @Test func canvasAndFocalAnchorStayIndependentOfClipOrder() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let wide = directory.appendingPathComponent("wide.png")
        let tall = directory.appendingPathComponent("tall.png")
        let left = CIImage(color: CIColor(red: 0.9, green: 0.2, blue: 0.05))
            .cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64))
        let right = CIImage(color: CIColor(red: 0.05, green: 0.3, blue: 0.9))
            .cropped(to: CGRect(x: 64, y: 0, width: 64, height: 64))
        try VideoImageContext.shared.writePNGRepresentation(
            of: right.composited(over: left),
            to: wide, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try VideoImageContext.shared.writePNGRepresentation(
            of: left.cropped(to: CGRect(x: 0, y: 0, width: 32, height: 64)),
            to: tall, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 64, height: 64,
            frameRateNumerator: 60000, frameRateDenominator: 1001)
        try project.addStillAsset(wide, duration: 1, metadata: VideoStillMedia.metadata(at: wide))
        try project.addStillAsset(tall, duration: 1, metadata: VideoStillMedia.metadata(at: tall))
        let id = project.clips[0].id
        var effects = VideoVisualEffects()
        effects.framing = .fill
        effects.focalX = 0
        try project.setVisualEffects(effects, clipID: id)
        let leftPipeline = try await VideoRenderPipeline.make(project: project)
        #expect(try pixel(renderedFrame(leftPipeline, at: 0), x: 32, y: 32).redComponent > 0.8)
        effects.focalX = 1
        try project.setVisualEffects(effects, clipID: id)
        let rightPipeline = try await VideoRenderPipeline.make(project: project)
        #expect(try pixel(renderedFrame(rightPipeline, at: 0), x: 32, y: 32).blueComponent > 0.8)
        project.setClips(project.clips.reversed())
        let reordered = try await VideoRenderPipeline.make(project: project)
        #expect(reordered.canvas == leftPipeline.canvas)
        #expect(
            reordered.videoComposition.frameDuration == leftPipeline.videoComposition.frameDuration)
        #expect(try pixel(renderedFrame(reordered, at: 1.2), x: 32, y: 32).blueComponent > 0.8)
    }

    @Test func originalOrientedStillRendersBeyondProxyResolution() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("orientation.tiff")
        let context = try #require(
            CGContext(
                data: nil, width: 2304, height: 64,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 1152, height: 64))
        context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        context.fill(CGRect(x: 1152, y: 0, width: 1152, height: 64))
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 32, width: 1152, height: 32))
        context.setFillColor(red: 1, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 1152, y: 32, width: 1152, height: 32))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 600, y: 0, width: 1, height: 64))
        let destination = try #require(
            CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil))
        CGImageDestinationAddImage(
            destination, try #require(context.makeImage()),
            [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let metadata = try VideoStillMedia.metadata(at: url)
        let proxy = try VideoStillMedia.image(at: url, previewMaxDimension: 512)
        #expect(proxy.extent.height == 512)
        #expect(metadata.width == 64 && metadata.height == 2304)
        #expect(metadata.orientation == 6)
        #expect(metadata.colorSpace != "unknown")
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 64, height: 2304,
            frameRateNumerator: 60000, frameRateDenominator: 1001)
        try project.addStillAsset(url, duration: 0.5, metadata: metadata)
        #expect(project.assets[0].url == url)
        #expect(project.assets[0].isStill)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        #expect(pipeline.videoComposition.frameDuration == CMTime(value: 1001, timescale: 60000))
        let frame = try renderedFrame(pipeline, at: 0.2)
        let actual = NSBitmapImageRep(cgImage: frame)
        #expect(actual.pixelsWide == 64 && actual.pixelsHigh == 2304)
        #expect(try pixel(frame, x: 16, y: 16).redComponent > 0.9)
        #expect(try pixel(frame, x: 48, y: 16).greenComponent > 0.9)
        #expect(try pixel(frame, x: 48, y: 16).redComponent < 0.1)
        #expect(try pixel(frame, x: 16, y: 2288).blueComponent > 0.9)
        #expect(try pixel(frame, x: 48, y: 2288).redComponent > 0.9)
        #expect(try pixel(frame, x: 48, y: 2288).greenComponent > 0.9)
        var pixels = [UInt8](repeating: 0, count: 64 * 2304 * 4)
        VideoImageContext.shared.render(
            CIImage(cgImage: frame), toBitmap: &pixels, rowBytes: 64 * 4,
            bounds: CGRect(x: 0, y: 0, width: 64, height: 2304), format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var brightRows = 0
        var maximumDifference = CGFloat.zero
        for y in 0..<2304 {
            let red: CGFloat = y < 1152 ? 1 : 0
            let green: CGFloat = y == 600 ? 1 : 0
            let blue: CGFloat = y == 600 || y >= 1152 ? 1 : 0
            let offset = (y * 64 + 16) * 4
            maximumDifference = max(
                maximumDifference,
                abs(CGFloat(pixels[offset]) / 255 - red),
                abs(CGFloat(pixels[offset + 1]) / 255 - green),
                abs(CGFloat(pixels[offset + 2]) / 255 - blue))
            if pixels[offset + 1] > 204 { brightRows += 1 }
        }
        #expect(brightRows == 1)
        #expect(maximumDifference < 0.08)
        let preview = try await VideoRenderPipeline.make(
            project: project, maxDimension: 512, previewOnly: true)
        #expect(preview.canvas.height == 512)
        #expect(pipeline.canvas.height == 2304)
        try project.setStillDuration(123.456, clipID: project.clips[0].id)
        let extended = try await VideoRenderPipeline.make(project: project)
        #expect(abs(extended.duration - 123.456) < 0.0001)
        #expect(try renderedFrame(extended, at: 100).height == 2304)
        #expect(project.assets[0].duration == 0.5)
    }

    @Test func rationalAndHighFrameRatesReachEncodedOutput() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("gray.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(
                to: CGRect(x: 0, y: 0, width: 64, height: 64)),
            to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        for (numerator, denominator) in [(60000, 1001), (120, 1)] {
            var project = VideoProject.create()
            project.videoSettings = VideoSettings(
                width: 64, height: 64,
                frameRateNumerator: numerator, frameRateDenominator: denominator)
            try project.addStillAsset(
                url, duration: 0.5, metadata: VideoStillMedia.metadata(at: url))
            let pipeline = try await VideoRenderPipeline.make(project: project)
            let output = directory.appendingPathComponent("rate-\(numerator).mp4")
            try await pipeline.exportMP4(to: output)
            let asset = AVURLAsset(url: output)
            let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
            #expect(try await track.load(.naturalSize) == CGSize(width: 64, height: 64))
            let reader = try AVAssetReader(asset: asset)
            let samples = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            reader.add(samples)
            #expect(reader.startReading())
            var times: [CMTime] = []
            while let sample = samples.copyNextSampleBuffer() {
                if CMSampleBufferGetNumSamples(sample) > 0 {
                    times.append(CMSampleBufferGetPresentationTimeStamp(sample))
                }
            }
            times.sort()
            #expect(reader.status == .completed)
            #expect(times.count >= Int(project.videoSettings.frameRate * 0.5) - 1)
            let invalidGaps = zip(times, times.dropFirst()).map { $1 - $0 }.filter {
                $0 != project.frameDuration
            }
            #expect(invalidGaps.isEmpty)
        }
    }

    @Test func gradingAndAnimationChangeRenderedPixels() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("color.png")
        let image = CIImage(color: CIColor(red: 0.4, green: 0.2, blue: 0.1))
            .cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32))
        try VideoImageContext.shared.writePNGRepresentation(
            of: image, to: url, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 64, height: 64)
        project.backgroundColor = "#000000"
        try project.addStillAsset(url, duration: 1, metadata: VideoStillMedia.metadata(at: url))
        var effects = VideoVisualEffects()
        effects.exposure = 1
        effects.brightness = 0.1
        effects.contrast = 1.2
        effects.saturation = 0
        effects.keyframes = [
            .init(time: 0, interpolation: .smooth),
            .init(time: 1, scale: 1.045, positionX: 0.1, rotation: 10),
        ]
        let sampled = effects.sample(at: 0.25)
        #expect(abs(sampled.scale - 1.00703125) < 0.00000001)
        #expect(abs(sampled.positionX - 0.015625) < 0.00000001)
        #expect(abs(sampled.rotation - 1.5625) < 0.00000001)
        effects.keyframes[0].interpolation = .linear
        #expect(abs(effects.sample(at: 0.25).scale - 1.01125) < 0.00000001)
        let baseline = try await VideoRenderPipeline.make(project: project)
        let base = try pixel(renderedFrame(baseline, at: 0), x: 32, y: 32)
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        let graded = try await VideoRenderPipeline.make(project: project)
        let result = try pixel(renderedFrame(graded, at: 0), x: 32, y: 32)
        #expect(abs(result.redComponent - result.greenComponent) < 0.03)
        #expect(result.greenComponent > base.greenComponent + 0.1)
        let fitCorner = try pixel(renderedFrame(graded, at: 0), x: 32, y: 2)
        #expect(fitCorner.redComponent < 0.05)
        effects.framing = .fill
        effects.focalX = 0
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        let filled = try await VideoRenderPipeline.make(project: project)
        #expect(try pixel(renderedFrame(filled, at: 0), x: 32, y: 2).redComponent > 0.15)
        effects.framing = .fit
        effects.keyframes = [.init(time: 0), .init(time: 0.5, positionY: 0.5, rotation: 90)]
        try project.setVisualEffects(effects, clipID: project.clips[0].id)
        let animated = try await VideoRenderPipeline.make(project: project)
        #expect(try pixel(renderedFrame(animated, at: 0), x: 4, y: 32).redComponent > 0.1)
        #expect(try pixel(renderedFrame(animated, at: 0.6), x: 4, y: 32).redComponent < 0.05)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "visual-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func renderedFrame(_ pipeline: VideoRenderPipeline, at seconds: Double) throws
        -> CGImage
    {
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 60000), actualTime: nil)
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        try #require(NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
    }

    @Test func settingsRoundTripAndRejectInvalidValues() throws {
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(
            width: 3840, height: 2160, frameRateNumerator: 60000,
            frameRateDenominator: 1001, colorSpace: .displayP3)
        #expect(project.frameDuration == CMTime(value: 1001, timescale: 60000))
        let data = try JSONSerialization.data(withJSONObject: project.root)
        let restored = VideoProject(
            root: try #require(JSONSerialization.jsonObject(with: data) as? [String: Any]))
        #expect(restored.videoSettings == project.videoSettings)
        for key in ["width", "height", "frameRateNumerator", "frameRateDenominator"] {
            var invalid = project
            var raw = project.videoSettings.raw
            raw[key] = 0
            invalid.root["edithVideoSettings"] = raw
            #expect(throws: VideoSettings.ValidationError.self) {
                try invalid.validateVideoSettings()
            }
        }
        var invalid = project.videoSettings
        invalid.width = 1919
        #expect(!invalid.isValid)
        invalid.width = 1920
        invalid.frameRateNumerator = 120
        invalid.frameRateDenominator = 1
        #expect(invalid.isValid)
        project.addAsset(
            URL(fileURLWithPath: "/synthetic/portrait.mov"), duration: 2, width: 1080, height: 1920)
        #expect(project.videoSettings == restored.videoSettings)
        #expect((project.assets[0].raw["video"] as? [String: Any])?["fps"] == nil)
        var effects = VideoVisualEffects()
        effects.keyframes = [.init(time: 1), .init(time: 1, scale: 1.045)]
        #expect(throws: VideoVisualEffects.VisualError.self) {
            try project.setVisualEffects(effects, clipID: project.clips[0].id)
        }
        #expect(throws: VideoVisualEffects.VisualError.self) {
            try VideoVisualEffects.decode("invalid")
        }
        effects.keyframes = [.init(time: 0, scale: -1)]
        #expect(!effects.isValid)
        effects.keyframes = []
        effects.exposure = .infinity
        #expect(!effects.isValid)
    }
}
