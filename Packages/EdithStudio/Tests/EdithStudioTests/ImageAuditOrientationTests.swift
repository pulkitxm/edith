import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

struct UprightCase: Sendable, CustomStringConvertible {
    let tool: String
    let settings: [String: StudioValue]
    let size: (Int, Int)
    let layout: [AuditRGB]
    var area: CGRect? = nil
    var rows: (Double, Double) = (0.25, 0.75)
    var label = ""

    var description: String { label.isEmpty ? tool : "\(tool) \(label)" }

    static let all: [UprightCase] = [
        UprightCase(
            tool: "image.compress", settings: [:], size: (120, 80), layout: AuditLayout.upright),
        UprightCase(
            tool: "image.compress",
            settings: ["level": .text("less"), "stripMetadata": .bool(false)], size: (120, 80),
            layout: AuditLayout.upright, label: "keeping metadata"),
        UprightCase(
            tool: "image.compress", settings: ["maxSize": .number(60)], size: (60, 40),
            layout: AuditLayout.upright, label: "max size"),
        UprightCase(
            tool: "image.resize", settings: ["width": .number(60)], size: (60, 40),
            layout: AuditLayout.upright),
        UprightCase(
            tool: "image.crop",
            settings: [
                "mode": .text("area"),
                "area": .rect(StudioRect(x: 0.25, y: 0, width: 0.5, height: 0.5)),
            ], size: (60, 40), layout: [.red, .green, .red, .green], label: "area"),
        UprightCase(
            tool: "image.crop", settings: ["aspect": .text("1:1")], size: (80, 80),
            layout: AuditLayout.upright, label: "square"),
        UprightCase(
            tool: "image.convert", settings: ["format": .text("png")], size: (120, 80),
            layout: AuditLayout.upright, label: "png"),
        UprightCase(
            tool: "image.convert", settings: ["format": .text("jpg")], size: (120, 80),
            layout: AuditLayout.upright, label: "jpg"),
        UprightCase(
            tool: "image.convert", settings: ["format": .text("heic")], size: (120, 80),
            layout: AuditLayout.upright, label: "heic"),
        UprightCase(
            tool: "image.convert", settings: ["format": .text("tiff")], size: (120, 80),
            layout: AuditLayout.upright, label: "tiff"),
        UprightCase(
            tool: "image.rotate", settings: ["angle": .text("90")], size: (80, 120),
            layout: AuditLayout.clockwise, label: "right"),
        UprightCase(
            tool: "image.rotate", settings: ["angle": .text("270")], size: (80, 120),
            layout: AuditLayout.counterClockwise, label: "left"),
        UprightCase(
            tool: "image.rotate", settings: ["angle": .text("180")], size: (120, 80),
            layout: AuditLayout.halfTurn, label: "half"),
        UprightCase(
            tool: "image.rotate", settings: ["angle": .text("0"), "flip": .text("horizontal")],
            size: (120, 80), layout: AuditLayout.mirrored, label: "mirror"),
        UprightCase(
            tool: "image.rotate", settings: ["angle": .text("0"), "flip": .text("vertical")],
            size: (120, 80), layout: AuditLayout.upsideDown, label: "flip"),
        UprightCase(
            tool: "image.watermark",
            settings: [
                "text": .text("©"), "size": .number(0.1), "position": .text("bottom-right"),
                "opacity": .number(1), "rotation": .number(0),
            ], size: (120, 80), layout: AuditLayout.upright),
        UprightCase(
            tool: "image.adjust", settings: ["brightness": .number(0.02)], size: (120, 80),
            layout: AuditLayout.upright),
        UprightCase(
            tool: "image.border", settings: ["width": .number(0.1), "color": .text("#000000")],
            size: (136, 96), layout: AuditLayout.upright,
            area: CGRect(x: 8, y: 8, width: 120, height: 80)),
        UprightCase(
            tool: "image.upscale", settings: [:], size: (240, 160), layout: AuditLayout.upright),
        UprightCase(
            tool: "image.meme", settings: ["bottom": .text("hi")], size: (120, 80),
            layout: AuditLayout.upright, rows: (0.25, 0.6)),
        UprightCase(
            tool: "image.metadata", settings: [:], size: (120, 80), layout: AuditLayout.upright),
        UprightCase(
            tool: "image.metadata", settings: ["mode": .text("location")], size: (120, 80),
            layout: AuditLayout.upright, label: "location"),
    ]
}

@Suite struct ImageAuditOrientationTests {
    static func orientedInputs(_ space: Workspace, camera: Bool = false) throws -> [URL] {
        var urls: [URL] = []
        for orientation in 1...8 {
            let url = space.url("o\(orientation).jpg")
            try AuditImages.photo(at: url, orientation: orientation, camera: camera)
            urls.append(url)
        }
        for orientation in [6, 8] {
            let url = space.url("h\(orientation).heic")
            try AuditImages.photo(at: url, orientation: orientation, type: .heic, camera: camera)
            urls.append(url)
        }
        return urls
    }

    @Test func fixturesDisplayUprightThroughImageIO() throws {
        let space = try Workspace()
        for url in try Self.orientedInputs(space) {
            let info = try #require(StudioImageIO.info(url))
            #expect(info.width == 120 && info.height == 80, "\(url.lastPathComponent)")
            let bitmap = try AuditBitmap(url: url)
            #expect(
                bitmap.matches(AuditLayout.upright),
                "\(url.lastPathComponent) \(bitmap.quadrants())")
        }
        #expect(AuditFiles.orientation(space.url("o6.jpg")) == 6)
        #expect(AuditFiles.orientation(space.url("h8.heic")) == 8)
    }

    @Test(arguments: UprightCase.all)
    func everyOrientationComesOutUpright(_ check: UprightCase) async throws {
        let space = try Workspace()
        let inputs = try Self.orientedInputs(space, camera: true)
        let before = try AuditFiles.snapshot(inputs)
        let result = try await space.run(check.tool, inputs, check.settings)
        #expect(result.failures.isEmpty, "\(result.failures)")
        for input in inputs {
            let output = try result.output(from: input)
            let name = "\(check) \(input.lastPathComponent)"
            let info = try #require(StudioImageIO.info(output), "\(name)")
            #expect(info.width == check.size.0 && info.height == check.size.1, "\(name) \(info)")
            let bitmap = try AuditBitmap(url: output)
            let area = check.area ?? CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height)
            let found = bitmap.quadrants(inset: area, rows: check.rows)
            let matches = zip(found, check.layout).allSatisfy { $0.isClose(to: $1, tolerance: 45) }
            #expect(matches, "\(name) found \(found) expected \(check.layout)")
        }
        #expect(try AuditFiles.snapshot(inputs) == before)
    }

    @Test func iconsCollagesAndGIFsAreUpright() async throws {
        let space = try Workspace()
        let inputs = try Self.orientedInputs(space)
        let icons = try await space.run("image.icon", inputs)
        for input in inputs {
            let icon = AuditBitmap(try AuditFiles.largestFrame(try icons.output(from: input)))
            let area = CGRect(
                x: 0, y: Double(icon.height) / 6, width: Double(icon.width),
                height: Double(icon.height) * 2 / 3)
            #expect(
                zip(icon.quadrants(inset: area), AuditLayout.upright).allSatisfy {
                    $0.isClose(to: $1)
                }, "icon \(input.lastPathComponent) \(icon.quadrants(inset: area))")
        }

        let pair = [space.url("o6.jpg"), space.url("h8.heic")]
        let column = try AuditBitmap(
            url: try await space.run(
                "image.collage", pair,
                [
                    "layout": .text("vertical"), "width": .number(240), "spacing": .number(0),
                    "format": .text("png"),
                ]
            ).url())
        #expect(column.width == 240 && column.height == 320)
        for cell in 0..<2 {
            let area = CGRect(x: 0, y: cell * 160, width: 240, height: 160)
            #expect(
                zip(column.quadrants(inset: area), AuditLayout.upright).allSatisfy {
                    $0.isClose(to: $1)
                }, "collage cell \(cell) \(column.quadrants(inset: area))")
        }

        let gif = try await space.run("image.make-gif", pair, ["width": .number(120)])
        let frames = try StudioImageIO.frames(try gif.url())
        #expect(frames.count == 2)
        for frame in frames {
            let bitmap = AuditBitmap(frame.image)
            #expect(bitmap.width == 120 && bitmap.height == 80)
            #expect(bitmap.matches(AuditLayout.upright), "gif frame \(bitmap.quadrants())")
        }
    }

    @Test func editorRendersOrientedSourcesUpright() throws {
        let space = try Workspace()
        for input in try Self.orientedInputs(space) {
            let document = ImageEditDocument(source: input)
            let output = AuditBitmap(try ImageEditRenderer.render(document: document))
            #expect(output.width == 120 && output.height == 80, "\(input.lastPathComponent)")
            #expect(output.matches(AuditLayout.upright), "\(input.lastPathComponent)")
            let exported = space.url("export-\(input.studioStem).png")
            try ImageEditRenderer.export(document: document, to: exported)
            #expect(AuditFiles.orientation(exported) == 1)
            #expect(try AuditBitmap(url: exported).matches(AuditLayout.upright))
        }
    }

    @Test func textIsReadFromPhonePhotosTakenSideways() async throws {
        let space = try Workspace()
        var inputs: [URL] = []
        for orientation in [6, 8, 3] {
            let url = space.url("sign\(orientation).jpg")
            try AuditImages.photo(
                at: url, orientation: orientation,
                upright: AuditImages.textPhoto("Harbor Street"))
            inputs.append(url)
        }
        let result = try await space.run("image.to-text", inputs)
        #expect(result.failures.isEmpty, "\(result.failures)")
        for input in inputs {
            let text = try String(contentsOf: try result.output(from: input), encoding: .utf8)
            #expect(text.contains("Harbor"), "\(input.lastPathComponent): \(text)")
        }
    }
}
