import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import EdithStudio

struct PreviewCase: Sendable, CustomStringConvertible {
    let tool: String
    let settings: [String: StudioValue]
    var tolerance = 6.0
    var label = ""

    var description: String { label.isEmpty ? tool : "\(tool) \(label)" }

    static let all: [PreviewCase] = [
        PreviewCase(tool: "image.resize", settings: ["width": .number(700)], label: "shrink"),
        PreviewCase(
            tool: "image.resize",
            settings: ["width": .number(900), "height": .number(300), "keepAspect": .bool(false)],
            label: "stretch"),
        PreviewCase(
            tool: "image.crop", settings: ["aspect": .text("4:5"), "position": .text("right")]),
        PreviewCase(
            tool: "image.crop",
            settings: [
                "mode": .text("area"),
                "area": .rect(StudioRect(x: 0.1, y: 0.3, width: 0.5, height: 0.6)),
            ], label: "area"),
        PreviewCase(tool: "image.convert", settings: ["format": .text("jpg")]),
        PreviewCase(
            tool: "image.rotate", settings: ["angle": .text("270"), "flip": .text("vertical")]),
        PreviewCase(
            tool: "image.rotate", settings: ["angle": .text("0"), "straighten": .number(7)],
            label: "straighten"),
        PreviewCase(
            tool: "image.watermark",
            settings: [
                "text": .text("DRAFT"), "position": .text("bottom-left"), "opacity": .number(0.8),
            ],
            tolerance: 8),
        PreviewCase(tool: "image.border", settings: ["style": .text("polaroid")]),
        PreviewCase(tool: "image.border", settings: ["style": .text("rounded")], label: "rounded"),
        PreviewCase(
            tool: "image.adjust",
            settings: [
                "filter": .text("vintage"), "contrast": .number(0.4), "vignette": .number(0.6),
            ],
            tolerance: 8),
        PreviewCase(tool: "image.upscale", settings: [:], tolerance: 8),
        PreviewCase(
            tool: "image.meme", settings: ["top": .text("preview"), "bottom": .text("matches")],
            tolerance: 10),
        PreviewCase(tool: "image.compress", settings: [:], tolerance: 8),
    ]
}

@Suite struct ImageAuditPreviewTests {
    @Test(arguments: PreviewCase.all)
    func previewMatchesTheRealRun(_ check: PreviewCase) async throws {
        let space = try Workspace()
        let phone = space.url("phone.jpg")
        try AuditImages.photo(
            at: phone, orientation: 6, camera: true,
            upright: AuditImages.quadrants(width: 1400, height: 1000))
        let cutout = space.url("cutout.png")
        try AuditImages.write(
            AuditImages.transparentCorner(width: 1000, height: 1400), to: cutout, type: .png)
        let tool = try #require(StudioCatalog.tool(check.tool))
        for input in [phone, cutout] {
            let before = try Data(contentsOf: input)
            let preview = try await StudioPreview.render(
                tool: tool, input: input, settings: StudioSettings(check.settings),
                environment: space.environment, maxPixelSize: 400)
            #expect(try Data(contentsOf: input) == before)
            let upright = try StudioImageIO.load(input, maxPixelSize: 400)
            #expect(
                AuditBitmap(preview.before).meanDifference(AuditBitmap(upright)) < 1,
                "\(check) before is not the upright input")
            let real = try await space.run(check.tool, [input], check.settings)
            let full = try StudioImageIO.load(try real.url())
            let name = "\(check) \(input.lastPathComponent)"
            let fullAspect = Double(full.width) / Double(full.height)
            let previewAspect = Double(preview.after.width) / Double(preview.after.height)
            #expect(
                abs(fullAspect - previewAspect) < 0.02,
                "\(name) aspect \(full.width)x\(full.height) vs \(preview.after.width)x\(preview.after.height)"
            )
            let scaled = try #require(
                StudioImageOps.resized(
                    full, width: preview.after.width, height: preview.after.height))
            let difference = AuditBitmap(scaled).meanDifference(AuditBitmap(preview.after))
            #expect(difference < check.tolerance, "\(name) differs by \(difference)")
        }
    }
}
