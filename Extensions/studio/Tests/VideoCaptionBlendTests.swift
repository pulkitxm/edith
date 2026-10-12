import EdithExtensionUI
import EdithExtensionSupport
import AVFoundation
import CoreImage
import Foundation
import Testing
@testable import StudioExtension

@Suite struct VideoCaptionBlendTests {
    private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../scripts/fixtures/caption-reference")

    @Test func encodedBlackGradientHasExactCodeValuePlateaus() throws {
        let bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let foreground = CIImage(
            color: CIColor(red: 0, green: 0, blue: 0, alpha: 100.0 / 255, colorSpace: space)!
        ).cropped(to: bounds)
        for (source, expected) in [
            ([255, 255, 255], [155, 155, 155]), ([128, 128, 128], [78, 78, 78]),
            ([51, 153, 204], [31, 93, 124]),
        ] {
            let background = CIImage(
                color: CIColor(
                    red: Double(source[0]) / 255, green: Double(source[1]) / 255,
                    blue: Double(source[2]) / 255, colorSpace: space)!
            ).cropped(to: bounds)
            let actual = VideoCaptionStyleTests.pixels(
                VideoStyledCaptionImage.composite(foreground, over: background))
            #expect(Array(actual.prefix(3)).map(Int.init) == expected)
            #expect(actual[3] == 255)
        }
    }

    @Test func encodedSourceOverMatchesPillowAtEveryAlpha() throws {
        let foreground = try image("blend-foreground")
        let background = try image("blend-background")
        let reference = VideoCaptionStyleTests.pixels(try image("blend-reference"))
        let actual = VideoCaptionStyleTests.pixels(
            VideoStyledCaptionImage.composite(foreground, over: background))
        let wrong = VideoCaptionStyleTests.pixels(foreground.composited(over: background))
        let errors = zip(actual, reference).map { abs(Int($0) - Int($1)) }
        #expect(errors.max()! <= 1)
        #expect(zip(wrong, reference).contains { abs(Int($0) - Int($1)) >= 49 })
    }

    @Test(arguments: ["white", "gray", "color", "tint"])
    func nativeFrameAndExportMatchIndependentPillowComposite(_ background: String) async throws {
        let directory = try VideoEditorServiceTests.folder()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = fixtures.appendingPathComponent("background-\(background).png")
        var project = VideoProject.create(title: "Synthetic caption blend")
        project.videoSettings = .init(width: 2160, height: 3840)
        try project.addStillAsset(
            source, duration: 0.05, metadata: VideoStillMedia.metadata(at: source))
        var style = VideoCaptionStyleTests.styled
        style.metrics = .fontBounds
        if background == "tint" {
            for index in style.gradient!.stops.indices {
                style.gradient!.stops[index].color.red = 51.0 / 255
                style.gradient!.stops[index].color.green = 179.0 / 255
                style.gradient!.stops[index].color.blue = 102.0 / 255
            }
        }
        try project.addOutputCaption(
            "SYNTHETIC\nCAPTION",
            anchor: VideoCaptionAnchor(
                start: .init(frame: 0, frameRate: .init(numerator: 60)),
                end: .init(frame: 3, frameRate: .init(numerator: 60))), style: style)
        let url = directory.appendingPathComponent("synthetic.openscreen")
        try project.save(to: url)
        let preview = directory.appendingPathComponent("frame.png")
        _ = try await VideoEditorService.frame(url, at: 0, to: preview)
        if background == "white",
            let evidence = ProcessInfo.processInfo.environment["EDITH_CAPTION_BLEND_EVIDENCE"]
        {
            try Data(contentsOf: preview).write(to: URL(fileURLWithPath: evidence))
        }
        let pipeline = try await VideoRenderPipeline.make(project: project)
        let output = directory.appendingPathComponent("synthetic.mp4")
        _ = try await pipeline.export(to: output)
        let decoded = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        let exported = CIImage(cgImage: try await decoded.image(at: .zero).image)
        let referenceURL = fixtures.appendingPathComponent("composite-\(background).png")
        var control = VideoProject.create(title: "Independent Pillow codec control")
        control.videoSettings = project.videoSettings
        try control.addStillAsset(
            referenceURL, duration: 0.05,
            metadata: VideoStillMedia.metadata(at: referenceURL))
        #expect(control.annotations.isEmpty)
        let controlPipeline = try await VideoRenderPipeline.make(project: control)
        let controlOutput = directory.appendingPathComponent("pillow-control.mp4")
        let controlReport = try await controlPipeline.export(to: controlOutput)
        #expect(controlReport.frameCount == 3)
        let controlDecoder = AVAssetImageGenerator(asset: AVURLAsset(url: controlOutput))
        let controlFrame = CIImage(cgImage: try await controlDecoder.image(at: .zero).image)
        let referencePNG = VideoCaptionStyleTests.pixels(try image("composite-\(background)"))
        let referenceExport = VideoCaptionStyleTests.pixels(controlFrame)
        let plateauOffset = (3700 * 2160 + 100) * 4
        print(
            "caption Pillow codec control \(background): plateau=\(Array(referenceExport[plateauOffset..<(plateauOffset + 3)])), PNG=\(Array(referencePNG[plateauOffset..<(plateauOffset + 3)]))"
        )
        for (name, frame, reference) in [
            ("frame", try #require(CIImage(contentsOf: preview)), referencePNG),
            ("export", exported, referenceExport),
        ] {
            let actual = VideoCaptionStyleTests.pixels(frame)
            var total = 0
            var textTotal = 0
            var textCount = 0
            for y in 0..<3840 {
                for x in 0..<2160 {
                    for channel in 0..<3 {
                        let offset = (y * 2160 + x) * 4 + channel
                        let error = abs(Int(actual[offset]) - Int(reference[offset]))
                        total += error
                        if (750..<1410).contains(x) && (2750..<3080).contains(y) {
                            textTotal += error
                            textCount += 1
                        }
                    }
                }
            }
            let mean = Double(total) / (2160 * 3840 * 3)
            let textMean = Double(textTotal) / Double(textCount)
            let plateau = Array(actual[((3700 * 2160 + 100) * 4)..<((3700 * 2160 + 100) * 4 + 3)])
            print(
                "caption encoded blend \(background) \(name): mean=\(mean), text mean=\(textMean), plateau=\(plateau)"
            )
            #expect(mean <= 1)
            #expect(textMean <= 6)
            let tolerance = name == "export" && background != "white" ? 2 : 1
            for y in [2000, 2100, 2850, 3700] {
                for channel in 0..<3 {
                    let offset = (y * 2160 + 100) * 4 + channel
                    #expect(
                        abs(Int(actual[offset]) - Int(reference[offset])) <= tolerance,
                        "\(background) \(name) y=\(y) channel=\(channel): \(actual[offset]) vs \(reference[offset])"
                    )
                }
            }
        }
    }

    private func image(_ name: String) throws -> CIImage {
        try #require(CIImage(contentsOf: fixtures.appendingPathComponent("\(name).png")))
    }
}
