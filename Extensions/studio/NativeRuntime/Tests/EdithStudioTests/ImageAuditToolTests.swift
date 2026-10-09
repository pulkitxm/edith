import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

@Suite struct ImageAuditToolTests {
    func expectNoCameraData(_ url: URL, _ label: String) {
        #expect(AuditFiles.gps(url) == nil, "\(label) keeps GPS")
        #expect(
            AuditFiles.exifValue(url, kCGImagePropertyExifUserComment) == nil, "\(label) comment")
        #expect(AuditFiles.exifValue(url, kCGImagePropertyExifLensModel) == nil, "\(label) lens")
        #expect(
            AuditFiles.exifValue(url, kCGImagePropertyExifDateTimeOriginal) == nil,
            "\(label) date")
        #expect(AuditFiles.tiffValue(url, kCGImagePropertyTIFFMake) == nil, "\(label) make")
        #expect(AuditFiles.tiffValue(url, kCGImagePropertyTIFFModel) == nil, "\(label) model")
    }

    @Test func metadataRemovalCleansEveryFormatAndKeepsPixelsUpright() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for (name, type, orientation) in [
            ("phone.jpg", UTType.jpeg, 6), ("phone.png", UTType.png, 6),
            ("scan.tiff", UTType.tiff, 8), ("phone.heic", UTType.heic, 6),
            ("mirror.jpg", UTType.jpeg, 5), ("plain.png", UTType.png, 1),
        ] {
            let url = space.url(name)
            try AuditImages.photo(at: url, orientation: orientation, type: type, camera: true)
            #expect(AuditFiles.gps(url) != nil, "fixture \(name) has GPS")
            inputs.append(url)
        }
        let before = try AuditFiles.snapshot(inputs)
        let all = try await space.run("image.metadata", inputs)
        #expect(all.failures.isEmpty, "\(all.failures)")
        for input in inputs {
            let output = try all.output(from: input)
            let label = "everything \(input.lastPathComponent)"
            #expect(output.pathExtension == input.pathExtension, "\(label)")
            expectNoCameraData(output, label)
            let info = try #require(StudioImageIO.info(output))
            #expect(info.width == 120 && info.height == 80, "\(label) \(info)")
            let cleaned = try AuditBitmap(url: output)
            #expect(cleaned.matches(AuditLayout.upright), "\(label) \(cleaned.quadrants())")
            if ["jpg", "png", "tiff"].contains(input.pathExtension) {
                let original = try AuditBitmap(url: input)
                #expect(cleaned.meanDifference(original) == 0, "\(label) was re-encoded")
            }
        }
        #expect(
            all.notes == ["phone.heic had to be re-encoded to remove its metadata."],
            "\(all.notes)")

        let location = try await space.run("image.metadata", inputs, ["mode": .text("location")])
        #expect(location.failures.isEmpty, "\(location.failures)")
        for input in inputs {
            let output = try location.output(from: input)
            let label = "location \(input.lastPathComponent)"
            #expect(AuditFiles.gps(output) == nil, "\(label) keeps GPS")
            #expect(
                AuditFiles.exifValue(output, kCGImagePropertyExifUserComment) as? String
                    == "secret", "\(label) lost camera data")
            #expect(
                AuditFiles.tiffValue(output, kCGImagePropertyTIFFMake) as? String == "Acme",
                "\(label) lost the camera make")
            #expect(try AuditBitmap(url: output).matches(AuditLayout.upright), "\(label)")
        }
        #expect(try AuditFiles.snapshot(inputs) == before)
    }

    @Test func metadataRemovalKeepsAnimatedGIFsAnimated() async throws {
        let space = try Workspace()
        let gif = space.url("wave.gif")
        try AuditImages.animatedGIF(at: gif, delays: [0.1, 0.5, 0.25])
        let result = try await space.run("image.metadata", [gif])
        let output = try result.url()
        #expect(ImageFixtures.frameCount(output) == 3)
        let delays = AuditFiles.frameDelays(output)
        #expect(delays.count == 3)
        for (found, expected) in zip(delays, [0.1, 0.5, 0.25]) {
            #expect(abs(found - expected) < 0.011, "\(delays)")
        }
    }

    @Test func metadataRemovalTrustsTheFileContentsOverItsExtension() async throws {
        let space = try Workspace()
        let disguisedPNG = space.url("download.jpg")
        try AuditImages.photo(at: disguisedPNG, orientation: 6, type: .png, camera: true)
        let disguisedHEIC = space.url("export.jpg")
        try AuditImages.photo(at: disguisedHEIC, orientation: 8, type: .heic, camera: true)
        for input in [disguisedPNG, disguisedHEIC] {
            let result = try await space.run("image.metadata", [input])
            let output = try result.url()
            expectNoCameraData(output, input.lastPathComponent)
            #expect(try AuditBitmap(url: output).matches(AuditLayout.upright))
        }
    }

    @Test func compressRemovesLocationEvenWhenItKeepsTheOriginalBytes() async throws {
        let space = try Workspace()
        let jpeg = space.url("tight.jpg")
        try AuditImages.write(
            AuditImages.stored(Fixtures.photo(width: 160, height: 120), orientation: 6), to: jpeg,
            type: .jpeg, properties: AuditImages.cameraProperties(orientation: 6), quality: 0.2)
        let png = space.url("flat.png")
        try AuditImages.write(
            AuditImages.pixelGrid([[.red, .green], [.blue, .yellow]]), to: png, type: .png,
            properties: AuditImages.cameraProperties())
        let inputs = [jpeg, png]
        let result = try await space.run("image.compress", inputs)
        for input in inputs {
            let output = try result.output(from: input)
            let label = input.lastPathComponent
            #expect(
                StudioRunner.fileSize(output) <= StudioRunner.fileSize(input), "\(label) grew")
            expectNoCameraData(output, label)
            let original = try StudioImageIO.load(input)
            let compressed = try StudioImageIO.load(output)
            #expect(compressed.width == original.width && compressed.height == original.height)
            #expect(ImageFixtures.meanDifference(original, compressed) < 4, "\(label)")
        }
        let kept = try await space.run("image.compress", [jpeg], ["stripMetadata": .bool(false)])
        #expect(AuditFiles.gps(try kept.url()) != nil)
    }

    @Test func compressNeverGrowsAFileAndStaysVisuallyClose() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for (name, type) in [
            ("photo.jpg", UTType.jpeg), ("photo.png", .png), ("photo.heic", .heic),
            ("photo.tiff", .tiff),
        ] {
            let url = space.url(name)
            try AuditImages.write(
                Fixtures.photo(width: 240, height: 160), to: url, type: type, quality: 0.97)
            inputs.append(url)
        }
        let gray = space.url("gray.png")
        try AuditImages.grayscale(at: gray, type: .png)
        let palette = space.url("palette.png")
        try AuditImages.palettePNG(at: palette)
        let gif = space.url("anim.gif")
        try AuditImages.animatedGIF(at: gif, delays: [0.2, 0.3])
        inputs += [gray, palette, gif]
        for level in ["less", "recommended", "extreme"] {
            let result = try await space.run("image.compress", inputs, ["level": .text(level)])
            #expect(result.failures.isEmpty)
            for input in inputs {
                let output = try result.output(from: input)
                let label = "\(level) \(input.lastPathComponent)"
                #expect(output.pathExtension == input.pathExtension, "\(label)")
                #expect(
                    StudioRunner.fileSize(output) <= StudioRunner.fileSize(input), "\(label) grew")
                let difference = ImageFixtures.meanDifference(
                    try StudioImageIO.load(input), try StudioImageIO.load(output))
                #expect(difference < (level == "extreme" ? 16 : 10), "\(label) \(difference)")
            }
            #expect(ImageFixtures.frameCount(try result.output(from: gif)) == 2)
        }
    }

    @Test func compressKeepsFormatsItCannotWriteWhenConvertingWouldGrowThem() async throws {
        let space = try Workspace()
        let stripes = AuditImages.context(600, 400)
        for row in 0..<400 {
            stripes.setFillColor((row % 2 == 0 ? AuditRGB.red : AuditRGB.blue).cgColor)
            stripes.fill(CGRect(x: 0, y: row, width: 600, height: 1))
        }
        let tga = space.url("sprite.tga")
        try AuditImages.write(
            stripes.makeImage()!, to: tga, type: UTType("com.truevision.tga-image")!)
        let result = try await space.run("image.compress", [tga])
        let output = try result.url()
        #expect(StudioRunner.fileSize(output) <= StudioRunner.fileSize(tga))
        #expect(StudioImageIO.info(output)?.width == 600)
        #expect(result.notes.contains { $0.contains("kept as it was") }, "\(result.notes)")

        let bmp = space.url("scan.bmp")
        try AuditImages.write(Fixtures.photo(width: 300, height: 200), to: bmp, type: .bmp)
        let converted = try await space.run("image.compress", [bmp])
        #expect(try converted.url().pathExtension == "jpg")
        #expect(StudioRunner.fileSize(try converted.url()) < StudioRunner.fileSize(bmp))
    }

    @Test func resizeHitsExactPixelSizes() async throws {
        let space = try Workspace()
        let landscape = space.url("land.png")
        try AuditImages.write(
            AuditImages.quadrants(width: 400, height: 300), to: landscape, type: .png)
        let portrait = space.url("portrait.jpg")
        try AuditImages.photo(
            at: portrait, orientation: 6, upright: AuditImages.quadrants(width: 300, height: 400))
        let cases: [(URL, [String: StudioValue], (Int, Int))] = [
            (landscape, ["width": .number(123)], (123, 92)),
            (landscape, ["width": .number(0), "height": .number(77)], (103, 77)),
            (landscape, ["width": .number(200), "height": .number(200)], (200, 150)),
            (landscape, ["width": .number(150), "height": .number(90)], (120, 90)),
            (
                landscape,
                ["width": .number(250), "height": .number(80), "keepAspect": .bool(false)],
                (250, 80)
            ),
            (
                landscape,
                [
                    "width": .number(900), "height": .number(300), "keepAspect": .bool(false),
                    "noEnlarge": .bool(false),
                ], (900, 300)
            ),
            (landscape, ["mode": .text("percent"), "percent": .number(33)], (132, 99)),
            (landscape, ["mode": .text("longest"), "longest": .number(100)], (100, 75)),
            (landscape, ["mode": .text("longest"), "longest": .number(1000)], (400, 300)),
            (
                landscape,
                ["mode": .text("longest"), "longest": .number(1000), "noEnlarge": .bool(false)],
                (1000, 750)
            ),
            (portrait, ["mode": .text("longest"), "longest": .number(200)], (150, 200)),
            (portrait, ["width": .number(150)], (150, 200)),
        ]
        for (input, values, expected) in cases {
            let output = try await space.run("image.resize", [input], values).url()
            let bitmap = try AuditBitmap(url: output)
            #expect(
                bitmap.width == expected.0 && bitmap.height == expected.1,
                "\(input.lastPathComponent) \(values) -> \(bitmap.width)x\(bitmap.height)")
            let stretched = values["keepAspect"] == .bool(false)
            if !stretched {
                #expect(bitmap.matches(AuditLayout.upright), "\(values) \(bitmap.quadrants())")
            }
        }
    }

    @Test func cropSelectsExactlyTheRequestedRegion() async throws {
        let space = try Workspace()
        let colors: [[AuditRGB]] = [
            [.red, .green, .blue, .yellow],
            [.white, .black, AuditRGB(255, 0, 255), AuditRGB(0, 255, 255)],
            [AuditRGB(128, 0, 0), AuditRGB(0, 128, 0), AuditRGB(0, 0, 128), AuditRGB(128, 128, 0)],
        ]
        let cell = 40
        let context = AuditImages.context(4 * cell, 3 * cell)
        for (row, line) in colors.enumerated() {
            for (column, color) in line.enumerated() {
                context.setFillColor(color.cgColor)
                context.fill(
                    CGRect(x: column * cell, y: (2 - row) * cell, width: cell, height: cell))
            }
        }
        let board = space.url("board.png")
        try AuditImages.write(context.makeImage()!, to: board, type: .png)
        let area = try AuditBitmap(
            url: try await space.run(
                "image.crop", [board],
                [
                    "mode": .text("area"),
                    "area": .rect(StudioRect(x: 0.25, y: 1.0 / 3, width: 0.5, height: 2.0 / 3)),
                ]
            ).url())
        #expect(area.width == 80 && area.height == 80)
        #expect(area.rgb(20, 20).isClose(to: colors[1][1], tolerance: 2))
        #expect(area.rgb(60, 20).isClose(to: colors[1][2], tolerance: 2))
        #expect(area.rgb(20, 60).isClose(to: colors[2][1], tolerance: 2))
        #expect(area.rgb(60, 60).isClose(to: colors[2][2], tolerance: 2))
        #expect(area.rgb(0, 0).isClose(to: colors[1][1], tolerance: 2))
        #expect(area.rgb(79, 79).isClose(to: colors[2][2], tolerance: 2))

        let anchors: [(String, Int)] = [("left", 0), ("center", 20), ("right", 40)]
        for (anchor, offset) in anchors {
            let square = try AuditBitmap(
                url: try await space.run(
                    "image.crop", [board], ["aspect": .text("1:1"), "position": .text(anchor)]
                ).url())
            #expect(square.width == 120 && square.height == 120, "\(anchor)")
            let firstColumn = offset / cell
            #expect(
                square.rgb(2, 2).isClose(to: colors[0][firstColumn], tolerance: 2),
                "\(anchor) \(square.rgb(2, 2))")
            #expect(
                square.rgb(117, 117).isClose(
                    to: colors[2][(offset + 119) / cell], tolerance: 2), "\(anchor)")
        }
        let top = try AuditBitmap(
            url: try await space.run(
                "image.crop", [board], ["aspect": .text("16:9"), "position": .text("top")]
            ).url())
        #expect(top.width == 160 && top.height == 90)
        #expect(top.rgb(2, 2).isClose(to: colors[0][0], tolerance: 2))
        #expect(top.rgb(2, 85).isClose(to: colors[2][0], tolerance: 2))
        let bottom = try AuditBitmap(
            url: try await space.run(
                "image.crop", [board], ["aspect": .text("16:9"), "position": .text("bottom")]
            ).url())
        #expect(bottom.rgb(2, 2).isClose(to: colors[0][0], tolerance: 2))
        #expect(bottom.rgb(2, 89).isClose(to: colors[2][0], tolerance: 2))
        #expect(bottom.rgb(2, 20).isClose(to: colors[1][0], tolerance: 2))
    }

    @Test func trimRemovesPlainBordersFromPhotosCutoutsAndAnimations() async throws {
        let space = try Workspace()
        let noisy = space.url("scan.jpg")
        let context = AuditImages.context(300, 200)
        context.setFillColor(gray: 0.97, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 300, height: 200))
        context.draw(
            AuditImages.quadrants(width: 180, height: 100),
            in: CGRect(x: 60, y: 40, width: 180, height: 100))
        try AuditImages.write(context.makeImage()!, to: noisy, type: .jpeg, quality: 0.8)
        let trimmed = try AuditBitmap(
            url: try await space.run("image.crop", [noisy], ["mode": .text("trim")]).url())
        #expect(abs(trimmed.width - 180) <= 2 && abs(trimmed.height - 100) <= 2)
        #expect(trimmed.matches(AuditLayout.upright))

        let cutout = space.url("cutout.png")
        let clear = AuditImages.context(200, 200, alpha: true)
        clear.clear(CGRect(x: 0, y: 0, width: 200, height: 200))
        clear.draw(
            AuditImages.quadrants(width: 100, height: 60),
            in: CGRect(x: 30, y: 90, width: 100, height: 60))
        try AuditImages.write(clear.makeImage()!, to: cutout, type: .png)
        let tight = try AuditBitmap(
            url: try await space.run("image.crop", [cutout], ["mode": .text("trim")]).url())
        #expect(tight.width == 100 && tight.height == 60)
        #expect(tight.matches(AuditLayout.upright))

        let frames = (0..<3).map { index -> (image: CGImage, delay: Double) in
            let frame = AuditImages.context(120, 90)
            frame.setFillColor(gray: 1, alpha: 1)
            frame.fill(CGRect(x: 0, y: 0, width: 120, height: 90))
            frame.setFillColor(([AuditRGB.red, .green, .blue][index]).cgColor)
            frame.fill(CGRect(x: 20 + index * 10, y: 30, width: 50, height: 30))
            return (frame.makeImage()!, 0.2)
        }
        let gif = space.url("bounce.gif")
        try StudioImageIO.writeAnimatedGIF(frames, to: gif)
        let result = try await space.run("image.crop", [gif], ["mode": .text("trim")])
        let output = try result.url()
        #expect(ImageFixtures.frameCount(output) == 3)
        let size = try #require(ImageFixtures.size(output))
        #expect(size == (70, 30), "trimmed animation is \(size)")
    }

    @Test func convertWritesEveryFormatThatReopensAtTheRightSize() async throws {
        let space = try Workspace()
        let source = space.url("camera.jpg")
        try AuditImages.photo(at: source, orientation: 6, camera: true)
        for format in StudioImageFormat.writable {
            let result = try await space.run(
                "image.convert", [source], ["format": .text(format.fileExtension)])
            let output = try result.url()
            let label = format.title
            #expect(output.pathExtension == format.fileExtension, "\(label)")
            switch format {
            case .pdf:
                let page = try #require(try result.document().page(at: 0))
                let box = page.bounds(for: .mediaBox)
                #expect(abs(box.width - 120) < 0.5 && abs(box.height - 80) < 0.5, "\(box)")
            case .ico, .icns:
                let largest = AuditBitmap(try AuditFiles.largestFrame(output))
                #expect(largest.width == largest.height, "\(label)")
                let area = CGRect(
                    x: 0, y: Double(largest.height) / 6, width: Double(largest.width),
                    height: Double(largest.height) * 2 / 3)
                #expect(
                    zip(largest.quadrants(inset: area), AuditLayout.upright).allSatisfy {
                        $0.isClose(to: $1)
                    }, "\(label) \(largest.quadrants(inset: area))")
            default:
                let info = try #require(StudioImageIO.info(output), "\(label)")
                #expect(info.width == 120 && info.height == 80, "\(label) \(info)")
                let bitmap = try AuditBitmap(url: output)
                #expect(
                    bitmap.matches(AuditLayout.upright, tolerance: format == .gif ? 50 : 40),
                    "\(label) \(bitmap.quadrants())")
            }
        }
        let tiff = try await space.run("image.convert", [source], ["format": .text("tiff")])
        #expect(AuditFiles.tiffValue(try tiff.url(), kCGImagePropertyTIFFMake) as? String == "Acme")
        #expect(AuditFiles.gps(try tiff.url()) != nil)
        let clean = try await space.run(
            "image.convert", [source], ["format": .text("png"), "keepMetadata": .bool(false)])
        expectNoCameraData(try clean.url(), "convert without metadata")
    }

    @Test func iconsContainEveryStandardSize() async throws {
        let space = try Workspace()
        let logo = space.url("logo.png")
        try AuditImages.write(AuditImages.quadrants(width: 300, height: 200), to: logo, type: .png)
        let icns = try await space.run("image.icon", [logo])
        let icnsSizes = Set(AuditFiles.frameSizes(try icns.url()))
        #expect(icnsSizes.isSuperset(of: [16, 32, 64, 128, 256, 512, 1024]), "\(icnsSizes)")
        let ico = try await space.run("image.icon", [logo], ["format": .text("ico")])
        #expect(Set(AuditFiles.frameSizes(try ico.url())) == [16, 24, 32, 48, 64, 256])

        let square = AuditBitmap(try AuditFiles.largestFrame(try icns.url()))
        #expect(square.width == 1024)
        #expect(square.alpha(512, 40) < 5)
        #expect(square.alpha(512, 512) > 250)
        let rounded = AuditBitmap(
            try AuditFiles.largestFrame(
                try await space.run("image.icon", [logo], ["shape": .text("rounded")]).url()))
        #expect(rounded.alpha(2, 2) < 5)
        #expect(rounded.alpha(512, 4) > 250)
        #expect(rounded.rgb(200, 200).isClose(to: .red))
        let margin = AuditBitmap(
            try AuditFiles.largestFrame(
                try await space.run(
                    "image.icon", [logo], ["shape": .text("rounded"), "margin": .bool(true)]
                ).url()))
        #expect(margin.alpha(512, 90) < 5)
        #expect(margin.alpha(512, 110) > 250)
    }
}
