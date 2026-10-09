import CoreGraphics
import Foundation
import Testing

@testable import EdithStudio

@Suite(.enabled(if: MediaFixtures.available)) struct MediaAuditPreviewTests {
    func preview(
        _ id: String, _ input: URL, _ values: [String: StudioValue] = [:], size: Int,
        space: Workspace
    ) async throws -> StudioPreviewImage {
        let tool = try #require(StudioCatalog.tool(id))
        let before = MediaAudit.digest(input)
        let image = try await StudioPreview.render(
            tool: tool, input: input, settings: StudioSettings(values),
            environment: space.environment, maxPixelSize: size)
        #expect(MediaAudit.digest(input) == before)
        return image
    }

    @Test func portraitPhonePreviewStaysUprightAndWithinTheLimit() async throws {
        let space = try Workspace()
        let phone = space.url("phone.mp4")
        try await MediaAudit.marker(at: phone, width: 240, height: 320, seconds: 2, rotation: 90)
        let image = try await preview("video.adjust", phone, size: 200, space: space)
        #expect(image.before.width == 150 && image.before.height == 200)
        #expect(image.after.width == 150 && image.after.height == 200)
        #expect(Bitmap(image.before).redCorner == .topLeft)
        #expect(Bitmap(image.after).redCorner == .topLeft)
        let turned = try await preview("video.rotate", phone, size: 200, space: space)
        #expect(turned.after.width == 200 && turned.after.height == 150)
        #expect(Bitmap(turned.after).redCorner == .topRight)
    }

    @Test func previewOfAVeryShortClipWorks() async throws {
        let space = try Workspace()
        let clip = space.url("blink.mp4")
        try await MediaAudit.marker(at: clip, width: 320, height: 240, seconds: 0.2)
        let image = try await preview("video.crop", clip, size: 400, space: space)
        #expect(image.before.width == 320 && image.before.height == 240)
        #expect(image.after.width == 240 && image.after.height == 240)
    }

    @Test func socialPreviewIsBoundedLikeTheBeforeImage() async throws {
        let space = try Workspace()
        let clip = space.url("wide.mp4")
        try await MediaAudit.marker(at: clip, width: 320, height: 180, seconds: 1)
        let image = try await preview(
            "video.social", clip, ["quality": .text("720")], size: 300, space: space)
        #expect(image.before.width == 300)
        #expect(image.after.height == 300)
        #expect(abs(Double(image.after.width) - 300 * 9 / 16) <= 2)
    }

    @Test func watermarkPreviewMatchesTheFullRender() async throws {
        let space = try Workspace()
        let clip = space.url("wide.mp4")
        try await MediaAudit.plain(at: clip, width: 640, height: 360, seconds: 2)
        let logo = space.url("logo.png")
        try MediaAudit.solidPNG(at: logo, width: 40, height: 40, red: 1, green: 0, blue: 0)
        let values: [String: StudioValue] = [
            "kind": .text("image"), "image": .text(logo.path), "position": .text("top-left"),
            "size": .number(0.25), "opacity": .number(1),
        ]
        let image = try await preview("video.watermark", clip, values, size: 320, space: space)
        let box = try #require(Bitmap(image.after).bounds(where: MediaAudit.isRed))
        #expect(abs(box.width - 80) <= 3 && box.minX < 12 && box.minY < 12)
    }
}
