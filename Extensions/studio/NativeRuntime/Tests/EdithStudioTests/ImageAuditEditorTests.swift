import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

@Suite struct ImageAuditEditorTests {
    enum Step: CaseIterable {
        case clockwise, counterClockwise, horizontal, vertical

        func apply(_ document: inout ImageEditDocument) {
            switch self {
            case .clockwise: document.rotateClockwise()
            case .counterClockwise: document.rotateCounterclockwise()
            case .horizontal: document.flipHorizontally()
            case .vertical: document.flipVertically()
            }
        }

        func apply(_ layout: [AuditRGB]) -> [AuditRGB] {
            switch self {
            case .clockwise: [layout[2], layout[0], layout[3], layout[1]]
            case .counterClockwise: [layout[1], layout[3], layout[0], layout[2]]
            case .horizontal: [layout[1], layout[0], layout[3], layout[2]]
            case .vertical: [layout[2], layout[3], layout[0], layout[1]]
            }
        }
    }

    func source(_ space: Workspace, width: Int = 120, height: Int = 80) throws -> (URL, CGImage) {
        let url = space.url("photo-\(width)x\(height).png")
        try AuditImages.write(
            AuditImages.quadrants(width: width, height: height), to: url, type: .png)
        return (url, try StudioImageIO.load(url))
    }

    @Test func everySequenceOfRotationsAndFlipsRendersWhatTheUserDid() throws {
        let space = try Workspace()
        let (url, image) = try source(space)
        var sequences: [[Step]] = [[]]
        for _ in 0..<3 {
            sequences = sequences.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
        }
        for sequence in sequences {
            var document = ImageEditDocument(source: url)
            var expected = AuditLayout.upright
            for step in sequence {
                step.apply(&document)
                expected = step.apply(expected)
            }
            let output = AuditBitmap(
                try ImageEditRenderer.render(document: document, source: image))
            let turned = sequence.filter { $0 == .clockwise || $0 == .counterClockwise }.count % 2
            #expect(
                output.width == (turned == 1 ? 80 : 120), "\(sequence) width \(output.width)")
            let matches = output.matches(expected)
            #expect(matches, "\(sequence) found \(output.quadrants())")
        }
    }

    @Test func straightenCommutesWithLaterFlipsAndRotations() throws {
        let space = try Workspace()
        let url = space.url("noise.png")
        try AuditImages.write(Fixtures.photo(width: 160, height: 120), to: url, type: .png)
        let image = try StudioImageIO.load(url)
        var straight = ImageEditDocument(source: url)
        straight.straighten = 9
        let base = try ImageEditRenderer.render(document: straight, source: image)
        let cases: [(Step, CGImage?)] = [
            (.horizontal, StudioImageOps.flipped(base, horizontal: true, vertical: false)),
            (.vertical, StudioImageOps.flipped(base, horizontal: false, vertical: true)),
            (.clockwise, StudioImageOps.rotated(base, quarterTurns: 1)),
            (.counterClockwise, StudioImageOps.rotated(base, quarterTurns: 3)),
        ]
        for (step, expected) in cases {
            var document = straight
            step.apply(&document)
            let output = AuditBitmap(
                try ImageEditRenderer.render(document: document, source: image))
            let reference = AuditBitmap(try #require(expected))
            let difference = output.meanDifference(reference)
            #expect(difference < 3, "\(step) differs by \(difference)")
        }
    }

    @Test func cropFollowsTheContentThroughRotationsAndFlips() throws {
        let space = try Workspace()
        let (url, image) = try source(space)
        var sequences: [[Step]] = [[]]
        for _ in 0..<3 {
            sequences = sequences.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
        }
        for sequence in sequences {
            var document = ImageEditDocument(source: url)
            document.crop = StudioRect(x: 0.5, y: 0, width: 0.5, height: 0.5)
            for step in sequence { step.apply(&document) }
            let output = AuditBitmap(
                try ImageEditRenderer.render(document: document, source: image))
            let turned = sequence.filter { $0 == .clockwise || $0 == .counterClockwise }.count % 2
            #expect(output.width == (turned == 1 ? 40 : 60), "\(sequence)")
            let corners = [
                output.rgb(1, 1), output.rgb(output.width - 2, output.height - 2),
                output.rgb(output.width / 2, output.height / 2),
            ]
            #expect(
                corners.allSatisfy { $0.isClose(to: .green, tolerance: 6) },
                "\(sequence) \(corners)")
        }
    }

    @Test func layersStayOnTheCanvasAfterCropRotateAndFlip() throws {
        let space = try Workspace()
        let (url, image) = try source(space, width: 400, height: 300)
        var document = ImageEditDocument(source: url)
        document.crop = StudioRect(x: 0, y: 0, width: 0.5, height: 1)
        document.rotateClockwise()
        document.flipHorizontally()
        let box = ImageLayer(
            content: .shape(
                ImageShapeStyle(
                    shape: .rectangle, strokeColor: "#FF00FF", strokeWidth: 0.01,
                    fillColor: "#FF00FF")),
            frame: StudioRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
        document.add(box)
        document.add(
            ImageLayer(
                content: .redaction(ImageRedaction(style: .solid, color: "#000000")),
                frame: StudioRect(x: 0.05, y: 0.75, width: 0.3, height: 0.2)))
        document.add(
            .text(
                "L", at: StudioRect(x: 0.5, y: 0.1, width: 0.4, height: 0.8),
                style: ImageTextStyle(text: "", size: 0.5, color: "#000000", shadow: false)))
        let size = document.canvasSize(for: CGSize(width: 400, height: 300))
        #expect(size == CGSize(width: 300, height: 200))
        let output = AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
        #expect(output.width == 300 && output.height == 200)
        let magenta = AuditRGB(255, 0, 255)
        #expect(output.rgb(75, 80).isClose(to: magenta, tolerance: 4))
        #expect(output.rgb(32, 43).isClose(to: magenta, tolerance: 4))
        #expect(output.rgb(117, 117).isClose(to: magenta, tolerance: 4))
        #expect(!output.rgb(25, 80).isClose(to: magenta, tolerance: 60))
        #expect(!output.rgb(75, 150).isClose(to: magenta, tolerance: 60))
        for (x, y) in [(17, 152), (103, 188), (60, 170)] {
            #expect(output.rgb(x, y) == .black, "redaction missing at \(x),\(y)")
        }
        #expect(output.rgb(12, 170) != .black)
        #expect(output.rgb(60, 146) != .black)
        let textArea = CGRect(x: 150, y: 20, width: 120, height: 160)
        let dark = { (color: AuditRGB, _: Int) in color.r < 60 && color.g < 60 && color.b < 60 }
        let left = output.count(in: CGRect(x: 150, y: 20, width: 60, height: 160), where: dark)
        let right = output.count(in: CGRect(x: 210, y: 20, width: 60, height: 160), where: dark)
        #expect(output.count(in: textArea, where: dark) > 200)
        #expect(left > right, "text was mirrored: left \(left) right \(right)")
    }

    @Test func translucentLayersCompositeOnceWithoutDarkSeams() throws {
        let space = try Workspace()
        let url = space.url("white.png")
        let white = AuditImages.context(300, 200)
        white.setFillColor(gray: 1, alpha: 1)
        white.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        try AuditImages.write(white.makeImage()!, to: url, type: .png)
        let image = try StudioImageIO.load(url)
        var document = ImageEditDocument(source: url)
        document.add(
            ImageLayer(
                content: .shape(
                    ImageShapeStyle(
                        shape: .rectangle, strokeColor: "#0000FF", strokeWidth: 0.05,
                        fillColor: "#0000FF")),
                frame: StudioRect(x: 0.1, y: 0.1, width: 0.4, height: 0.6), opacity: 0.5))
        document.add(
            ImageLayer(
                content: .shape(
                    ImageShapeStyle(
                        shape: .arrow, strokeColor: "#FF0000", strokeWidth: 0.04,
                        start: ImagePoint(x: 0, y: 0.5), end: ImagePoint(x: 1, y: 0.5))),
                frame: StudioRect(x: 0.55, y: 0.2, width: 0.4, height: 0.3), opacity: 0.5))
        document.add(
            .text(
                "W", at: StudioRect(x: 0.55, y: 0.55, width: 0.4, height: 0.4),
                style: ImageTextStyle(
                    text: "", size: 0.3, color: "#00AA00", strokeColor: "#00AA00",
                    strokeWidth: 0.08, shadow: false)))
        document.updateLayer(document.layers[2].id) { $0.opacity = 0.5 }
        let output = AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
        let interior = output.rgb(90, 80)
        let edge = output.rgb(37, 80)
        #expect(interior.isClose(to: AuditRGB(128, 128, 255), tolerance: 4), "\(interior)")
        #expect(edge.isClose(to: interior, tolerance: 3), "edge \(edge) interior \(interior)")
        let shaft = output.rgb(200, 70)
        let tip = output.rgb(280, 70)
        #expect(shaft.isClose(to: AuditRGB(255, 128, 128), tolerance: 4), "\(shaft)")
        #expect(tip.isClose(to: shaft, tolerance: 3), "arrow head \(tip) shaft \(shaft)")
        let greens = output.count(in: CGRect(x: 165, y: 110, width: 120, height: 80)) { c, _ in
            c.g > c.r + 20
        }
        let darkGreens = output.count(in: CGRect(x: 165, y: 110, width: 120, height: 80)) { c, _ in
            c.g > c.r + 20 && c.r < 110
        }
        #expect(greens > 50)
        #expect(darkGreens == 0, "stroke drawn twice: \(darkGreens) dark pixels")
    }

    @Test func grainAddsNoiseWithoutFillingTransparency() throws {
        let space = try Workspace()
        let url = space.url("cutout.png")
        try AuditImages.write(AuditImages.transparentCorner(), to: url, type: .png)
        let image = try StudioImageIO.load(url)
        var document = ImageEditDocument(source: url)
        document.adjustments.grain = 1
        let output = AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
        let filled = output.count(in: CGRect(x: 62, y: 42, width: 56, height: 36)) { _, alpha in
            alpha > 3
        }
        #expect(filled == 0, "grain filled \(filled) transparent pixels")
        let original = AuditBitmap(image)
        var changed = 0
        for x in stride(from: 2, to: 58, by: 3) {
            for y in stride(from: 2, to: 38, by: 3) {
                #expect(output.alpha(x, y) == 255)
                if output.rgb(x, y) != original.rgb(x, y) { changed += 1 }
            }
        }
        #expect(changed > 50, "grain changed only \(changed) samples")

        let gray = space.url("gray.png")
        try AuditImages.write(
            AuditImages.quadrants(
                width: 200, height: 200, colors: Array(repeating: AuditRGB(128, 128, 128), count: 4)
            ),
            to: gray, type: .png)
        var grainy = ImageEditDocument(source: gray)
        grainy.adjustments.grain = 1
        let noisy = AuditBitmap(
            try ImageEditRenderer.render(document: grainy, source: try StudioImageIO.load(gray)))
        let mean = noisy.average(around: CGPoint(x: 100, y: 100), radius: 90)
        #expect(mean.isClose(to: AuditRGB(128, 128, 128), tolerance: 6), "grain shifted to \(mean)")
        #expect(noisy.detail(in: CGRect(x: 10, y: 10, width: 180, height: 180)) > 20)
    }

    @Test func highlighterStrokesRespectTheLayerOpacity() throws {
        let space = try Workspace()
        let url = space.url("white.png")
        let white = AuditImages.context(200, 100)
        white.setFillColor(gray: 1, alpha: 1)
        white.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        try AuditImages.write(white.makeImage()!, to: url, type: .png)
        let image = try StudioImageIO.load(url)
        func render(opacity: Double) throws -> AuditRGB {
            var document = ImageEditDocument(source: url)
            var layer = try #require(
                ImageLayer.drawing(
                    canvasStrokes: [[ImagePoint(x: 0.1, y: 0.5), ImagePoint(x: 0.9, y: 0.5)]],
                    color: "#0000FF", width: 0.1, highlighter: true))
            layer.opacity = opacity
            document.add(layer)
            return AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
                .rgb(100, 50)
        }
        let full = try render(opacity: 1)
        let half = try render(opacity: 0.5)
        #expect(full.isClose(to: AuditRGB(153, 153, 255), tolerance: 4), "\(full)")
        #expect(half.isClose(to: AuditRGB(204, 204, 255), tolerance: 4), "\(half)")
    }

    @Test func layerOrderSurvivesEveryEdit() throws {
        let space = try Workspace()
        let (url, image) = try source(space, width: 200, height: 200)
        var document = ImageEditDocument(source: url)
        func square(_ color: String, x: Double) -> ImageLayer {
            ImageLayer(
                content: .shape(
                    ImageShapeStyle(shape: .rectangle, strokeColor: color, fillColor: color)),
                frame: StudioRect(x: x, y: 0.3, width: 0.4, height: 0.4))
        }
        let red = square("#FF0000", x: 0.1)
        let blue = square("#0000FF", x: 0.3)
        let sticker = ImageLayer(
            content: .sticker("🌴"), frame: StudioRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3))
        document.add(red)
        document.add(sticker)
        document.add(blue)
        func overlap() throws -> AuditRGB {
            AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
                .rgb(70, 100)
        }
        #expect(try overlap().isClose(to: AuditRGB(0, 0, 255), tolerance: 4))
        document.updateLayer(blue.id) { $0.frame.x = 0.28 }
        document.rotateClockwise()
        document.flipHorizontally()
        document.adjustments.contrast = 0.1
        document.crop = StudioRect(x: 0, y: 0, width: 1, height: 1)
        #expect(document.layers.map(\.id) == [red.id, sticker.id, blue.id])
        #expect(try overlap().isClose(to: AuditRGB(0, 0, 255), tolerance: 4))
        document.moveLayer(red.id, by: 5)
        #expect(document.layers.map(\.id) == [sticker.id, blue.id, red.id])
        #expect(try overlap().isClose(to: AuditRGB(255, 0, 0), tolerance: 4))
        let duplicated = document.duplicateLayer(sticker.id)
        let copy = try #require(duplicated)
        #expect(document.layers.map(\.id) == [sticker.id, copy, blue.id, red.id])
        document.updateLayer(red.id) { $0.isHidden = true }
        #expect(try overlap().isClose(to: AuditRGB(0, 0, 255), tolerance: 4))
        #expect(
            document.hitTest(CGPoint(x: 0.35, y: 0.5), canvas: CGSize(width: 200, height: 200))
                == blue.id)
    }

    @Test func everyLayerTypeRendersAfterATextLayerWithShadow() throws {
        let space = try Workspace()
        let (url, image) = try source(space, width: 400, height: 300)
        let logo = space.url("logo.jpg")
        try AuditImages.photo(
            at: logo, orientation: 6,
            upright: AuditImages.quadrants(
                width: 40, height: 40, colors: Array(repeating: .white, count: 4)))
        var document = ImageEditDocument(source: url)
        document.add(.text("Shadowed", at: StudioRect(x: 0.05, y: 0.02, width: 0.9, height: 0.15)))
        let layers: [(ImageLayer.Content, StudioRect, (AuditRGB) -> Bool)] = [
            (
                .shape(
                    ImageShapeStyle(shape: .ellipse, strokeColor: "#FFFFFF", fillColor: "#FFFFFF")),
                StudioRect(x: 0.05, y: 0.25, width: 0.15, height: 0.2),
                { $0.isClose(to: .white, tolerance: 6) }
            ),
            (
                .drawing(
                    ImageDrawing(
                        strokes: [[ImagePoint(x: 0, y: 0.5), ImagePoint(x: 1, y: 0.5)]],
                        color: "#FFFFFF", width: 0.05)),
                StudioRect(x: 0.55, y: 0.25, width: 0.3, height: 0.2),
                { $0.isClose(to: .white, tolerance: 6) }
            ),
            (
                .sticker("🌴"), StudioRect(x: 0.05, y: 0.6, width: 0.2, height: 0.3),
                { $0.g > $0.r + 30 && $0.g > $0.b + 30 }
            ),
            (
                .image(path: logo.path), StudioRect(x: 0.6, y: 0.6, width: 0.2, height: 0.3),
                { $0.isClose(to: .white, tolerance: 6) }
            ),
        ]
        for (content, frame, _) in layers {
            document.add(ImageLayer(content: content, frame: frame))
        }
        let output = AuditBitmap(try ImageEditRenderer.render(document: document, source: image))
        for (content, frame, check) in layers {
            let rect = frame.canvasRect(in: CGSize(width: 400, height: 300))
            let hits = output.count(in: rect, step: 2) { color, _ in check(color) }
            #expect(hits > 20, "\(content) missing: \(hits)")
        }
        #expect(output.rgb(50, 139).isClose(to: .red, tolerance: 6), "ellipse cast a shadow")
        #expect(output.rgb(280, 138).isClose(to: .green, tolerance: 6), "drawing cast a shadow")
    }

    @Test func fullResolutionExportMatchesThePreview() throws {
        let space = try Workspace()
        let url = space.url("scene.jpg")
        try AuditImages.photo(
            at: url, orientation: 6,
            upright: Fixtures.photo(width: 1200, height: 900))
        let image = try StudioImageIO.load(url)
        var document = ImageEditDocument(source: url)
        document.rotateClockwise()
        document.flipVertically()
        document.straighten = 4
        document.crop = StudioRect(x: 0.1, y: 0.05, width: 0.8, height: 0.7)
        document.adjustments.contrast = 0.3
        document.adjustments.vignette = 0.5
        document.filter = .chrome
        document.add(
            .text(
                "Summer", at: StudioRect(x: 0.1, y: 0.05, width: 0.8, height: 0.2),
                style: ImageTextStyle(
                    text: "", size: 0.1, strokeColor: "#000000", strokeWidth: 0.03)))
        document.add(
            ImageLayer(
                content: .sticker("🌴"), frame: StudioRect(x: 0.6, y: 0.5, width: 0.25, height: 0.3),
                rotation: 20, opacity: 0.8))
        document.add(
            ImageLayer(
                content: .shape(
                    ImageShapeStyle(shape: .arrow, strokeColor: "#FFFF00", strokeWidth: 0.02)),
                frame: StudioRect(x: 0.1, y: 0.4, width: 0.3, height: 0.3)))
        document.add(
            ImageLayer(
                content: .redaction(ImageRedaction(style: .pixelate, strength: 0.8)),
                frame: StudioRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)))
        document.add(
            ImageLayer(
                content: .redaction(ImageRedaction(style: .blur, strength: 0.8)),
                frame: StudioRect(x: 0.1, y: 0.75, width: 0.3, height: 0.2)))
        document.frame = ImageFrameStyle(kind: .polaroid, width: 0.05, color: "#FFFFFF")
        let full = try ImageEditRenderer.render(document: document, source: image)
        let preview = try ImageEditRenderer.render(
            document: document, source: image, maxPixelSize: 300)
        #expect(max(preview.width, preview.height) == 300)
        let fullAspect = Double(full.width) / Double(full.height)
        let previewAspect = Double(preview.width) / Double(preview.height)
        #expect(
            abs(fullAspect - previewAspect) < 0.02,
            "\(full.width)x\(full.height) vs \(preview.width)x\(preview.height)")
        let scaled = try #require(
            StudioImageOps.resized(full, width: preview.width, height: preview.height))
        let difference = AuditBitmap(scaled).meanDifference(AuditBitmap(preview))
        #expect(difference < 5, "preview differs from export by \(difference)")

        let exported = space.url("scene-edited.heic")
        try ImageEditRenderer.export(document: document, to: exported)
        let info = try #require(StudioImageIO.info(exported))
        #expect(info.width == full.width && info.height == full.height)
        #expect(AuditFiles.orientation(exported) == 1)
        let reopened = try StudioImageIO.load(exported)
        #expect(AuditBitmap(reopened).meanDifference(AuditBitmap(full)) < 4)
    }

    @Test func exportWritesEveryFormatAtTheRequestedSize() throws {
        let space = try Workspace()
        let (url, _) = try source(space, width: 400, height: 300)
        var document = ImageEditDocument(source: url)
        document.frame = ImageFrameStyle(
            kind: .rounded, width: 0.05, color: "#000000", cornerRadius: 0.2)
        for format in [StudioImageFormat.jpeg, .png, .heic, .tiff, .gif, .bmp] {
            let output = space.url("edited.\(format.fileExtension)")
            try ImageEditRenderer.export(document: document, to: output)
            let bitmap = try AuditBitmap(url: output)
            #expect(bitmap.width == 430 && bitmap.height == 330, "\(format)")
            if format.supportsAlpha {
                #expect(bitmap.alpha(0, 0) < 10, "\(format) corner")
            } else {
                #expect(bitmap.rgb(0, 0).isClose(to: .white, tolerance: 6), "\(format) corner")
            }
            #expect(
                bitmap.matches(
                    AuditLayout.upright, inset: CGRect(x: 15, y: 15, width: 400, height: 300),
                    tolerance: 45),
                "\(format)")
        }
        document.export.maxDimension = 215
        let small = space.url("small.png")
        try ImageEditRenderer.export(document: document, to: small)
        let info = try #require(StudioImageIO.info(small))
        #expect(info.width == 215 && info.height == 165)
        #expect(document.outputFormat == .png)
    }

    @Test func geometryPreviewShowsTheWholeImageWithTheSameGeometry() throws {
        let space = try Workspace()
        let (url, image) = try source(space, width: 400, height: 300)
        var document = ImageEditDocument(source: url)
        document.crop = StudioRect(x: 0.2, y: 0.2, width: 0.3, height: 0.3)
        document.flipHorizontally()
        document.rotateCounterclockwise()
        let preview = AuditBitmap(
            try ImageEditRenderer.geometryPreview(
                document: document, source: image, maxPixelSize: 200))
        #expect(preview.width == 150 && preview.height == 200)
        var expected = AuditLayout.upright
        expected = Step.horizontal.apply(expected)
        expected = Step.counterClockwise.apply(expected)
        let matches = preview.matches(expected)
        #expect(matches, "\(preview.quadrants())")
    }
}
