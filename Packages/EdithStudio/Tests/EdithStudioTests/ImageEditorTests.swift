import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import EdithStudio

@Suite struct ImageEditorTests {
    func quad(_ space: Workspace) throws -> (URL, CGImage) {
        let url = space.url("quad.png")
        try Fixtures.image(at: url, width: 400, height: 300)
        return (url, try StudioImageIO.load(url))
    }

    @Test func untouchedDocumentRendersTheSourceUnchanged() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        let document = ImageEditDocument(source: url)
        #expect(document.isUnchanged)
        let output = try ImageEditRenderer.render(document: document, source: source)
        #expect(output.width == 400 && output.height == 300)
        #expect(ImageFixtures.meanDifference(source, output) < 1)
    }

    @Test func cropAppliesAfterRotation() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        document.rotateClockwise()
        document.crop = StudioRect(x: 0, y: 0, width: 1, height: 0.5)
        let output = try ImageEditRenderer.render(document: document, source: source)
        #expect(output.width == 300 && output.height == 200)
        #expect(ImageFixtures.isRed(Fixtures.pixel(output, x: 280, y: 20)))
        #expect(!ImageFixtures.isRed(Fixtures.pixel(output, x: 20, y: 20)))
        #expect(
            document.canvasSize(for: CGSize(width: 400, height: 300))
                == CGSize(width: 300, height: 200))
    }

    @Test func rotatingCarriesTheCropWithTheImage() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        document.crop = StudioRect(x: 0, y: 0, width: 0.5, height: 0.5)
        let before = try ImageEditRenderer.render(document: document, source: source)
        #expect(ImageFixtures.isRed(Fixtures.pixel(before, x: 100, y: 75)))
        document.rotateClockwise()
        let after = try ImageEditRenderer.render(document: document, source: source)
        #expect(after.width == 150 && after.height == 200)
        #expect(ImageFixtures.isRed(Fixtures.pixel(after, x: 75, y: 100)))
        document.rotateCounterclockwise()
        #expect(document.crop == StudioRect(x: 0, y: 0, width: 0.5, height: 0.5))
        document.flipHorizontally()
        let mirrored = try ImageEditRenderer.render(document: document, source: source)
        #expect(ImageFixtures.isRed(Fixtures.pixel(mirrored, x: 100, y: 75)))
    }

    @Test func straightenCropsToFillWithoutBlankCorners() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        document.straighten = 8
        let output = try ImageEditRenderer.render(document: document, source: source)
        let expected = document.geometrySize(for: CGSize(width: 400, height: 300))
        #expect(abs(Double(output.width) - Double(expected.width)) <= 1)
        #expect(abs(Double(output.height) - Double(expected.height)) <= 1)
        for (x, y) in [
            (0, 0), (output.width - 1, 0), (0, output.height - 1),
            (output.width - 1, output.height - 1),
        ] {
            #expect(Fixtures.pixel(output, x: x, y: y).a > 250)
        }
        #expect(
            ImageEditGeometry.straightenScale(size: CGSize(width: 400, height: 300), degrees: 0)
                == 1)
    }

    @Test func layersLandWhereTheirFramesSay() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        let box = ImageLayer(
            content: .shape(
                ImageShapeStyle(shape: .rectangle, strokeColor: "#0000FF", fillColor: "#0000FF")),
            frame: StudioRect(x: 0.5, y: 0.5, width: 0.25, height: 0.25))
        document.add(box)
        let output = try ImageEditRenderer.render(document: document, source: source)
        let inside = Fixtures.pixel(output, x: 250, y: 187)
        #expect(inside.b > 200 && inside.r < 40)
        #expect(ImageFixtures.isGreen(Fixtures.pixel(output, x: 390, y: 290)))
        #expect(
            document.hitTest(CGPoint(x: 0.6, y: 0.6), canvas: CGSize(width: 400, height: 300))
                == box.id)
        #expect(
            document.hitTest(CGPoint(x: 0.1, y: 0.1), canvas: CGSize(width: 400, height: 300))
                == nil)
    }

    @Test func stickerLandsInItsFrameAfterATextLayer() throws {
        let space = try Workspace()
        let url = space.url("plain.png")
        let canvas = try #require(StudioImageOps.context(width: 1200, height: 800, opaque: true))
        canvas.setFillColor(CGColor(srgbRed: 0.95, green: 0.9, blue: 0.8, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: 1200, height: 800))
        try StudioImageIO.write(try #require(canvas.makeImage()), to: url, format: .png)
        let source = try StudioImageIO.load(url)
        var document = ImageEditDocument(source: url)
        document.add(
            .text("Beach day", at: StudioRect(x: 0.2, y: 0.12, width: 0.6, height: 0.12)))
        document.add(
            ImageLayer(
                content: .sticker("🌴"),
                frame: StudioRect(x: 0.44, y: 0.41, width: 0.12, height: 0.18)))
        let output = try ImageEditRenderer.render(document: document, source: source)
        var green = 0
        for x in stride(from: 530, to: 670, by: 3) {
            for y in stride(from: 330, to: 470, by: 3) {
                let pixel = Fixtures.pixel(output, x: x, y: y)
                if pixel.g > pixel.r + 40 && pixel.g > pixel.b + 40 && pixel.r < 200 { green += 1 }
            }
        }
        #expect(green > 40)
    }

    @Test func textStickerDrawingAndArrowLayersRender() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        document.add(
            .text(
                "Hello", at: StudioRect(x: 0.1, y: 0.6, width: 0.8, height: 0.3),
                style: ImageTextStyle(text: "", size: 0.15, color: "#000000", shadow: false)))
        document.add(
            ImageLayer(
                content: .sticker("🎉"), frame: StudioRect(x: 0.7, y: 0.05, width: 0.2, height: 0.25)
            ))
        document.add(
            ImageLayer(
                content: .shape(
                    ImageShapeStyle(shape: .arrow, strokeColor: "#FFFF00", strokeWidth: 0.02)),
                frame: StudioRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)))
        let drawing = try #require(
            ImageLayer.drawing(
                canvasStrokes: [[ImagePoint(x: 0.2, y: 0.2), ImagePoint(x: 0.4, y: 0.3)]],
                color: "#FF00FF", width: 0.02))
        #expect(abs(drawing.frame.x - 0.2) < 0.0001 && abs(drawing.frame.width - 0.2) < 0.0001)
        document.add(drawing)
        let output = try ImageEditRenderer.render(document: document, source: source)
        #expect(ImageFixtures.meanDifference(source, output) > 2)
        var dark = 0
        for x in stride(from: 60, to: 340, by: 4) {
            for y in stride(from: 190, to: 270, by: 4) {
                let pixel = Fixtures.pixel(output, x: x, y: y)
                if pixel.r < 60 && pixel.g < 60 && pixel.b < 60 { dark += 1 }
            }
        }
        #expect(dark > 10)
    }

    @Test func redactionPixelatesOnlyItsRegion() throws {
        let space = try Workspace()
        let url = space.url("noise.png")
        try ImageFixtures.photo(at: url, width: 200, height: 200)
        let source = try StudioImageIO.load(url)
        var document = ImageEditDocument(source: url)
        document.add(
            ImageLayer(
                content: .redaction(ImageRedaction(style: .pixelate, strength: 1)),
                frame: StudioRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        let output = try ImageEditRenderer.render(document: document, source: source)
        var outside = 0
        var inside = 0
        for x in stride(from: 110, to: 200, by: 7) {
            for y in stride(from: 110, to: 200, by: 7) {
                let a = Fixtures.pixel(source, x: x, y: y)
                let b = Fixtures.pixel(output, x: x, y: y)
                outside += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
            }
        }
        for x in stride(from: 5, to: 95, by: 7) {
            for y in stride(from: 5, to: 95, by: 7) {
                let a = Fixtures.pixel(source, x: x, y: y)
                let b = Fixtures.pixel(output, x: x, y: y)
                inside += abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
            }
        }
        #expect(outside < 350)
        #expect(inside > 2000)
        let solid = try ImageEditRenderer.redact(
            source, rects: [StudioRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)],
            style: ImageRedaction(style: .solid))
        let black = Fixtures.pixel(solid, x: 150, y: 150)
        #expect(black.r < 5 && black.g < 5 && black.b < 5)
    }

    @Test func adjustmentsAndFiltersChangeColorsPredictably() throws {
        let space = try Workspace()
        let (_, source) = try quad(space)
        var warm = ImageAdjustments()
        warm.warmth = 1
        let warmed = try ImageEditRenderer.adjust(source, adjustments: warm, filter: .none)
        let beigeBefore = Fixtures.pixel(source, x: 300, y: 50)
        let beigeAfter = Fixtures.pixel(warmed, x: 300, y: 50)
        #expect(beigeAfter.r - beigeAfter.b > beigeBefore.r - beigeBefore.b)
        let none = try ImageEditRenderer.adjust(
            source, adjustments: ImageAdjustments(), filter: .mono, intensity: 0)
        #expect(ImageFixtures.meanDifference(source, none) < 1.5)
        for preset in ImageFilterPreset.allCases {
            let output = try ImageEditRenderer.adjust(
                source, adjustments: ImageAdjustments(), filter: preset)
            #expect(output.width == 400)
        }
        var all = ImageAdjustments()
        for key in ImageAdjustments.Key.allCases { all[key] = key.range.upperBound * 0.5 }
        #expect(!all.isNeutral)
        all[.exposure] = 5
        #expect(all.exposure == 1)
        _ = try ImageEditRenderer.adjust(source, adjustments: all, filter: .vintage)
    }

    @Test func framesExportAndPreviewSizes() throws {
        let space = try Workspace()
        let (url, source) = try quad(space)
        var document = ImageEditDocument(source: url)
        document.frame = ImageFrameStyle(kind: .solid, width: 0.1, color: "#000000")
        let framed = try ImageEditRenderer.render(document: document, source: source)
        #expect(framed.width == 460 && framed.height == 360)
        let preview = try ImageEditRenderer.render(
            document: document, source: source, maxPixelSize: 100)
        #expect(max(preview.width, preview.height) <= 100)
        document.export.maxDimension = 200
        let limited = try ImageEditRenderer.render(document: document, source: source)
        #expect(max(limited.width, limited.height) == 200)
        document.frame = ImageFrameStyle(kind: .rounded, width: 0)
        #expect(document.outputFormat == .png)
        let exported = space.url("export.jpg")
        document.frame = nil
        try ImageEditRenderer.export(document: document, to: exported)
        #expect(StudioImageFormat.of(exported) == .jpeg)
        #expect(StudioImageIO.info(exported)?.width == 200)
        let geometry = try ImageEditRenderer.geometryPreview(
            document: document, source: source, maxPixelSize: 80)
        #expect(max(geometry.width, geometry.height) <= 80)
    }

    @Test func documentsRoundTripThroughJSONAndSupportLayerEditing() throws {
        var document = ImageEditDocument(source: URL(fileURLWithPath: "/tmp/photo.heic"))
        document.adjustments.contrast = 0.3
        document.filter = .noir
        document.straighten = -3
        document.crop = StudioRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)
        let text = ImageLayer.text(
            "Caption", at: StudioRect(x: 0.1, y: 0.8, width: 0.8, height: 0.1))
        document.add(text)
        document.add(
            ImageLayer(
                content: .image(path: "/tmp/logo.png"),
                frame: StudioRect(x: 0, y: 0, width: 0.2, height: 0.2), rotation: 15, opacity: 0.5))
        document.add(
            ImageLayer(
                content: .redaction(ImageRedaction()),
                frame: StudioRect(x: 0.4, y: 0.4, width: 0.1, height: 0.1)))
        document.frame = ImageFrameStyle(kind: .polaroid)
        document.export = ImageExportSettings(format: .jpeg, quality: 0.8, maxDimension: 2048)
        let data = try JSONEncoder().encode(document)
        let decoded = try JSONDecoder().decode(ImageEditDocument.self, from: data)
        #expect(decoded == document)
        #expect(!decoded.isUnchanged)
        #expect(decoded.outputFormat == .jpeg)

        var edited = decoded
        edited.updateLayer(text.id) { $0.opacity = 0.4 }
        #expect(edited.layer(text.id)?.opacity == 0.4)
        let duplicated = edited.duplicateLayer(text.id)
        let copy = try #require(duplicated)
        #expect(edited.layers.count == 4)
        edited.moveLayer(copy, by: 10)
        #expect(edited.layers.last?.id == copy)
        edited.removeLayer(copy)
        #expect(edited.layers.count == 3)
        #expect(edited.layers.first { $0.isRedaction } != nil)
    }

    @Test func rotatedLayerHitTestingAndViewConversions() {
        let layer = ImageLayer(
            content: .sticker("⭐️"), frame: StudioRect(x: 0.4, y: 0.45, width: 0.2, height: 0.1),
            rotation: 90)
        let canvas = CGSize(width: 100, height: 100)
        #expect(layer.contains(CGPoint(x: 0.5, y: 0.41), canvas: canvas))
        #expect(!layer.contains(CGPoint(x: 0.41, y: 0.5), canvas: canvas))
        let view = CGRect(x: 10, y: 20, width: 200, height: 100)
        let point = ImageEditGeometry.normalized(CGPoint(x: 110, y: 70), in: view)
        #expect(point == CGPoint(x: 0.5, y: 0.5))
        #expect(ImageEditGeometry.viewPoint(point, in: view) == CGPoint(x: 110, y: 70))
        let frame = ImageEditGeometry.viewRect(
            for: StudioRect(x: 0.5, y: 0, width: 0.5, height: 1), in: view)
        #expect(frame == CGRect(x: 110, y: 20, width: 100, height: 100))
        #expect(
            StudioRect.from(canvasRect: CGRect(x: 50, y: 25, width: 25, height: 50), in: canvas)
                == StudioRect(x: 0.5, y: 0.25, width: 0.25, height: 0.5))
        let fitted = ImageEditGeometry.fittedRect(
            content: CGSize(width: 400, height: 300),
            in: CGRect(x: 0, y: 0, width: 200, height: 200))
        #expect(fitted == CGRect(x: 0, y: 25, width: 200, height: 150))
        let crop = ImageEditGeometry.aspectCrop(1, in: CGSize(width: 400, height: 300))
        #expect(abs(crop.width - 0.75) < 0.0001 && crop.height == 1)
    }

    @Test func quantizerKeepsTransparencyAndExactPalettes() throws {
        let space = try Workspace()
        let url = space.url("dot.png")
        try Fixtures.image(at: url, width: 120, height: 120, alpha: true)
        let image = try StudioImageIO.load(url)
        let quantized = try ImageQuantizer.quantize(image, colors: 16)
        #expect(quantized.palette.count <= 16)
        #expect(quantized.hasTransparency)
        let png = space.url("dot-indexed.png")
        try quantized.pngData().write(to: png)
        let decoded = try StudioImageIO.load(png)
        #expect(decoded.width == 120)
        #expect(Fixtures.pixel(decoded, x: 2, y: 2).a == 0)
        let center = Fixtures.pixel(decoded, x: 60, y: 60)
        #expect(center.a == 255 && center.b > 200)

        let flat = space.url("flat.png")
        try Fixtures.image(at: flat, width: 40, height: 30)
        let exact = try ImageQuantizer.quantize(try StudioImageIO.load(flat))
        #expect(exact.palette.count == 3)
        let exactURL = space.url("flat-indexed.png")
        try exact.pngData().write(to: exactURL)
        #expect(
            ImageFixtures.meanDifference(
                try StudioImageIO.load(flat), try StudioImageIO.load(exactURL)) == 0)

        let photo = Fixtures.photo(width: 160, height: 120)
        let dithered = try ImageQuantizer.quantize(photo, colors: 64, dither: true)
        #expect(dithered.palette.count == 64)
        let plain = try ImageQuantizer.quantize(photo, colors: 64, dither: false)
        #expect(plain.indices.count == 160 * 120)
    }

    @Test func pngEncoderChecksumsMatchKnownValues() {
        #expect(CRC32.checksum(Data("IEND".utf8)) == 0xAE42_6082)
        #expect(IndexedPNGEncoder.adler32(Data("Wikipedia".utf8)) == 0x11E6_0398)
    }

    @Test func jpegStripperRemovesExifButKeepsOrientation() throws {
        let segment = JPEGMetadata.orientationSegment(6)
        #expect(segment[0] == 0xFF && segment[1] == 0xE1)
        #expect(throws: StudioError.self) {
            try JPEGMetadata.strip(Data([0, 1, 2, 3, 4]), orientation: 1)
        }
    }
}
