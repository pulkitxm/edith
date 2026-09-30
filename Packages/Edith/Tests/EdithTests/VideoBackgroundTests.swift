import AVFoundation
import CoreImage
import CryptoKit
import ImageIO
import Testing
@testable import Edith

@Suite struct VideoBackgroundTests {
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    @Test func originalBackgroundDoesNotInheritForegroundCropOrAnimation() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.png")
        let original = CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 400, height: 200))
        let right = CIImage(color: .blue).cropped(to: CGRect(x: 200, y: 0, width: 200, height: 200))
        try VideoImageContext.shared.writePNGRepresentation(
            of: right.composited(over: original), to: url, format: .RGBA8, colorSpace: colorSpace)
        let checksum = SHA256.hash(data: try Data(contentsOf: url))
        var project = VideoProject.create()
        project.videoSettings = VideoSettings(width: 216, height: 384)
        try project.addStillAsset(url, duration: 1, metadata: VideoStillMedia.metadata(at: url))
        let id = project.clips[0].id
        project.crop(clipID: id, x: 0.5, y: 0, width: 0.5, height: 1)
        try project.setVisualEffects(
            VideoVisualEffects(
                framing: .fullWidth, keyframes: [.init(time: 0), .init(time: 1, scale: 0.5)],
                background: VideoBackground(focalX: 0, blurRadius: 6.5)), clipID: id)
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let borders = try await VideoEditorService.reviewBorders(
            project: project, pipeline: pipeline, limit: 100)
        #expect(borders.segments[0].intentionalPresentation.contains("original_background_fill"))
        #expect(borders.segments[0].intentionalPresentation.contains("original_background_blur"))
        for time in [0.0, 0.9] {
            let image = CIImage(cgImage: try frame(pipeline, at: time))
            #expect(pixel(image, x: 108, y: 12)[0] > 240)
            #expect(pixel(image, x: 108, y: 192)[2] > 240)
            #expect(pixel(image, x: 0, y: 0)[0] > 240)
        }
        var effects = project.clips[0].visualEffects
        effects.background?.sourceCrop = .init(x: 0.5, y: 0, width: 0.5, height: 1)
        try project.setVisualEffects(effects, clipID: id)
        let cropped = try await VideoRenderPipeline.make(project: project)
        #expect(pixel(CIImage(cgImage: try frame(cropped, at: 0)), x: 108, y: 12)[2] > 240)
        #expect(SHA256.hash(data: try Data(contentsOf: url)) == checksum)
    }

    @Test func conciseSettingsRoundTripAndInvalidBackgroundsRollBack() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("edit.openscreen")
        var project = VideoProject.create()
        let source = directory.appendingPathComponent("synthetic.png")
        try VideoImageContext.shared.writePNGRepresentation(
            of: CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 32)),
            to: source, format: .RGBA8, colorSpace: colorSpace)
        try project.addStillAsset(
            source, duration: 1, metadata: VideoStillMedia.metadata(at: source))
        try project.save(to: url)
        let id = project.clips[0].id
        func plan(_ effects: [String: Any]) throws -> VideoEditPlan {
            try VideoEditPlan.decode(
                JSONSerialization.data(withJSONObject: [
                    "version": 1,
                    "operations": [["visualEffects": ["clipID": id, "effects": effects]]],
                ]))
        }
        let edit = try plan([
            "framing": "fullWidth", "background": ["blurRadius": 65], "keyframes": [["time": 0]],
        ])
        let before = try Data(contentsOf: url)
        _ = try await VideoEditorService.apply(edit, to: url, dryRun: true, overwrite: true)
        #expect(try Data(contentsOf: url) == before)
        _ = try await VideoEditorService.apply(edit, to: url, overwrite: true)
        let saved = try Data(contentsOf: url)
        let restored = try VideoProject.open(url).clips[0].visualEffects
        #expect(restored.framing == .fullWidth)
        #expect(restored.background == VideoBackground())
        #expect(restored.keyframes == [.init(time: 0)])
        for background: [String: Any] in [
            ["blurRadius": -1], ["blurRadius": 1001], ["focalY": 1.1],
            ["sourceCrop": ["x": 0.9, "y": 0, "width": 0.2, "height": 1]],
        ] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.apply(
                    try plan(["background": background]), to: url, overwrite: true)
            }
            #expect(try Data(contentsOf: url) == saved)
        }
        for background: [String: Any] in [
            ["blurRadius": "65"], ["focalZ": 1], ["sourceCrop": NSNull()],
        ] {
            #expect(throws: (any Error).self) { try plan(["background": background]) }
        }
        _ = try await VideoEditorService.apply(try plan([:]), to: url, overwrite: true)
        #expect(try VideoProject.open(url).clips[0].visualEffects == VideoVisualEffects())
    }

    @Test func previewBlurScalesAndClampedEdgesRemainOpaque() {
        let image = CIImage(color: .white).cropped(
            to: CGRect(x: 0, y: 0, width: 2160, height: 3840))
        let black = CIImage(color: .black).cropped(
            to: CGRect(x: 1080, y: 0, width: 1080, height: 3840))
        let background = VideoBackground(blurRadius: 65)
        let native = CGSize(width: 2160, height: 3840)
        let full = background.render(
            original: black.composited(over: image), canvas: native, nativeCanvas: native)
        let preview = background.render(
            original: black.composited(over: image), canvas: CGSize(width: 540, height: 960),
            nativeCanvas: native)
        for x in [0, 1, 800, 1000, 1080, 1160, 1360, 2156] {
            let nativePixel = pixel(full, x: x, y: 32)
            let previewPixel = pixel(preview, x: x / 4, y: 8)
            #expect(abs(Int(nativePixel[0]) - Int(previewPixel[0])) <= 6)
            #expect(nativePixel[3] == 255 && previewPixel[3] == 255)
        }
        #expect(pixel(full, x: 1000, y: 32)[0] < 254)
        #expect(pixel(full, x: 1160, y: 32)[0] > 1)
    }

    private func pixel(_ image: CIImage, x: Int, y: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 4)
        VideoImageContext.shared.render(
            image, toBitmap: &bytes, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1),
            format: .RGBA8, colorSpace: colorSpace)
        return bytes
    }

    private func frame(_ pipeline: VideoRenderPipeline, at time: Double) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: pipeline.composition)
        generator.videoComposition = pipeline.videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: time, preferredTimescale: 60000), actualTime: nil)
    }
}
