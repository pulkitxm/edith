import AVFoundation
import CoreImage
import CoreText
import Foundation
import Testing
@testable import Edith

@Suite struct VideoCaptionStyleTests {
    static var styled: VideoCaptionStyle {
        var style = VideoCaptionStyle()
        style.outline = .init()
        style.shadow = .init(
            strokeWidth: 7, color: .init(alpha: 230.0 / 255),
            strokeColor: .init(alpha: 150.0 / 255))
        style.gradient = .init(
            startY: 2100, endY: 3600,
            stops: [
                .init(location: 0, color: .init(alpha: 0)),
                .init(location: 1, color: .init(alpha: 100.0 / 255)),
            ])
        return style
    }

    @Test func exactFontAndMultilineLayout() throws {
        var style = Self.styled
        style.fontStyle = "BoldItalic"
        #expect(CTFontCopyPostScriptName(try style.font()) as String == "Arial-BoldItalicMT")
        for size in [104.0, 112.0] {
            style.fontSize = size
            let lines = try VideoStyledCaptionImage.layout("SYNTHETIC\nCAPTION", style: style)
            #expect(lines.count == 2)
            #expect(lines[0].baseline.y - lines[1].baseline.y == 150)
            #expect(
                abs(
                    style.canvasHeight - lines[0].baseline.y - CTFontGetAscent(try style.font())
                        - 2780) < 0.001)
            for line in lines {
                let width = CTLineGetTypographicBounds(line.text, nil, nil, nil)
                #expect(abs(line.baseline.x + width / 2 - 1080) < 0.001)
            }
        }
        style.fontFamily = "Missing Synthetic Font 4921"
        do { try style.validate(); Issue.record("Missing font accepted") } catch let error
            as VideoEditorService.Failure
        { #expect(error.code == "font_not_found") }
        style = Self.styled
        style.fontStyle = "Missing face"
        #expect(throws: (any Error).self) { try style.validate() }
    }

    @Test func integerGlyphPositionsPreventAccumulatedFractionalAdvance() throws {
        var style = Self.styled
        style.metrics = .fontBounds
        let line = try #require(
            VideoStyledCaptionImage.layout(
                "little firm rivers drift far from terrain", style: style
            ).first)
        let font = try #require(line.font)
        let glyphs = try #require(line.integerGlyphs)
        var advances = [CGSize](repeating: .zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var integer: CGFloat = 0
        var fractional: CGFloat = 0
        var maximumDrift: CGFloat = 0
        for index in glyphs.indices {
            #expect(line.integerPositions[index].x == integer)
            maximumDrift = max(maximumDrift, abs(integer - fractional))
            integer += advances[index].width.rounded()
            fractional += advances[index].width
        }
        #expect(maximumDrift > 2)
        style.metrics = .typographic
        #expect(
            try VideoStyledCaptionImage.layout(
                "little firm rivers drift far from terrain", style: style
            ).first?.integerGlyphs == nil)
    }

    @Test func rejectsInvalidColorsGeometryAndNestedFields() throws {
        for value in [Double.nan, .infinity, -1, 1.1] {
            var style = Self.styled
            style.fill.alpha = value
            #expect(throws: (any Error).self) { try style.validate() }
        }
        for value in [Double.nan, .infinity, -1, 5000] {
            var style = Self.styled
            style.fontSize = value
            #expect(throws: (any Error).self) { try style.validate() }
        }
        var style = Self.styled
        style.y = 3800
        #expect(throws: (any Error).self) {
            try VideoStyledCaptionImage.layout("TWO\nLINES", style: style)
        }
        var raw = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(Self.styled)) as? [String: Any])
        var shadow = try #require(raw["shadow"] as? [String: Any])
        shadow["typo"] = 2
        raw["shadow"] = shadow
        #expect(throws: (any Error).self) {
            try VideoCaptionStyle.decode(JSONSerialization.data(withJSONObject: raw))
        }
    }

    @Test func outlineAndOffsetShadowKeepTheirOwnColorsAndOpacity() throws {
        var style = VideoCaptionStyle()
        style.canvasWidth = 400
        style.canvasHeight = 400
        style.width = 300
        style.x = 200
        style.y = 80
        style.fill = .init(red: 1)
        style.outline = .init(width: 4, color: .init(green: 1, alpha: 0.5))
        style.shadow = .init(x: 70, y: 60, blur: 0, color: .init(blue: 1, alpha: 0.4))
        var project = VideoProject.create(title: "Synthetic effect channels")
        project.addText("I", startMs: 0, endMs: 1000)
        let caption = try #require(project.annotations.first)
        let image = try #require(
            VideoStyledCaptionImage.make(
                caption, style: style, size: CGSize(width: 400, height: 400)))
        let bytes = Self.pixels(image)
        let red = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] > 200 && bytes[$0 + 1] < 10 && bytes[$0 + 2] < 10
        }
        let green = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] == 0 && bytes[$0 + 1] > 100 && bytes[$0 + 2] == 0
        }
        let blue = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] < 10 && bytes[$0 + 1] < 10 && bytes[$0 + 2] > 80
        }
        #expect(red.count > 100 && green.count > 100 && blue.count > 100)
        #expect(green.map { bytes[$0 + 3] }.max() == 128)
        #expect(blue.map { bytes[$0 + 3] }.max() == 102)
        let redX = try #require(red.map { $0 / 4 % 400 }.min())
        let blueX = try #require(blue.map { $0 / 4 % 400 }.min())
        let redY = try #require(red.map { $0 / 4 / 400 }.max())
        let blueY = try #require(blue.map { $0 / 4 / 400 }.max())
        #expect(abs(blueX - redX - 70) <= 1)
        #expect(abs(blueY - redY - 60) <= 1)
    }

    @Test func rasterHasScaledTextAndExactGradientExtent() throws {
        var project = VideoProject.create(title: "Synthetic typography")
        let rate = try VideoCaptionFrameRate(numerator: 60)
        let anchor = try VideoCaptionAnchor(
            start: .init(frame: 0, frameRate: rate), end: .init(frame: 60, frameRate: rate))
        try project.addOutputCaption("SYNTHETIC\nCAPTION", anchor: anchor, style: Self.styled)
        let caption = try #require(project.annotations.first)
        for scale in [1.0, 0.25] {
            let size = CGSize(width: 2160 * scale, height: 3840 * scale)
            let image = try #require(
                VideoStyledCaptionImage.make(caption, style: Self.styled, size: size))
            let pixels = Self.pixels(image)
            func alpha(_ y: Double) -> Int {
                Int(pixels[(Int(y * scale) * Int(size.width) + 1) * 4 + 3])
            }
            #expect(alpha(2000) == 0)
            #expect(abs(alpha(2850) - 50) <= 1)
            #expect(abs(alpha(3700) - 100) <= 1)
            let bright = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] > 200 }
            #expect(bright.count > Int(2000 * scale * scale))
            let top = bright.map { Double($0 / 4 / Int(size.width)) / scale }.min()!
            #expect((2780...2810).contains(top))
        }
    }

    @Test func styledCRUDDryRunAndFailurePreserveAnchorsAndBytes() async throws {
        let (directory, url, _) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await VideoEditorService.changeCaption(
            .add(
                content: "SYNTHETIC\nCAPTION", start: .frame(12), end: .frame(24), rate: .project,
                style: Self.styled), in: url)
        let id = try #require(report.captionID)
        #expect(report.captions.first?.style == Self.styled)
        let before = try Data(contentsOf: url)
        var changed = Self.styled
        changed.fontSize = 112
        let preview = try await VideoEditorService.changeCaption(
            .update(id: id, content: nil, start: nil, end: nil, rate: nil, style: changed), in: url,
            dryRun: true)
        #expect(preview.captions.first?.style == changed)
        #expect(preview.captions.first?.anchor == report.captions.first?.anchor)
        #expect(try Data(contentsOf: url) == before)
        changed.fontFamily = "Missing Synthetic Font 4921"
        do {
            _ = try await VideoEditorService.changeCaption(
                .update(id: id, content: nil, start: nil, end: nil, rate: nil, style: changed),
                in: url)
            Issue.record("Missing font accepted")
        } catch {}
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func nativePreviewAndExportRenderTheSameStyledOutputFrames() async throws {
        let (directory, url, initial) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        var project = initial
        var settings = project.videoSettings
        settings.width = 2160
        settings.height = 3840
        project.videoSettings = settings
        var framing = VideoVisualEffects()
        framing.framing = .fill
        for clip in project.clips { try project.setVisualEffects(framing, clipID: clip.id) }
        let rate = try VideoCaptionFrameRate(numerator: 60)
        let anchor = try VideoCaptionAnchor(
            start: .init(frame: 12, frameRate: rate), end: .init(frame: 24, frameRate: rate))
        var renderStyle = Self.styled
        renderStyle.metrics = .fontBounds
        try project.addOutputCaption("SYNTHETIC\nCAPTION", anchor: anchor, style: renderStyle)
        try project.save(to: url)
        let frameFile = directory.appendingPathComponent("full-resolution.png")
        let frameReport = try await VideoEditorService.frame(url, frameIndex: 12, to: frameFile)
        #expect(frameReport.frame == 12)
        let fullFrame = try #require(CIImage(contentsOf: frameFile))
        #expect(fullFrame.extent.size == CGSize(width: 2160, height: 3840))
        if let path = ProcessInfo.processInfo.environment["EDITH_STYLED_CAPTION_EVIDENCE"] {
            try Data(contentsOf: frameFile).write(to: URL(fileURLWithPath: path))
        }
        let preview = try await VideoRenderPipeline.make(
            project: project, maxDimension: 960, previewOnly: true)
        let delivery = try await VideoRenderPipeline.make(project: project, maxDimension: 960)
        let native = AVAssetImageGenerator(asset: preview.composition)
        native.videoComposition = preview.videoComposition
        let output = directory.appendingPathComponent("styled.mp4")
        try await delivery.exportMP4(to: output)
        let exported = AVAssetImageGenerator(asset: AVURLAsset(url: output))
        for generator in [native, exported] {
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
        }
        for frame: Int64 in [11, 12, 23, 24] {
            var bounds: [CGRect] = []
            for generator in [native, exported] {
                let frameImage = try await generator.image(at: CMTime(value: frame, timescale: 60))
                    .image
                let image = CIImage(cgImage: frameImage)
                let bytes = Self.pixels(image)
                let bright = stride(from: 0, to: bytes.count, by: 4).filter {
                    bytes[$0] > 200 && bytes[$0 + 1] > 200 && bytes[$0 + 2] > 200
                }
                #expect(!bright.isEmpty == (frame >= 12 && frame < 24))
                if !bright.isEmpty {
                    let x = bright.map { $0 / 4 % frameImage.width }
                    let y = bright.map { $0 / 4 / frameImage.width }
                    bounds.append(
                        CGRect(
                            x: x.min()!, y: y.min()!, width: x.max()! - x.min()!,
                            height: y.max()! - y.min()!))
                }
            }
            if bounds.count == 2 {
                #expect(abs(bounds[0].minX - bounds[1].minX) <= 2)
                #expect(abs(bounds[0].minY - bounds[1].minY) <= 2)
                #expect(abs(bounds[0].width - bounds[1].width) <= 2)
                #expect(abs(bounds[0].height - bounds[1].height) <= 2)
            }
        }
    }

    @Test @MainActor func nativeMoveResizeAndUndoKeepPixelStylesEditable() async throws {
        let (directory, url, _) = try await VideoOutputCaptionTests.fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = try await VideoEditorService.changeCaption(
            .add(
                content: "SYNTHETIC\nCAPTION", start: .frame(12), end: .frame(24), rate: .project,
                style: Self.styled), in: url)
        let model = VideoEditorModel()
        defer { model.close() }
        model.project = try VideoProject.open(url)
        let caption = try #require(model.project?.annotations.first)
        let rect = try #require(caption.captionCanvasRect)
        model.placeAnnotation(caption.id, rect: rect.offsetBy(dx: 0, dy: -0.1))
        #expect(model.project?.annotations.first?.captionStyle?.y == 2396)
        #expect(model.project?.annotations.first?.outputCaption == report.captions[0].anchor)
        model.undo()
        #expect(model.project?.annotations.first?.captionStyle == Self.styled)
        model.placeAnnotation(
            caption.id,
            rect: CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height / 2)
        )
        #expect(model.project?.annotations.first?.captionStyle?.fontSize == 52)
        #expect(model.project?.annotations.first?.captionStyle?.lineAdvance == 75)
        model.updateCaption(caption.id, text: String(repeating: "TOO MANY LINES\n", count: 500))
        #expect(model.project?.annotations.first?.text == "SYNTHETIC\nCAPTION")
        #expect(model.errorMessage != nil)
    }

    static func pixels(_ image: CIImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: Int(image.extent.width * image.extent.height) * 4)
        CIContext().render(
            image, toBitmap: &bytes, rowBytes: Int(image.extent.width) * 4,
            bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }
}
