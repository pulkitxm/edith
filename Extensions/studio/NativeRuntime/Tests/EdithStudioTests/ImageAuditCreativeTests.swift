import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

@Suite struct ImageAuditCreativeTests {
    static func white(_ space: Workspace, _ name: String, width: Int = 300, height: Int = 200)
        throws -> URL
    {
        let url = space.url(name)
        let context = AuditImages.context(width, height)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        try AuditImages.write(context.makeImage()!, to: url, type: .png)
        return url
    }

    static func bounds(
        _ bitmap: AuditBitmap, where predicate: (AuditRGB) -> Bool
    ) -> CGRect? {
        var minX = Int.max
        var minY = Int.max
        var maxX = -1
        var maxY = -1
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width where predicate(bitmap.rgb(x, y)) {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        guard maxX >= minX else { return nil }
        return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    static func isBlue(_ color: AuditRGB) -> Bool { color.b > 150 && color.r < 110 }

    static func isRed(_ color: AuditRGB) -> Bool { color.r > 150 && color.g < 110 && color.b < 110 }

    @Test func textWatermarksLandAtEveryAnchor() async throws {
        let space = try Workspace()
        let source = try Self.white(space, "page.png")
        let anchors: [(String, Double, Double)] = [
            ("top-left", 0, 0), ("top", 0.5, 0), ("top-right", 1, 0), ("left", 0, 0.5),
            ("center", 0.5, 0.5), ("right", 1, 0.5), ("bottom-left", 0, 1), ("bottom", 0.5, 1),
            ("bottom-right", 1, 1),
        ]
        for (anchor, ux, uy) in anchors {
            let result = try await space.run(
                "image.watermark", [source],
                [
                    "text": .text("MARK"), "color": .text("#0000FF"), "opacity": .number(1),
                    "rotation": .number(0), "size": .number(0.25), "position": .text(anchor),
                ])
            let bitmap = try AuditBitmap(url: try result.url())
            let box = try #require(Self.bounds(bitmap, where: Self.isBlue), "\(anchor)")
            let margin = 200 * 0.04
            let expectedX = margin + (300 - 2 * margin - box.width) * ux
            let expectedY = margin + (200 - 2 * margin - box.height) * uy
            #expect(abs(box.minX - expectedX) < 8, "\(anchor) x \(box)")
            #expect(abs(box.minY - expectedY) < 10, "\(anchor) y \(box)")
            #expect(abs(box.width - 75) < 8, "\(anchor) width \(box)")
        }
        let tiled = try AuditBitmap(
            url: try await space.run(
                "image.watermark", [source],
                [
                    "text": .text("MARK"), "color": .text("#0000FF"), "opacity": .number(1),
                    "size": .number(0.2), "position": .text("tiled"),
                ]
            ).url())
        for column in 0..<3 {
            for row in 0..<2 {
                let cell = CGRect(x: column * 100, y: row * 100, width: 100, height: 100)
                #expect(tiled.count(in: cell, step: 2) { c, _ in Self.isBlue(c) } > 0)
            }
        }
    }

    @Test func imageWatermarksKeepTheirAspectAndOpacity() async throws {
        let space = try Workspace()
        let source = try Self.white(space, "page.png")
        let logo = space.url("logo.png")
        try AuditImages.photo(
            at: logo, orientation: 6, type: .png,
            upright: AuditImages.pixelGrid([[.red, .red], [.red, .red]]))
        let tall = space.url("tall.jpg")
        try AuditImages.photo(
            at: tall, orientation: 6,
            upright: AuditImages.quadrants(width: 40, height: 80))
        let result = try await space.run(
            "image.watermark", [source],
            [
                "kind": .text("image"), "image": .text(tall.path), "opacity": .number(1),
                "rotation": .number(0), "size": .number(0.2), "position": .text("top-left"),
            ])
        let bitmap = try AuditBitmap(url: try result.url())
        let box = try #require(Self.bounds(bitmap) { $0.distance(to: .white) > 30 })
        #expect(abs(box.width - 60) <= 2 && abs(box.height - 120) <= 2, "\(box)")
        #expect(abs(box.minX - 8) <= 2 && abs(box.minY - 8) <= 2, "\(box)")
        let inner = bitmap.quadrants(inset: box)
        #expect(zip(inner, AuditLayout.upright).allSatisfy { $0.isClose(to: $1) }, "\(inner)")
        let faint = try AuditBitmap(
            url: try await space.run(
                "image.watermark", [source],
                [
                    "kind": .text("image"), "image": .text(logo.path), "opacity": .number(0.5),
                    "rotation": .number(0), "size": .number(0.2), "position": .text("center"),
                ]
            ).url())
        let middle = faint.rgb(150, 100)
        #expect(abs(middle.g - 151) < 12 && middle.r > 225, "\(middle)")
    }

    @Test func memeCaptionsSitAtTheTopAndBottomCentered() async throws {
        let space = try Workspace()
        let source = try Self.white(space, "cat.png", width: 400, height: 300)
        let result = try await space.run(
            "image.meme", [source],
            [
                "top": .text("top line"), "bottom": .text("bottom"), "color": .text("#FF0000"),
                "stroke": .text("#FF0000"),
            ])
        let bitmap = try AuditBitmap(url: try result.url())
        #expect(bitmap.width == 400 && bitmap.height == 300)
        let topHalf = CGRect(x: 0, y: 0, width: 400, height: 150)
        let bottomHalf = CGRect(x: 0, y: 150, width: 400, height: 150)
        let middle = CGRect(x: 0, y: 95, width: 400, height: 110)
        #expect(bitmap.count(in: middle) { c, _ in Self.isRed(c) } == 0)
        var top: CGRect?
        var bottom: CGRect?
        for (area, slot) in [(topHalf, 0), (bottomHalf, 1)] {
            var minX = Int.max
            var maxX = -1
            var minY = Int.max
            var maxY = -1
            for y in Int(area.minY)..<Int(area.maxY) {
                for x in 0..<400 where Self.isRed(bitmap.rgb(x, y)) {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                }
            }
            let box = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            if slot == 0 { top = box } else { bottom = box }
        }
        let topBox = try #require(top)
        let bottomBox = try #require(bottom)
        #expect(topBox.minY < 30, "\(topBox)")
        #expect(bottomBox.maxY > 270, "\(bottomBox)")
        #expect(abs(topBox.midX - 200) < 6, "\(topBox)")
        #expect(abs(bottomBox.midX - 200) < 6, "\(bottomBox)")
    }

    @Test func solidAndPolaroidBordersAreCrispAndExact() async throws {
        let space = try Workspace()
        let source = space.url("pic.png")
        try AuditImages.write(
            AuditImages.quadrants(width: 125, height: 100), to: source, type: .png)
        let original = try AuditBitmap(url: source)
        let solid = try AuditBitmap(
            url: try await space.run(
                "image.border", [source], ["width": .number(0.1), "color": .text("#000000")]
            ).url())
        #expect(solid.width == 145 && solid.height == 120)
        for (x, y) in [(0, 0), (9, 60), (135, 60), (70, 119), (70, 9)] {
            #expect(solid.rgb(x, y) == .black, "solid ring \(x),\(y) \(solid.rgb(x, y))")
        }
        for (x, y) in [(0, 0), (124, 0), (0, 99), (124, 99), (62, 49), (63, 50)] {
            #expect(
                solid.rgb(x + 10, y + 10).isClose(to: original.rgb(x, y), tolerance: 1),
                "solid inner \(x),\(y)")
        }
        for width in [0.0, 0.05, 0.07] {
            let polaroid = try AuditBitmap(
                url: try await space.run(
                    "image.border", [source],
                    [
                        "style": .text("polaroid"), "width": .number(width),
                        "color": .text("#FFFFFF"),
                    ]
                ).url())
            let side = (polaroid.width - 125)
            #expect(side % 2 == 0, "polaroid \(width) width \(polaroid.width)")
            let inset = side / 2
            let bottom = polaroid.height - 100 - inset
            #expect(bottom > inset, "polaroid \(width) bottom \(bottom)")
            for x in [inset, inset + 30, inset + 124] {
                #expect(polaroid.rgb(x, inset - 1) == .white, "polaroid \(width) top border")
                #expect(
                    polaroid.rgb(x, inset).isClose(to: original.rgb(x - inset, 0), tolerance: 1),
                    "polaroid \(width) first row \(polaroid.rgb(x, inset))")
                #expect(
                    polaroid.rgb(x, inset + 99).isClose(
                        to: original.rgb(x - inset, 99), tolerance: 1),
                    "polaroid \(width) last row \(polaroid.rgb(x, inset + 99))")
                #expect(polaroid.rgb(x, inset + 100) == .white, "polaroid \(width) bottom border")
            }
            #expect(polaroid.rgb(inset - 1, 50) == .white)
            #expect(polaroid.rgb(inset + 125, 50) == .white)
        }
    }

    @Test func roundedAndShadowBordersKeepTransparency() async throws {
        let space = try Workspace()
        let jpeg = space.url("large.jpg")
        try AuditImages.write(
            AuditImages.quadrants(width: 1200, height: 900), to: jpeg, type: .jpeg)
        let rounded = try await space.run(
            "image.border", [jpeg],
            ["style": .text("rounded"), "width": .number(0), "radius": .number(0.004)])
        let output = try rounded.url()
        #expect(output.pathExtension == "png", "\(output.lastPathComponent)")
        let bitmap = try AuditBitmap(url: output)
        #expect(bitmap.width == 1200 && bitmap.height == 900)
        #expect(bitmap.alpha(0, 0) < 10)
        #expect(bitmap.alpha(1199, 899) < 10)
        #expect(bitmap.alpha(600, 0) > 250)
        let shadow = try AuditBitmap(
            url: try await space.run("image.border", [jpeg], ["style": .text("shadow")]).url())
        #expect(shadow.width == 1290 && shadow.height == 990)
        #expect(shadow.alpha(0, 0) < 10)
        #expect(shadow.rgb(45 + 300, 45 + 225).isClose(to: .red))
    }

    @Test func collageCellsSpacingAndOrderAreExact() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for (index, color) in [AuditRGB.red, .green, .blue, .yellow].enumerated() {
            let url = space.url("tile\(index).png")
            try AuditImages.write(
                AuditImages.quadrants(
                    width: 200, height: 100, colors: Array(repeating: color, count: 4)),
                to: url, type: .png)
            inputs.append(url)
        }
        let grid = try AuditBitmap(
            url: try await space.run(
                "image.collage", inputs,
                [
                    "columns": .number(2), "width": .number(1000), "spacing": .number(20),
                    "background": .text("#000000"), "format": .text("png"),
                ]
            ).url())
        #expect(grid.width == 1000 && grid.height == 530)
        let cells: [(CGRect, AuditRGB)] = [
            (CGRect(x: 20, y: 20, width: 470, height: 235), .red),
            (CGRect(x: 510, y: 20, width: 470, height: 235), .green),
            (CGRect(x: 20, y: 275, width: 470, height: 235), .blue),
            (CGRect(x: 510, y: 275, width: 470, height: 235), .yellow),
        ]
        for (rect, color) in cells {
            for point in [
                CGPoint(x: rect.minX + 1, y: rect.minY + 1),
                CGPoint(x: rect.maxX - 2, y: rect.maxY - 2),
                CGPoint(x: rect.midX, y: rect.midY),
            ] {
                #expect(
                    grid.rgb(Int(point.x), Int(point.y)).isClose(to: color, tolerance: 4),
                    "cell \(color) at \(point) \(grid.rgb(Int(point.x), Int(point.y)))")
            }
            #expect(grid.rgb(Int(rect.minX) - 2, Int(rect.midY)) == .black)
            #expect(grid.rgb(Int(rect.midX), Int(rect.minY) - 2) == .black)
        }
        #expect(grid.rgb(500, 265) == .black)

        let row = try AuditBitmap(
            url: try await space.run(
                "image.collage", inputs,
                [
                    "layout": .text("horizontal"), "width": .number(1000), "spacing": .number(20),
                    "background": .text("#000000"), "format": .text("png"),
                ]
            ).url())
        #expect(row.width == 1000 && abs(row.height - 153) <= 1)
        for (index, color) in [AuditRGB.red, .green, .blue, .yellow].enumerated() {
            let x = 20 + index * 245 + 112
            #expect(row.rgb(x, 76).isClose(to: color, tolerance: 4), "row \(index)")
        }
        let column = try AuditBitmap(
            url: try await space.run(
                "image.collage", Array(inputs.prefix(2)),
                [
                    "layout": .text("vertical"), "width": .number(420), "spacing": .number(10),
                    "background": .text("#000000"), "format": .text("png"),
                ]
            ).url())
        #expect(column.width == 420 && column.height == 430)
        #expect(column.rgb(210, 110).isClose(to: .red, tolerance: 4))
        #expect(column.rgb(210, 320).isClose(to: .green, tolerance: 4))
        #expect(column.rgb(210, 215) == .black)
    }

    @Test func makeGIFKeepsFrameCountOrderDelaysAndLooping() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for (index, color) in [AuditRGB.red, .green, .blue].enumerated() {
            let url = space.url("frame\(index).png")
            try AuditImages.write(
                AuditImages.quadrants(
                    width: 120, height: 80, colors: Array(repeating: color, count: 4)),
                to: url, type: .png)
            inputs.append(url)
        }
        let looping = try await space.run(
            "image.make-gif", inputs, ["width": .number(60), "delay": .number(0.35)])
        let output = try looping.url()
        let frames = try StudioImageIO.frames(output)
        #expect(frames.count == 3)
        for (frame, color) in zip(frames, [AuditRGB.red, .green, .blue]) {
            #expect(frame.image.width == 60 && frame.image.height == 40)
            #expect(abs(frame.delay - 0.35) < 0.011)
            #expect(AuditBitmap(frame.image).rgb(30, 20).isClose(to: color, tolerance: 30))
        }
        #expect(ImageToolSupport.loopCount(output) == 0)
        let once = try await space.run("image.make-gif", inputs, ["loop": .bool(false)])
        #expect(ImageToolSupport.loopCount(try once.url()) == 1)
        #expect(ImageFixtures.size(try once.url())! == (640, 427))
    }

    @Test func animatedGIFsKeepEveryFrameAndDelayThroughEachTool() async throws {
        let space = try Workspace()
        let gif = space.url("anim.gif")
        let delays = [0.1, 0.5, 0.25]
        try AuditImages.animatedGIF(at: gif, delays: delays, size: (60, 40))
        let before = try Data(contentsOf: gif)
        let cases: [(String, [String: StudioValue])] = [
            ("image.resize", ["width": .number(30)]),
            ("image.crop", ["aspect": .text("1:1")]),
            ("image.rotate", [:]),
            ("image.watermark", [:]),
            ("image.adjust", ["filter": .text("mono")]),
            ("image.border", [:]),
            ("image.compress", ["maxSize": .number(30)]),
            ("image.convert", ["format": .text("gif")]),
            ("image.upscale", ["scale": .text("3")]),
            ("image.meme", ["top": .text("hi"), "bottom": .text("there")]),
            ("image.blur-faces", ["style": .text("pixelate")]),
        ]
        for (id, values) in cases {
            let output = try await space.run(id, [gif], values).url()
            #expect(output.pathExtension == "gif", "\(id)")
            let found = AuditFiles.frameDelays(output)
            #expect(found.count == 3, "\(id)")
            for (value, expected) in zip(found, delays) {
                #expect(abs(value - expected) < 0.011, "\(id) \(found)")
            }
            if id == "image.compress" || id == "image.resize" {
                #expect(ImageFixtures.size(output)! == (30, 20), "\(id)")
            }
            if id == "image.upscale" {
                #expect(ImageFixtures.size(output)! == (180, 120), "\(id)")
            }
        }
        #expect(try Data(contentsOf: gif) == before)
    }

    @Test func upscaleEnlargesExactlyAndKeepsColorsAndAlpha() async throws {
        let space = try Workspace()
        let odd = space.url("odd.png")
        try AuditImages.write(
            AuditImages.transparentCorner(width: 37, height: 23), to: odd, type: .png)
        for scale in [2, 3, 4] {
            let output = try await space.run("image.upscale", [odd], ["scale": .text("\(scale)")])
            let bitmap = try AuditBitmap(url: try output.url())
            #expect(bitmap.width == 37 * scale && bitmap.height == 23 * scale)
            let found = bitmap.quadrants()
            #expect(found[0].isClose(to: .red, tolerance: 20), "\(scale)x \(found)")
            #expect(found[2].isClose(to: .blue, tolerance: 20), "\(scale)x \(found)")
            #expect(bitmap.alpha(bitmap.width * 7 / 8, bitmap.height * 7 / 8) < 10)
            #expect(bitmap.alpha(bitmap.width / 8, bitmap.height / 8) > 245)
        }
    }

    @Test func adjustmentsMoveColorsInTheRightDirection() async throws {
        let space = try Workspace()
        let source = space.url("swatch.png")
        try AuditImages.write(
            AuditImages.quadrants(
                width: 80, height: 80,
                colors: [AuditRGB(150, 100, 80), AuditRGB(150, 100, 80), .blue, .yellow]),
            to: source, type: .png)
        func swatch(_ values: [String: StudioValue]) async throws -> AuditRGB {
            try AuditBitmap(url: try await space.run("image.adjust", [source], values).url())
                .average(around: CGPoint(x: 40, y: 20), radius: 3)
        }
        let base = AuditRGB(150, 100, 80)
        let brighter = try await swatch(["exposure": .number(0.5)])
        #expect(brighter.r > base.r + 20 && brighter.g > base.g + 20, "\(brighter)")
        let darker = try await swatch(["brightness": .number(-0.5)])
        #expect(darker.r < base.r - 20, "\(darker)")
        let gray = try await swatch(["saturation": .number(-1)])
        #expect(abs(gray.r - gray.b) < 6, "\(gray)")
        let warm = try await swatch(["warmth": .number(0.8)])
        #expect(warm.r - warm.b > base.r - base.b + 10, "\(warm)")
        let cool = try await swatch(["warmth": .number(-0.8)])
        #expect(cool.r - cool.b < base.r - base.b - 10, "\(cool)")
        let mono = try await swatch(["filter": .text("mono")])
        #expect(abs(mono.r - mono.g) < 4 && abs(mono.g - mono.b) < 4, "\(mono)")
        let half = try await swatch(["filter": .text("mono"), "intensity": .number(0.5)])
        #expect(half.r < base.r && half.r > mono.r, "\(half)")
        let vignette = try AuditBitmap(
            url: try await space.run("image.adjust", [source], ["vignette": .number(1)]).url())
        #expect(vignette.rgb(0, 0).r < vignette.rgb(40, 40).r || vignette.rgb(0, 0).r < 150)
    }

    @Test func adjustmentsNeverTintTransparentAreas() async throws {
        let space = try Workspace()
        let source = space.url("cutout.png")
        try AuditImages.write(AuditImages.transparentCorner(), to: source, type: .png)
        let variants: [[String: StudioValue]] = [
            ["brightness": .number(0.6)], ["exposure": .number(0.8)], ["warmth": .number(1)],
            ["contrast": .number(-0.8)], ["saturation": .number(1)], ["filter": .text("sepia")],
            ["filter": .text("fade")], ["filter": .text("vintage")], ["filter": .text("instant")],
            ["vignette": .number(1)], ["sharpness": .number(1)],
        ]
        for values in variants {
            let output = try AuditBitmap(
                url: try await space.run("image.adjust", [source], values).url())
            let corner = output.count(in: CGRect(x: 64, y: 44, width: 52, height: 32)) { _, alpha in
                alpha > 3
            }
            #expect(corner == 0, "\(values) painted \(corner) transparent pixels")
            #expect(output.alpha(30, 20) > 250, "\(values)")
        }
    }

    @Test func blurFacesBlursExactlyTheFaceItFinds() async throws {
        let space = try Workspace()
        let scene = AuditImages.faceScene()
        let upright = space.url("person.png")
        try AuditImages.write(scene, to: upright, type: .png)
        let sideways = space.url("person.jpg")
        try AuditImages.write(
            AuditImages.stored(scene, orientation: 6), to: sideways, type: .jpeg,
            properties: [kCGImagePropertyOrientation: 6], quality: 1)
        let faces = try await StudioVision.faces(in: scene)
        guard let face = faces.first else { return }
        let box = CGRect(
            x: face.minX * 600, y: (1 - face.maxY) * 400, width: face.width * 600,
            height: face.height * 400)
        for input in [upright, sideways] {
            let result = try await space.run(
                "image.blur-faces", [input], ["margin": .number(0), "strength": .number(1)])
            #expect(result.notes.contains { $0.contains("1 face") }, "\(result.notes)")
            let output = try AuditBitmap(url: try result.url())
            let original = try AuditBitmap(url: input)
            #expect(output.width == 600 && output.height == 400)
            let inner = box.insetBy(dx: box.width * 0.15, dy: box.height * 0.15)
            #expect(
                output.detail(in: inner) < original.detail(in: inner) * 0.6,
                "\(input.lastPathComponent) face not blurred")
            let outside = CGRect(x: 420, y: 20, width: 160, height: 360)
            #expect(output.meanDifference(original) > 0)
            #expect(
                output.count(in: outside, step: 3) { color, _ in
                    color.distance(to: AuditRGB(153, 191, 230)) > 12
                } == 0, "\(input.lastPathComponent) blur leaked outside the face")
        }

        let gif = space.url("wave.gif")
        let shifted = AuditImages.context(600, 400)
        shifted.draw(scene, in: CGRect(x: 0, y: 0, width: 600, height: 400))
        try StudioImageIO.writeAnimatedGIF([(scene, 0.3), (shifted.makeImage()!, 0.6)], to: gif)
        let gifFaces = try await StudioVision.faces(in: try StudioImageIO.frames(gif)[0].image)
        guard !gifFaces.isEmpty else { return }
        let animated = try await space.run(
            "image.blur-faces", [gif], ["margin": .number(0), "strength": .number(1)])
        let output = try animated.url()
        #expect(output.pathExtension == "gif")
        let frames = try StudioImageIO.frames(output)
        #expect(frames.count == 2)
        #expect(abs(frames[1].delay - 0.6) < 0.011)
        let before = try StudioImageIO.frames(gif)
        for (index, frame) in frames.enumerated() {
            let inner = box.insetBy(dx: box.width * 0.15, dy: box.height * 0.15)
            #expect(
                AuditBitmap(frame.image).detail(in: inner)
                    < AuditBitmap(before[index].image).detail(in: inner) * 0.6,
                "gif frame \(index) face not blurred")
        }
    }

    @Test func faceBoxesMapFromVisionSpaceAndClipAtTheEdges() throws {
        let rect = FaceBlur.rect(CGRect(x: 0.4, y: 0.1, width: 0.2, height: 0.3), margin: 0.25)
        #expect(abs(rect.x - 0.35) < 1e-9 && abs(rect.width - 0.3) < 1e-9)
        #expect(abs(rect.y - 0.525) < 1e-9 && abs(rect.height - 0.45) < 1e-9)
        let corner = FaceBlur.rect(CGRect(x: 0, y: 0.8, width: 0.2, height: 0.2), margin: 0.2)
        #expect(abs(corner.x) < 1e-9 && abs(corner.width - 0.24) < 1e-9, "\(corner)")
        #expect(abs(corner.y) < 1e-9 && abs(corner.height - 0.24) < 1e-9, "\(corner)")
        let edge = FaceBlur.rect(CGRect(x: 0.9, y: 0, width: 0.2, height: 0.1), margin: 0)
        #expect(abs(edge.x - 0.9) < 1e-9 && abs(edge.width - 0.1) < 1e-9, "\(edge)")

        let noise = AuditBitmap(Fixtures.photo(width: 200, height: 100))
        let source = Fixtures.photo(width: 200, height: 100)
        for style in ImageRedactionStyle.allCases {
            let redacted = AuditBitmap(
                try ImageEditRenderer.redact(
                    source, rects: [StudioRect(x: 0.25, y: 0.2, width: 0.5, height: 0.6)],
                    style: ImageRedaction(style: style, strength: 1)))
            var outside = 0
            var inside = 0
            for y in 0..<100 {
                for x in 0..<200 {
                    let changed = redacted.rgb(x, y).distance(to: noise.rgb(x, y)) > 2
                    let within = x >= 50 && x < 150 && y >= 20 && y < 80
                    if within, changed { inside += 1 }
                    if !within, changed { outside += 1 }
                }
            }
            #expect(outside == 0, "\(style) changed \(outside) pixels outside")
            #expect(inside > 4000, "\(style) changed only \(inside) pixels inside")
        }
    }

    @Test func backgroundRemovalCompositesMaskAndKeepsAlphaInHEIC() throws {
        let photo = AuditImages.quadrants(width: 100, height: 80)
        let maskContext = AuditImages.context(100, 80)
        maskContext.setFillColor(gray: 0, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 0, width: 100, height: 80))
        maskContext.setFillColor(gray: 1, alpha: 1)
        maskContext.fill(CGRect(x: 0, y: 40, width: 50, height: 40))
        let mask = CIImage(cgImage: maskContext.makeImage()!)
        let transparent = AuditBitmap(
            try BackgroundRemoval.composite(
                photo, mask: mask, background: "transparent", color: .white))
        #expect(transparent.rgb(25, 20).isClose(to: .red, tolerance: 4))
        #expect(transparent.alpha(25, 20) > 250)
        #expect(transparent.alpha(75, 60) < 5)
        let colored = AuditBitmap(
            try BackgroundRemoval.composite(
                photo, mask: mask, background: "color", color: StudioColor(hex: "#00FF00")!))
        #expect(colored.rgb(75, 60).isClose(to: AuditRGB(0, 255, 0), tolerance: 4))
        let bounds = try #require(
            BackgroundRemoval.subjectBounds(mask, size: photo))
        #expect(abs(bounds.x) < 0.03 && abs(bounds.y) < 0.03, "\(bounds)")
        #expect(abs(bounds.width - 0.54) < 0.03 && abs(bounds.height - 0.54) < 0.03, "\(bounds)")

        let space = try Workspace()
        let heic = space.url("cutout.heic")
        try StudioImageIO.write(
            try BackgroundRemoval.composite(
                photo, mask: mask, background: "transparent", color: .white),
            to: heic, format: .heic, options: .init(quality: 0.9))
        let reopened = try AuditBitmap(url: heic)
        #expect(reopened.alpha(75, 60) < 10)
        #expect(reopened.rgb(25, 20).isClose(to: .red, tolerance: 20))
    }
}
