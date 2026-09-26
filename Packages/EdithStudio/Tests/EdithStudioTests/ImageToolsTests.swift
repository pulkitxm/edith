import AppKit
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

enum ImageFixtures {
    static func load(_ url: URL) throws -> CGImage {
        try StudioImageIO.load(url)
    }

    static func size(_ url: URL) -> (Int, Int)? {
        StudioImageIO.info(url).map { ($0.width, $0.height) }
    }

    static func write(
        _ image: CGImage, to url: URL, format: StudioImageFormat, quality: Double = 0.98
    )
        throws
    {
        try StudioImageIO.write(image, to: url, format: format, options: .init(quality: quality))
    }

    static func photo(
        at url: URL, width: Int = 480, height: Int = 360, format: StudioImageFormat = .png
    )
        throws
    {
        try write(Fixtures.photo(width: width, height: height), to: url, format: format)
    }

    static func text(
        _ text: String, at url: URL, width: Int = 900, height: Int = 300, size: CGFloat = 90,
        border: Int = 0
    ) throws {
        let context = StudioImageOps.context(width: width, height: height, opaque: true)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        Fixtures.line(
            text, x: 40, y: CGFloat(height) / 2 - size / 3, size: size, bold: true, context: context
        )
        try write(context.makeImage()!, to: url, format: .png)
    }

    static func bordered(at url: URL, width: Int = 400, height: Int = 300, inset: Int = 50) throws {
        let context = StudioImageOps.context(width: width, height: height, opaque: true)!
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.8, alpha: 1))
        context.fill(
            CGRect(x: inset, y: inset, width: width - inset * 2, height: height - inset * 2))
        try write(context.makeImage()!, to: url, format: .png)
    }

    static func animatedGIF(at url: URL, frames: Int = 3) throws {
        let images = (0..<frames).map { index -> (image: CGImage, delay: Double) in
            let context = StudioImageOps.context(width: 60, height: 40, opaque: true)!
            context.setFillColor(
                CGColor(srgbRed: Double(index) / Double(frames), green: 0.4, blue: 0.2, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 60, height: 40))
            return (context.makeImage()!, 0.2)
        }
        try StudioImageIO.writeAnimatedGIF(images, to: url)
    }

    static func frameCount(_ url: URL) -> Int {
        CGImageSourceCreateWithURL(url as CFURL, nil).map(CGImageSourceGetCount) ?? 0
    }

    static func meanDifference(_ a: CGImage, _ b: CGImage) -> Double {
        let width = min(a.width, b.width, 64)
        let height = min(a.height, b.height, 64)
        let left = StudioImageOps.resized(a, width: width, height: height)!
        let right = StudioImageOps.resized(b, width: width, height: height)!
        var total = 0
        for x in stride(from: 0, to: width, by: 4) {
            for y in stride(from: 0, to: height, by: 4) {
                let p = Fixtures.pixel(left, x: x, y: y)
                let q = Fixtures.pixel(right, x: x, y: y)
                total += abs(p.r - q.r) + abs(p.g - q.g) + abs(p.b - q.b)
            }
        }
        let samples = ((width + 3) / 4) * ((height + 3) / 4) * 3
        return Double(total) / Double(samples)
    }

    static func isRed(_ pixel: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        pixel.r > 170 && pixel.g < 80 && pixel.b < 80
    }

    static func isGreen(_ pixel: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        pixel.g > 120 && pixel.r < 80 && pixel.b < 90
    }
}

@Suite struct ImageToolsTests {
    @Test func catalogRegistersTheImageFamily() throws {
        let ids = ImageTools.all.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count >= 18)
        for id in ids { #expect(StudioCatalog.tool(id) != nil) }
        #expect(StudioCatalog.quickTool(.edit, for: .image)?.id == "image.edit")
        #expect(StudioCatalog.quickTool(.compress, for: .image)?.id == "image.compress")
        #expect(StudioCatalog.quickTool(.convert, for: .image)?.id == "image.convert")
        #expect(ImageTools.edit.style == .editor(.image, pdfMode: nil))
        #expect(ImageTools.all.allSatisfy { $0.family == .image })
    }

    @Test func compressShrinksJPEGsAndKeepsDimensions() async throws {
        let space = try Workspace()
        let source = space.url("photo.jpg")
        try ImageFixtures.photo(at: source, width: 1200, height: 900, format: .jpeg)
        let before = StudioRunner.fileSize(source)
        let result = try await space.run("image.compress", [source])
        let output = try #require(result.outputs.first)
        #expect(output.url.lastPathComponent == "photo-compressed.jpg")
        #expect(output.bytes < before)
        #expect(ImageFixtures.size(output.url)! == (1200, 900))
        let extreme = try await space.run("image.compress", [source], ["level": .text("extreme")])
        #expect(try #require(extreme.outputs.first).bytes < output.bytes)
    }

    @Test func compressQuantizesPNGsIntoIndexedFiles() async throws {
        let space = try Workspace()
        let source = space.url("gradient.png")
        try ImageFixtures.photo(at: source, width: 320, height: 240)
        let result = try await space.run("image.compress", [source])
        let output = try result.url()
        #expect(StudioRunner.fileSize(output) < StudioRunner.fileSize(source))
        let properties = StudioImageIO.properties(output)
        #expect(properties[kCGImagePropertyIsIndexed] as? Bool == true)
        let difference = ImageFixtures.meanDifference(
            try ImageFixtures.load(source), try ImageFixtures.load(output))
        #expect(difference < 14)
    }

    @Test func compressNeverGrowsAnAlreadyTinyFile() async throws {
        let space = try Workspace()
        let source = space.url("flat.png")
        try Fixtures.image(at: source, width: 64, height: 64)
        let result = try await space.run("image.compress", [source], ["level": .text("less")])
        #expect(try #require(result.outputs.first).bytes <= StudioRunner.fileSize(source))
    }

    @Test func compressMinifiesSVGAndConvertsUnwritableFormats() async throws {
        let space = try Workspace()
        let svg = space.url("logo.svg")
        let markup = """
            <?xml version="1.0"?>
            <!-- exported by a design tool -->
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="100">
                <metadata>lots of tool data here</metadata>
                <circle cx="50.123456" cy="50.654321" r="40" fill="red" />
            </svg>
            """
        try markup.write(to: svg, atomically: true, encoding: .utf8)
        let minified = try await space.run("image.compress", [svg])
        let text = try String(contentsOf: try minified.url(), encoding: .utf8)
        #expect(!text.contains("exported by"))
        #expect(!text.contains("metadata"))
        #expect(text.contains("cx=\"50.123\""))
        #expect(text.count < markup.count)

        let bmp = space.url("scan.bmp")
        try ImageFixtures.photo(at: bmp, width: 200, height: 150, format: .bmp)
        let converted = try await space.run("image.compress", [bmp])
        #expect(try converted.url().pathExtension == "jpg")
        #expect(converted.notes.contains { $0.contains("scan.bmp") })
    }

    @Test func resizeByPixelsPercentLongestSideAndNoEnlarge() async throws {
        let space = try Workspace()
        let source = space.url("wide.png")
        try Fixtures.image(at: source, width: 400, height: 300)
        func size(_ values: [String: StudioValue]) async throws -> (Int, Int) {
            let result = try await space.run("image.resize", [source], values)
            return try #require(ImageFixtures.size(try result.url()))
        }
        #expect(try await size(["width": .number(200)]) == (200, 150))
        #expect(try await size(["width": .number(0), "height": .number(60)]) == (80, 60))
        #expect(
            try await size([
                "width": .number(100), "height": .number(100), "keepAspect": .bool(false),
            ]) == (100, 100))
        #expect(try await size(["width": .number(100), "height": .number(100)]) == (100, 75))
        #expect(try await size(["mode": .text("percent"), "percent": .number(25)]) == (100, 75))
        #expect(try await size(["mode": .text("longest"), "longest": .number(120)]) == (120, 90))
        #expect(try await size(["width": .number(800)]) == (400, 300))
        #expect(
            try await size(["width": .number(800), "noEnlarge": .bool(false)]) == (800, 600))
    }

    @Test func resizeKeepsAnimatedGIFsAnimated() async throws {
        let space = try Workspace()
        let source = space.url("spinner.gif")
        try ImageFixtures.animatedGIF(at: source, frames: 4)
        let result = try await space.run("image.resize", [source], ["width": .number(30)])
        let output = try result.url()
        #expect(output.pathExtension == "gif")
        #expect(ImageFixtures.frameCount(output) == 4)
        #expect(ImageFixtures.size(output)! == (30, 20))
    }

    @Test func cropToAspectAreaAndTrim() async throws {
        let space = try Workspace()
        let source = space.url("quad.png")
        try Fixtures.image(at: source, width: 400, height: 300)
        let square = try await space.run("image.crop", [source])
        #expect(ImageFixtures.size(try square.url())! == (300, 300))
        let area = try await space.run(
            "image.crop", [source],
            ["mode": .text("area"), "area": .rect(StudioRect(x: 0, y: 0, width: 0.5, height: 0.5))])
        let quarter = try ImageFixtures.load(try area.url())
        #expect(quarter.width == 200 && quarter.height == 150)
        #expect(ImageFixtures.isRed(Fixtures.pixel(quarter, x: 100, y: 75)))
        let left = try await space.run(
            "image.crop", [source],
            ["aspect": .text("1:1"), "position": .text("left")])
        #expect(
            ImageFixtures.isRed(
                Fixtures.pixel(try ImageFixtures.load(try left.url()), x: 20, y: 20)))

        let framed = space.url("framed.png")
        try ImageFixtures.bordered(at: framed, inset: 50)
        let trimmed = try await space.run("image.crop", [framed], ["mode": .text("trim")])
        #expect(ImageFixtures.size(try trimmed.url())! == (300, 200))
        let untouched = try await space.run(
            "image.crop", [try trimmed.url()], ["mode": .text("trim")])
        #expect(untouched.notes.contains { $0.contains("no plain border") })
    }

    @Test func convertToEveryWritableFormat() async throws {
        let space = try Workspace()
        let source = space.url("art.png")
        try Fixtures.image(at: source, width: 256, height: 256, alpha: true)
        for format in StudioImageFormat.writable {
            let result = try await space.run(
                "image.convert", [source], ["format": .text(format.fileExtension)])
            let output = try result.url()
            #expect(output.pathExtension == format.fileExtension)
            #expect(StudioRunner.fileSize(output) > 0)
            if format != .pdf {
                #expect(
                    CGImageSourceCreateWithURL(output as CFURL, nil).map(CGImageSourceGetCount) ?? 0
                        >= 1)
            }
        }
        let jpeg = try await space.run(
            "image.convert", [source], ["format": .text("jpg"), "background": .text("#00FF00")])
        let corner = Fixtures.pixel(try ImageFixtures.load(try jpeg.url()), x: 2, y: 2)
        #expect(corner.g > 200 && corner.r < 60)

        let gif = space.url("loop.gif")
        try ImageFixtures.animatedGIF(at: gif)
        let animated = try await space.run("image.convert", [gif], ["format": .text("gif")])
        #expect(ImageFixtures.frameCount(try animated.url()) == 3)
        #expect(try animated.url().lastPathComponent == "loop-converted.gif")
        let still = try await space.run("image.convert", [gif], ["format": .text("png")])
        #expect(ImageFixtures.frameCount(try still.url()) == 1)
    }

    @Test func rotateFlipFilterAndStraighten() async throws {
        let space = try Workspace()
        let source = space.url("quad.png")
        try Fixtures.image(at: source, width: 400, height: 300)
        let turned = try ImageFixtures.load(try await space.run("image.rotate", [source]).url())
        #expect(turned.width == 300 && turned.height == 400)
        #expect(ImageFixtures.isRed(Fixtures.pixel(turned, x: 280, y: 20)))
        let flipped = try ImageFixtures.load(
            try await space.run(
                "image.rotate", [source], ["angle": .text("0"), "flip": .text("horizontal")]
            ).url())
        #expect(ImageFixtures.isRed(Fixtures.pixel(flipped, x: 380, y: 20)))
        let skipped = try await space.run("image.rotate", [source], ["only": .text("portrait")])
        #expect(skipped.notes.first?.contains("landscape") == true)
        #expect(ImageFixtures.size(try skipped.url())! == (400, 300))
        let level = try ImageFixtures.load(
            try await space.run(
                "image.rotate", [source], ["angle": .text("0"), "straighten": .number(10)]
            ).url())
        #expect(level.width < 400 && level.height < 300)
        #expect(abs(Double(level.width) / Double(level.height) - 4.0 / 3.0) < 0.02)
        await #expect(throws: StudioError.self) {
            try await space.run("image.rotate", [source], ["angle": .text("0")])
        }
    }

    @Test func watermarkStampsVisibleText() async throws {
        let space = try Workspace()
        let source = space.url("photo.png")
        try Fixtures.image(at: source, width: 600, height: 400)
        let result = try await space.run(
            "image.watermark", [source],
            [
                "text": .text("SAMPLE"), "opacity": .number(1), "color": .text("#0000FF"),
                "rotation": .number(0),
            ])
        let original = try ImageFixtures.load(source)
        let marked = try ImageFixtures.load(try result.url())
        #expect(marked.width == 600 && marked.height == 400)
        var blue = 0
        for x in stride(from: 150, to: 450, by: 3) {
            let pixel = Fixtures.pixel(marked, x: x, y: 200)
            if pixel.b > 180 && pixel.r < 80 { blue += 1 }
        }
        #expect(blue > 5)
        #expect(ImageFixtures.meanDifference(original, marked) > 0.5)
    }

    @Test func removeBackgroundCutsOutASubjectOrExplainsWhy() async throws {
        let space = try Workspace()
        let source = space.url("subject.png")
        let context = StudioImageOps.context(width: 400, height: 400, opaque: true)!
        context.setFillColor(CGColor(srgbRed: 0.85, green: 0.9, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fillEllipse(in: CGRect(x: 120, y: 80, width: 160, height: 240))
        context.setFillColor(CGColor(srgbRed: 0.2, green: 0.2, blue: 0.2, alpha: 1))
        context.fillEllipse(in: CGRect(x: 160, y: 250, width: 80, height: 80))
        try ImageFixtures.write(context.makeImage()!, to: source, format: .png)
        do {
            let result = try await space.run(
                "image.remove-background", [source], ["crop": .bool(true)])
            let output = try ImageFixtures.load(try result.url())
            #expect(try result.url().pathExtension == "png")
            #expect(output.width <= 400)
            let full = try await space.run("image.remove-background", [source])
            let cut = try ImageFixtures.load(try full.url())
            #expect(Fixtures.pixel(cut, x: 3, y: 3).a < 30)
        } catch let error as StudioError {
            #expect(error.errorDescription?.contains("subject") == true)
        }
    }

    @Test func blurFacesSavesUnchangedWithoutFacesAndBlursText() async throws {
        let space = try Workspace()
        let empty = space.url("landscape.png")
        try Fixtures.image(at: empty, width: 300, height: 200)
        let result = try await space.run("image.blur-faces", [empty])
        #expect(result.notes.first?.contains("No faces") == true)
        #expect(StudioRunner.fileSize(try result.url()) == StudioRunner.fileSize(empty))

        let plate = space.url("plate.png")
        try ImageFixtures.text("AB 1234", at: plate)
        let blurred = try await space.run(
            "image.blur-faces", [plate], ["text": .bool(true), "style": .text("solid")])
        #expect(blurred.notes.first?.contains("text area") == true)
        let before = try ImageFixtures.load(plate)
        let after = try ImageFixtures.load(try blurred.url())
        #expect(ImageFixtures.meanDifference(before, after) > 5)
    }

    @Test func faceRectsConvertFromVisionCoordinates() {
        let rect = FaceBlur.rect(CGRect(x: 0.2, y: 0.6, width: 0.2, height: 0.2), margin: 0)
        #expect(abs(rect.x - 0.2) < 0.0001)
        #expect(abs(rect.y - 0.2) < 0.0001)
        #expect(FaceBlur.summary(faces: 2, text: 1) == "Blurred 2 faces and 1 text area.")
    }

    @Test func upscaleDoublesTheSize() async throws {
        let space = try Workspace()
        let source = space.url("small.jpg")
        try ImageFixtures.photo(at: source, width: 100, height: 80, format: .jpeg)
        let result = try await space.run("image.upscale", [source])
        #expect(try result.url().lastPathComponent == "small-2x.jpg")
        #expect(ImageFixtures.size(try result.url())! == (200, 160))
        let four = try await space.run("image.upscale", [source], ["scale": .text("4")])
        #expect(ImageFixtures.size(try four.url())! == (400, 320))
    }

    @Test func adjustAppliesFiltersAndRejectsNoOps() async throws {
        let space = try Workspace()
        let source = space.url("color.png")
        try Fixtures.image(at: source, width: 200, height: 150)
        let mono = try ImageFixtures.load(
            try await space.run("image.adjust", [source], ["filter": .text("mono")]).url())
        let pixel = Fixtures.pixel(mono, x: 20, y: 20)
        #expect(abs(pixel.r - pixel.g) < 6 && abs(pixel.g - pixel.b) < 6)
        let brighter = try ImageFixtures.load(
            try await space.run("image.adjust", [source], ["exposure": .number(0.5)]).url())
        #expect(
            Fixtures.pixel(brighter, x: 150, y: 20).r
                >= Fixtures.pixel(try ImageFixtures.load(source), x: 150, y: 20).r)
        await #expect(throws: StudioError.self) { try await space.run("image.adjust", [source]) }
    }

    @Test func memeAddsCaptions() async throws {
        let space = try Workspace()
        let source = space.url("cat.jpg")
        try ImageFixtures.photo(at: source, width: 500, height: 400, format: .jpeg)
        let result = try await space.run(
            "image.meme", [source],
            ["top": .text("one does not simply"), "bottom": .text("ship on friday")])
        let meme = try ImageFixtures.load(try result.url())
        #expect(meme.width == 500 && meme.height == 400)
        var white = 0
        for x in stride(from: 20, to: 480, by: 4) {
            for y in stride(from: 4, to: 70, by: 4) {
                let pixel = Fixtures.pixel(meme, x: x, y: y)
                if pixel.r > 235 && pixel.g > 235 && pixel.b > 235 { white += 1 }
            }
        }
        #expect(white > 20)
        await #expect(throws: StudioError.self) { try await space.run("image.meme", [source]) }
    }

    @Test func bordersGrowTheCanvas() async throws {
        let space = try Workspace()
        let source = space.url("pic.png")
        try Fixtures.image(at: source, width: 200, height: 100)
        let solid = try ImageFixtures.load(
            try await space.run(
                "image.border", [source], ["width": .number(0.1), "color": .text("#000000")]
            ).url())
        #expect(solid.width == 220 && solid.height == 120)
        #expect(Fixtures.pixel(solid, x: 2, y: 2).r < 20)
        let polaroid = try ImageFixtures.load(
            try await space.run("image.border", [source], ["style": .text("polaroid")]).url())
        #expect(polaroid.height > polaroid.width - 100)
        let rounded = try await space.run(
            "image.border", [source], ["style": .text("rounded"), "width": .number(0)])
        let corner = Fixtures.pixel(try ImageFixtures.load(try rounded.url()), x: 0, y: 0)
        #expect(corner.a < 20)
        let jpeg = space.url("pic.jpg")
        try ImageFixtures.photo(at: jpeg, width: 200, height: 100, format: .jpeg)
        let shadow = try await space.run("image.border", [jpeg], ["style": .text("shadow")])
        #expect(try shadow.url().pathExtension == "png")
        #expect(shadow.notes.contains { $0.contains("transparency") })
    }

    @Test func collageLaysOutGridsRowsAndColumns() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for index in 0..<3 {
            let url = space.url("tile\(index).png")
            try Fixtures.image(at: url, width: 200, height: 100)
            inputs.append(url)
        }
        let grid = try await space.run(
            "image.collage", inputs, ["width": .number(1000), "spacing": .number(10)])
        let gridImage = try ImageFixtures.load(try grid.url())
        #expect(gridImage.width == 1000)
        #expect(try grid.url().lastPathComponent == "tile0-collage.jpg")
        let row = try ImageFixtures.load(
            try await space.run(
                "image.collage", inputs,
                ["layout": .text("horizontal"), "width": .number(1240), "spacing": .number(10)]
            ).url())
        #expect(row.width == 1240)
        #expect(abs(row.height - 220) <= 2)
        let column = try ImageFixtures.load(
            try await space.run(
                "image.collage", inputs,
                ["layout": .text("vertical"), "width": .number(420), "spacing": .number(10)]
            ).url())
        #expect(abs(column.height - 640) <= 2)
    }

    @Test func makeGIFAnimatesImages() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for index in 0..<3 {
            let url = space.url("frame\(index).png")
            try Fixtures.image(at: url, width: 120, height: 80)
            inputs.append(url)
        }
        let result = try await space.run(
            "image.make-gif", inputs, ["width": .number(60), "delay": .number(0.25)])
        let output = try result.url()
        #expect(ImageFixtures.frameCount(output) == 3)
        #expect(ImageFixtures.size(output)! == (60, 40))
        let frames = try StudioImageIO.frames(output)
        #expect(abs(frames[0].delay - 0.25) < 0.02)
    }

    @Test func metadataRemovalIsLosslessAndKeepsOrientation() async throws {
        let space = try Workspace()
        let source = space.url("trip.jpg")
        let photo = Fixtures.photo(width: 200, height: 100)
        let destination = CGImageDestinationCreateWithURL(
            source as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            destination, photo,
            [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyGPSDictionary: [
                    kCGImagePropertyGPSLatitude: 48.85, kCGImagePropertyGPSLatitudeRef: "N",
                    kCGImagePropertyGPSLongitude: 2.35, kCGImagePropertyGPSLongitudeRef: "E",
                ],
                kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "secret"],
            ] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        #expect(StudioImageIO.properties(source)[kCGImagePropertyGPSDictionary] != nil)

        let all = try await space.run("image.metadata", [source])
        let clean = try all.url()
        let properties = StudioImageIO.properties(clean)
        #expect(properties[kCGImagePropertyGPSDictionary] == nil)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
        #expect(ImageFixtures.size(clean)! == (100, 200))
        #expect(StudioRunner.fileSize(clean) < StudioRunner.fileSize(source))

        let location = try await space.run("image.metadata", [source], ["mode": .text("location")])
        let kept = StudioImageIO.properties(try location.url())
        #expect(kept[kCGImagePropertyGPSDictionary] == nil)
        #expect(kept[kCGImagePropertyOrientation] as? Int == 6)
        let keptExif = kept[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(keptExif?[kCGImagePropertyExifUserComment] as? String == "secret")

        let heic = space.url("trip.heic")
        let heicDestination = CGImageDestinationCreateWithURL(
            heic as CFURL, UTType.heic.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(
            heicDestination, photo,
            [
                kCGImagePropertyOrientation: 3,
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.5],
            ] as CFDictionary)
        #expect(CGImageDestinationFinalize(heicDestination))
        let heicClean = StudioImageIO.properties(
            try await space.run("image.metadata", [heic]).url())
        #expect(heicClean[kCGImagePropertyGPSDictionary] == nil)
        #expect(heicClean[kCGImagePropertyOrientation] as? Int == 3)
    }

    @Test func imageToTextReadsTextOrExplains() async throws {
        let space = try Workspace()
        let source = space.url("sign.png")
        try ImageFixtures.text("Studio Rocks", at: source)
        let result = try await space.run("image.to-text", [source])
        let text = try String(contentsOf: try result.url(), encoding: .utf8)
        #expect(text.contains("Studio"))
        let blank = space.url("blank.png")
        try ImageFixtures.bordered(at: blank, inset: 400)
        await #expect(throws: StudioError.self) { try await space.run("image.to-text", [blank]) }
    }

    @Test func iconIncludesEverySize() async throws {
        let space = try Workspace()
        let source = space.url("logo.png")
        try Fixtures.image(at: source, width: 300, height: 200, alpha: true)
        let icns = try await space.run("image.icon", [source], ["shape": .text("rounded")])
        #expect(try icns.url().pathExtension == "icns")
        #expect(ImageFixtures.frameCount(try icns.url()) >= 5)
        let ico = try await space.run("image.icon", [source], ["format": .text("ico")])
        #expect(ImageFixtures.frameCount(try ico.url()) >= 5)
    }

    @Test func batchRunsProduceOneOutputPerImage() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for index in 0..<3 {
            let url = space.url("batch\(index).jpg")
            try ImageFixtures.photo(at: url, width: 300, height: 200, format: .jpeg)
            inputs.append(url)
        }
        let result = try await space.run("image.resize", inputs, ["width": .number(150)])
        #expect(result.outputs.count == 3)
        #expect(result.failures.isEmpty)
    }
}
