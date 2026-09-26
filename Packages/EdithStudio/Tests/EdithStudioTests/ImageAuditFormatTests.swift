import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

struct FormatVariant: Sendable, CustomStringConvertible {
    let name: String
    let colors: [AuditRGB]
    let transparentCorner: Bool
    let tolerance: Int

    var description: String { name }

    static let all: [FormatVariant] = [
        FormatVariant(
            name: "cmyk.jpg", colors: AuditLayout.upright, transparentCorner: false,
            tolerance: 45),
        FormatVariant(
            name: "p3.png", colors: AuditLayout.upright, transparentCorner: false, tolerance: 10),
        FormatVariant(
            name: "p3.jpg", colors: AuditLayout.upright, transparentCorner: false, tolerance: 14),
        FormatVariant(
            name: "gray.png", colors: AuditImages.grayLevels.map { AuditRGB($0, $0, $0) },
            transparentCorner: false, tolerance: 12),
        FormatVariant(
            name: "gray.jpg", colors: AuditImages.grayLevels.map { AuditRGB($0, $0, $0) },
            transparentCorner: false, tolerance: 14),
        FormatVariant(
            name: "deep.png", colors: AuditLayout.upright, transparentCorner: true, tolerance: 10),
        FormatVariant(
            name: "palette.png", colors: AuditLayout.upright, transparentCorner: true,
            tolerance: 10),
        FormatVariant(
            name: "alpha.png", colors: AuditLayout.upright, transparentCorner: true, tolerance: 10),
        FormatVariant(
            name: "photo.tiff", colors: AuditLayout.upright, transparentCorner: false,
            tolerance: 10),
        FormatVariant(
            name: "alpha.heic", colors: AuditLayout.upright, transparentCorner: true,
            tolerance: 16),
    ]

    func make(in space: Workspace) throws -> URL {
        let url = space.url(name)
        switch name {
        case "cmyk.jpg": try AuditImages.cmykJPEG(at: url)
        case "p3.png": try AuditImages.displayP3(at: url, type: .png)
        case "p3.jpg": try AuditImages.displayP3(at: url, type: .jpeg)
        case "gray.png": try AuditImages.grayscale(at: url, type: .png)
        case "gray.jpg": try AuditImages.grayscale(at: url, type: .jpeg)
        case "deep.png": try AuditImages.sixteenBitPNG(at: url)
        case "palette.png": try AuditImages.palettePNG(at: url)
        case "alpha.png":
            try AuditImages.write(AuditImages.transparentCorner(), to: url, type: .png)
        case "photo.tiff": try AuditImages.write(AuditImages.quadrants(), to: url, type: .tiff)
        default:
            try AuditImages.write(AuditImages.transparentCorner(), to: url, type: .heic)
        }
        return url
    }
}

struct VariantTool: Sendable, CustomStringConvertible {
    let tool: String
    let settings: [String: StudioValue]
    let order: [Int]
    let flattensTo: AuditRGB?
    var label = ""

    var description: String { label.isEmpty ? tool : "\(tool) \(label)" }

    static let all: [VariantTool] = [
        VariantTool(tool: "image.compress", settings: [:], order: [0, 1, 2, 3], flattensTo: nil),
        VariantTool(
            tool: "image.resize", settings: ["width": .number(60)], order: [0, 1, 2, 3],
            flattensTo: nil),
        VariantTool(
            tool: "image.crop", settings: ["aspect": .text("1:1")], order: [0, 1, 2, 3],
            flattensTo: nil),
        VariantTool(
            tool: "image.convert", settings: ["format": .text("png")], order: [0, 1, 2, 3],
            flattensTo: nil, label: "png"),
        VariantTool(
            tool: "image.convert", settings: ["format": .text("jpg")], order: [0, 1, 2, 3],
            flattensTo: .white, label: "jpg"),
        VariantTool(
            tool: "image.convert",
            settings: ["format": .text("bmp"), "background": .text("#000000")],
            order: [0, 1, 2, 3], flattensTo: .black, label: "bmp"),
        VariantTool(
            tool: "image.convert", settings: ["format": .text("heic")], order: [0, 1, 2, 3],
            flattensTo: nil, label: "heic"),
        VariantTool(
            tool: "image.convert", settings: ["format": .text("tiff")], order: [0, 1, 2, 3],
            flattensTo: nil, label: "tiff"),
        VariantTool(
            tool: "image.rotate", settings: ["angle": .text("180")], order: [3, 2, 1, 0],
            flattensTo: nil),
        VariantTool(
            tool: "image.watermark",
            settings: [
                "text": .text("©"), "size": .number(0.08), "position": .text("top"),
                "opacity": .number(1), "rotation": .number(0),
            ], order: [0, 1, 2, 3], flattensTo: nil),
        VariantTool(
            tool: "image.adjust", settings: ["contrast": .number(0.01)], order: [0, 1, 2, 3],
            flattensTo: nil),
        VariantTool(tool: "image.upscale", settings: [:], order: [0, 1, 2, 3], flattensTo: nil),
        VariantTool(
            tool: "image.metadata", settings: [:], order: [0, 1, 2, 3], flattensTo: nil),
    ]
}

@Suite struct ImageAuditFormatTests {
    @Test func variantFixturesLoadWithTheirTrueColors() throws {
        let space = try Workspace()
        for variant in FormatVariant.all {
            let url = try variant.make(in: space)
            let bitmap = try AuditBitmap(url: url)
            let found = bitmap.quadrants()
            if variant.name.hasPrefix("gray") {
                #expect(found.allSatisfy { $0.r == $0.g && $0.g == $0.b }, "\(variant) \(found)")
                #expect(found.map(\.r) == found.map(\.r).sorted(), "\(variant) \(found)")
                #expect(found[3].r - found[0].r > 150, "\(variant) \(found)")
                continue
            }
            for index in 0..<3 where !(variant.name == "cmyk.jpg" && index == 2) {
                #expect(
                    found[index].isClose(to: variant.colors[index], tolerance: variant.tolerance),
                    "\(variant) \(index) \(found)")
            }
            if variant.transparentCorner {
                #expect(bitmap.alpha(bitmap.width * 3 / 4, bitmap.height * 3 / 4) < 10)
            }
        }
        #expect(
            AuditFiles.properties(space.url("cmyk.jpg"))[kCGImagePropertyColorModel] as? String
                == "CMYK")
        #expect(AuditFiles.properties(space.url("deep.png"))[kCGImagePropertyDepth] as? Int == 16)
        let palette = try Data(contentsOf: space.url("palette.png"))
        #expect(palette.count > 26 && palette[25] == 3)
        #expect(
            AuditFiles.properties(space.url("p3.png"))[kCGImagePropertyProfileName] as? String
                == "Display P3")
    }

    @Test(arguments: VariantTool.all)
    func colorSpacesDepthsAndAlphaSurviveEveryTool(_ check: VariantTool) async throws {
        let space = try Workspace()
        let inputs = try FormatVariant.all.map { try $0.make(in: space) }
        let references = try inputs.map { try AuditBitmap(url: $0).quadrants() }
        let before = try AuditFiles.snapshot(inputs)
        let result = try await space.run(check.tool, inputs, check.settings)
        #expect(result.failures.isEmpty, "\(result.failures)")
        for (offset, (variant, input)) in zip(FormatVariant.all, inputs).enumerated() {
            let reference = references[offset]
            let output = try result.output(from: input)
            let bitmap = try AuditBitmap(url: output)
            let found = bitmap.quadrants()
            let name = "\(check) \(variant) -> \(output.lastPathComponent)"
            for position in 0..<4 {
                let sourceIndex = check.order[position]
                let transparentSource = variant.transparentCorner && sourceIndex == 3
                let point = (
                    x: bitmap.width * (position % 2 == 0 ? 1 : 3) / 4,
                    y: bitmap.height * (position < 2 ? 1 : 3) / 4
                )
                if transparentSource {
                    if let flattened = check.flattensTo {
                        #expect(bitmap.alpha(point.x, point.y) > 250, "\(name) alpha")
                        #expect(
                            found[position].isClose(to: flattened, tolerance: 12),
                            "\(name) flattened \(found[position])")
                    } else {
                        #expect(
                            bitmap.alpha(point.x, point.y) < 12,
                            "\(name) lost transparency at \(position)")
                    }
                } else {
                    #expect(bitmap.alpha(point.x, point.y) > 245, "\(name) alpha \(position)")
                    #expect(
                        found[position].isClose(to: reference[sourceIndex], tolerance: 12),
                        "\(name) quadrant \(position) found \(found[position]) expected \(reference[sourceIndex])"
                    )
                }
            }
        }
        #expect(try AuditFiles.snapshot(inputs) == before)
    }

    static let grid: [[AuditRGB]] = [
        [.red, .green, .blue],
        [.yellow, .white, AuditRGB(20, 20, 20)],
    ]

    func expectGrid(_ image: CGImage, _ expected: [[AuditRGB]], _ label: String) {
        let bitmap = AuditBitmap(image)
        #expect(
            bitmap.width == expected[0].count && bitmap.height == expected.count,
            "\(label) size \(bitmap.width)x\(bitmap.height)")
        guard bitmap.width == expected[0].count, bitmap.height == expected.count else { return }
        for y in 0..<bitmap.height {
            for x in 0..<bitmap.width {
                #expect(
                    bitmap.rgb(x, y).isClose(to: expected[y][x], tolerance: 3),
                    "\(label) pixel \(x),\(y) \(bitmap.rgb(x, y)) expected \(expected[y][x])")
            }
        }
    }

    @Test func tinyImagesRotateFlipAndCropPixelExactly() async throws {
        let space = try Workspace()
        let source = space.url("grid.png")
        try AuditImages.write(AuditImages.pixelGrid(Self.grid), to: source, type: .png)
        let g = Self.grid
        let clockwise = [[g[1][0], g[0][0]], [g[1][1], g[0][1]], [g[1][2], g[0][2]]]
        let counter = [[g[0][2], g[1][2]], [g[0][1], g[1][1]], [g[0][0], g[1][0]]]
        let mirrored = g.map { Array($0.reversed()) }
        let upsideDown = Array(g.reversed())
        func run(_ id: String, _ values: [String: StudioValue]) async throws -> CGImage {
            try StudioImageIO.load(try await space.run(id, [source], values).url())
        }
        expectGrid(try await run("image.rotate", ["angle": .text("90")]), clockwise, "right")
        expectGrid(try await run("image.rotate", ["angle": .text("270")]), counter, "left")
        expectGrid(
            try await run("image.rotate", ["angle": .text("180")]),
            upsideDown.map { Array($0.reversed()) }, "half")
        expectGrid(
            try await run("image.rotate", ["angle": .text("0"), "flip": .text("horizontal")]),
            mirrored, "mirror")
        expectGrid(
            try await run("image.rotate", ["angle": .text("0"), "flip": .text("vertical")]),
            upsideDown, "flip")
        expectGrid(
            try await run(
                "image.crop",
                [
                    "mode": .text("area"),
                    "area": .rect(StudioRect(x: 1.0 / 3, y: 0.5, width: 2.0 / 3, height: 0.5)),
                ]), [[g[1][1], g[1][2]]], "crop")
        expectGrid(
            try await run("image.crop", ["aspect": .text("1:1"), "position": .text("right")]),
            [[g[0][1], g[0][2]], [g[1][1], g[1][2]]], "square right")
        expectGrid(try await run("image.convert", ["format": .text("tiff")]), g, "tiff")
        expectGrid(try await run("image.convert", ["format": .text("bmp")]), g, "bmp")
        expectGrid(try await run("image.compress", [:]), g, "compress")
        expectGrid(try await run("image.metadata", [:]), g, "metadata")
    }

    @Test func singlePixelImagesWorkInEveryTool() async throws {
        let space = try Workspace()
        let dot = space.url("dot.png")
        try AuditImages.write(AuditImages.pixelGrid([[.red]]), to: dot, type: .png)
        let jpeg = space.url("dot.jpg")
        try AuditImages.write(AuditImages.pixelGrid([[.blue]]), to: jpeg, type: .jpeg)
        let sizes: [(String, [String: StudioValue], (Int, Int))] = [
            ("image.compress", [:], (1, 1)),
            ("image.resize", ["mode": .text("percent"), "percent": .number(50)], (1, 1)),
            (
                "image.resize",
                ["mode": .text("percent"), "percent": .number(300), "noEnlarge": .bool(false)],
                (3, 3)
            ),
            ("image.crop", ["aspect": .text("16:9")], (1, 1)),
            ("image.crop", ["mode": .text("trim")], (1, 1)),
            ("image.convert", ["format": .text("heic")], (1, 1)),
            ("image.convert", ["format": .text("gif")], (1, 1)),
            ("image.rotate", [:], (1, 1)),
            ("image.rotate", ["angle": .text("0"), "straighten": .number(10)], (1, 1)),
            ("image.watermark", [:], (1, 1)),
            ("image.adjust", ["filter": .text("sepia")], (1, 1)),
            ("image.upscale", ["scale": .text("4")], (4, 4)),
            ("image.border", ["width": .number(0)], (1, 1)),
            ("image.meme", ["top": .text("a")], (1, 1)),
            ("image.blur-faces", [:], (1, 1)),
            ("image.metadata", [:], (1, 1)),
        ]
        for (id, values, size) in sizes {
            for input in [dot, jpeg] {
                let result = try await space.run(id, [input], values)
                let info = try #require(StudioImageIO.info(try result.url()), "\(id)")
                #expect(info.width == size.0 && info.height == size.1, "\(id) \(values) \(info)")
            }
        }
        let icon = try await space.run("image.icon", [dot])
        #expect(AuditFiles.frameSizes(try icon.url()).contains(1024))
        await #expect(throws: StudioError.self) { try await space.run("image.to-text", [dot]) }
    }

    @Test func vectorInputsRasterizeUpright() async throws {
        let space = try Workspace()
        let svg = space.url("badge.svg")
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="120" height="80" viewBox="0 0 120 80">
        <rect x="0" y="0" width="60" height="40" fill="rgb(214,48,49)"/>
        <rect x="60" y="0" width="60" height="40" fill="rgb(46,160,67)"/>
        <rect x="0" y="40" width="60" height="40" fill="rgb(40,80,200)"/>
        <rect x="60" y="40" width="60" height="40" fill="rgb(236,200,40)"/>
        </svg>
        """.write(to: svg, atomically: true, encoding: .utf8)
        let info = try #require(StudioImageIO.info(svg))
        #expect(info.width == 120 && info.height == 80)
        for (id, values) in [
            ("image.convert", ["format": StudioValue.text("png")]),
            ("image.resize", ["width": .number(60)]), ("image.rotate", ["angle": .text("180")]),
        ] {
            let output = try await space.run(id, [svg], values).url()
            let bitmap = try AuditBitmap(url: output)
            let expected = id == "image.rotate" ? AuditLayout.halfTurn : AuditLayout.upright
            let matches = bitmap.matches(expected, tolerance: 12)
            #expect(matches, "\(id) \(bitmap.quadrants())")
            #expect(abs(Double(bitmap.width) / Double(bitmap.height) - 1.5) < 0.01, "\(id)")
        }
        let empty = space.url("empty.svg")
        try Data().write(to: empty)
        let binary = space.url("binary.svg")
        try Data([0xFF, 0xFE, 0x00, 0xD8, 0x00, 0x01, 0x02]).write(to: binary)
        for input in [empty, binary] {
            for id in ["image.compress", "image.resize", "image.convert"] {
                do {
                    _ = try await space.run(id, [input])
                    Issue.record("\(id) accepted \(input.lastPathComponent)")
                } catch let error as StudioError {
                    #expect(
                        error.errorDescription?.contains(input.lastPathComponent) == true,
                        "\(id) \(error)")
                } catch {
                    Issue.record("\(id) \(input.lastPathComponent) threw \(error)")
                }
            }
        }
    }

    @Test func oddAndExtremeDimensionsKeepExactSizes() async throws {
        let space = try Workspace()
        let odd = space.url("odd.png")
        try AuditImages.write(AuditImages.quadrants(width: 101, height: 57), to: odd, type: .png)
        let wide = space.url("wide.jpg")
        try AuditImages.write(
            AuditImages.quadrants(width: 8000, height: 200), to: wide, type: .jpeg)
        func size(_ id: String, _ input: URL, _ values: [String: StudioValue]) async throws
            -> (Int, Int)
        {
            let info = try #require(
                StudioImageIO.info(try await space.run(id, [input], values).url()))
            return (info.width, info.height)
        }
        #expect(try await size("image.rotate", odd, [:]) == (57, 101))
        #expect(try await size("image.upscale", odd, ["scale": .text("3")]) == (303, 171))
        #expect(
            try await size("image.resize", odd, ["mode": .text("percent"), "percent": .number(50)])
                == (51, 29))
        #expect(try await size("image.crop", odd, ["aspect": .text("1:1")]) == (57, 57))
        #expect(try await size("image.crop", odd, ["aspect": .text("16:9")]) == (101, 57))
        #expect(try await size("image.crop", odd, ["aspect": .text("9:16")]) == (32, 57))
        #expect(
            try await size("image.border", odd, ["width": .number(0.1)]) == (113, 69))
        #expect(
            try await size(
                "image.resize", wide, ["mode": .text("longest"), "longest": .number(800)])
                == (800, 20))
        #expect(try await size("image.crop", wide, ["aspect": .text("1:1")]) == (200, 200))
        #expect(try await size("image.rotate", wide, [:]) == (200, 8000))
        #expect(try await size("image.compress", wide, [:]) == (8000, 200))
        let wideRotated = try AuditBitmap(
            url: try await space.run("image.rotate", [wide], [:]).url())
        #expect(wideRotated.rgb(150, 100).isClose(to: .red))
        #expect(wideRotated.rgb(50, 7900).isClose(to: .yellow))
    }
}
