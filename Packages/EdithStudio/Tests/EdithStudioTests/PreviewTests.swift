import Foundation
import PDFKit
import Testing

@testable import EdithStudio

@Suite struct PreviewTests {
    @Test func imagePreviewShowsTheToolApplied() async throws {
        let space = try Workspace()
        let source = space.url("photo.jpg")
        try Fixtures.image(at: source, width: 2400, height: 1600, format: .jpeg)
        let tool = try #require(StudioCatalog.tool("image.border"))
        let preview = try await StudioPreview.render(
            tool: tool, input: source, settings: StudioSettings(), environment: space.environment,
            maxPixelSize: 600)
        #expect(max(preview.before.width, preview.before.height) == 600)
        #expect(
            preview.after.width != preview.before.width
                || preview.after.height != preview.before.height)
        #expect(StudioRunner.fileSize(source) > 0)
    }

    @Test func pdfPreviewRendersTheFirstSelectedPage() async throws {
        let space = try Workspace()
        let source = space.url("doc.pdf")
        try Fixtures.pdf(at: source, pages: ["First", "Second", "Third"])
        let tool = try #require(StudioCatalog.tool("pdf.watermark"))
        let preview = try await StudioPreview.render(
            tool: tool, input: source,
            settings: StudioSettings(["pages": .text("2-3"), "opacity": .number(1)]),
            environment: space.environment, maxPixelSize: 400)
        #expect(max(preview.after.width, preview.after.height) == 400)
        var red = 0
        for x in stride(from: 0, to: preview.after.width, by: 5) {
            for y in stride(from: 0, to: preview.after.height, by: 5) {
                let pixel = Fixtures.pixel(preview.after, x: x, y: y)
                if pixel.r > 150 && pixel.g < 90 { red += 1 }
            }
        }
        #expect(red > 5)
        #expect(!StudioPreview.supports(try #require(StudioCatalog.tool("pdf.merge"))))
    }

    @Test func previewRejectsUnsupportedTools() async throws {
        let space = try Workspace()
        let source = space.url("a.pdf")
        try Fixtures.pdf(at: source, pages: ["A"])
        await #expect(throws: StudioError.self) {
            try await StudioPreview.render(
                tool: try #require(StudioCatalog.tool("pdf.to-text")), input: source,
                settings: StudioSettings(), environment: space.environment)
        }
    }
}

@Suite struct VideoPreviewTests {
    @Test func videoPreviewRunsTheToolOnAShortClip() async throws {
        let space = try Workspace()
        guard let ffmpeg = space.environment.ffmpeg else { return }
        let clip = space.url("clip.mp4")
        let made = try await StudioProcess.run(
            ffmpeg,
            [
                "-hide_banner", "-nostdin", "-y", "-f", "lavfi", "-i",
                "testsrc2=size=320x240:rate=25:duration=3", "-pix_fmt", "yuv420p", clip.path,
            ], timeout: 60)
        #expect(made.status == 0)
        let tool = try #require(StudioCatalog.tool("video.rotate"))
        let preview = try await StudioPreview.render(
            tool: tool, input: clip, settings: StudioSettings(), environment: space.environment)
        #expect(preview.before.width == 320 && preview.before.height == 240)
        #expect(preview.after.width == 240 && preview.after.height == 320)
    }
}
