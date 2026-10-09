import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import ImageIO
import Testing
@testable import StudioExtension

@Suite struct VideoVisualSourceTests {
    @Test func addedMovieRecordsActualCadenceCodecAndDisplayedDimensions() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let movie = directory.appendingPathComponent("portrait.mov")
        let cadence = CMTime(value: 1001, timescale: 60000)
        try await VideoSyntheticMovie.write(
            CIImage(color: .red).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 64)),
            to: movie, duration: CMTimeMultiply(cadence, multiplier: 30).seconds,
            frameDuration: cadence,
            transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 64, ty: 0))
        let url = directory.appendingPathComponent("source.openscreen")
        _ = try VideoEditorService.create(at: url, title: "Source metadata")
        let settings = VideoSettings(
            width: 128, height: 128, frameRateNumerator: 120, colorSpace: .displayP3)
        let result = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .videoSettings(settings: settings), .addMedia(path: movie.path, name: "portrait"),
            ]), to: url, overwrite: true)
        let project = try VideoProject.open(url)
        let metadata = try #require(project.assets[0].raw["video"] as? [String: Any])
        #expect(metadata["width"] as? Int == 64 && metadata["height"] as? Int == 128)
        #expect(metadata["codec"] as? String == "avc1")
        #expect(abs((metadata["fps"] as? Double ?? 0) - 60000.0 / 1001) < 0.00001)
        #expect(metadata["frameRateNumerator"] as? Int == 60000)
        #expect(metadata["frameRateDenominator"] as? Int == 1001)
        #expect(project.videoSettings == settings)
        let before = try Data(contentsOf: url)
        await #expect(throws: VideoEditorService.Failure.self) {
            try await VideoEditorService.apply(
                VideoEditPlan(operations: [
                    .stillDuration(clipID: result.aliases["portrait"]!, duration: 2)
                ]),
                to: url, overwrite: true)
        }
        #expect(try Data(contentsOf: url) == before)
        _ = try await VideoEditorService.apply(
            VideoEditPlan(operations: [
                .canvas(aspectRatio: "native", padding: 0, backgroundColor: "#000000")
            ]),
            to: url, overwrite: true)
        let native = try VideoProject.open(url).videoSettings
        #expect(native.width == 64 && native.height == 128)
        #expect(native.frameDuration == settings.frameDuration && native.colorSpace == .displayP3)
    }

    @Test func frameAndContactSheetSelectTheSameExactRationalBoundary() async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let sources = ["red.png", "blue.png"].map { directory.appendingPathComponent($0) }
        for (url, color) in zip(sources, [CIColor.red, .blue]) {
            try VideoImageContext.shared.writePNGRepresentation(
                of: CIImage(color: color).cropped(to: CGRect(x: 0, y: 0, width: 64, height: 64)),
                to: url, format: .RGBA8, colorSpace: colorSpace)
        }
        for (numerator, denominator, index) in [(60000, 1001, 3), (120, 1, 34)] {
            let url = directory.appendingPathComponent("frames-\(numerator).openscreen")
            _ = try VideoEditorService.create(at: url, title: "Boundary frames")
            let settings = VideoSettings(
                width: 64, height: 64, frameRateNumerator: numerator,
                frameRateDenominator: denominator)
            let operations: [VideoEditPlan.Operation] =
                [.videoSettings(settings: settings)]
                + (0..<35).map { frame in
                    .addStill(
                        path: sources[frame % 2].path, name: "frame\(frame)",
                        duration: settings.frameDuration.seconds)
                }
            _ = try await VideoEditorService.apply(
                VideoEditPlan(operations: operations), to: url, overwrite: true)
            let time = CMTimeMultiply(settings.frameDuration, multiplier: Int32(index)).seconds
            let frameURL = directory.appendingPathComponent("frame-\(numerator).png")
            _ = try await VideoEditorService.frame(url, at: time, to: frameURL)
            let image = try #require(CIImage(contentsOf: frameURL))
            var pixel = [UInt8](repeating: 0, count: 4)
            VideoImageContext.shared.render(
                image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: 32, y: 32, width: 1, height: 1), format: .RGBA8,
                colorSpace: colorSpace)
            #expect(pixel[index % 2 == 0 ? 0 : 2] > 220)
            #expect(pixel[index % 2 == 0 ? 2 : 0] < 30)
            let report = try await VideoEditorService.contactSheet(
                url, times: [time, time + settings.frameDuration.seconds * 0.1], cellWidth: 64,
                to: directory.appendingPathComponent("sheet-\(numerator).png"))
            #expect(report.frames.map(\.frame) == [Int64(index), Int64(index)])
            #expect(report.frames.allSatisfy { $0.time == time })
        }
    }
}
