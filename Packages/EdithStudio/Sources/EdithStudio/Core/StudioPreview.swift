import CoreGraphics
import Foundation
import PDFKit

public struct StudioPreviewImage: @unchecked Sendable {
    public let before: CGImage
    public let after: CGImage
}

public enum StudioPreview {
    static let imageTools: Set<String> = [
        "image.resize", "image.crop", "image.convert", "image.rotate", "image.watermark",
        "image.remove-background", "image.blur-faces", "image.upscale", "image.meme",
        "image.border", "image.adjust", "image.compress", "pdf.scan",
    ]

    static let pdfTools: Set<String> = [
        "pdf.watermark", "pdf.page-numbers", "pdf.rotate", "pdf.crop", "pdf.grayscale", "pdf.n-up",
        "pdf.page-size", "pdf.compress", "pdf.redact",
    ]

    static let videoTools: Set<String> = [
        "video.crop", "video.rotate", "video.watermark", "video.adjust", "video.social",
    ]

    public static func supports(_ tool: StudioTool) -> Bool {
        imageTools.contains(tool.id) || pdfTools.contains(tool.id) || videoTools.contains(tool.id)
    }

    public static func render(
        tool: StudioTool, input: URL, settings: StudioSettings, environment: StudioEnvironment,
        maxPixelSize: Int = 900
    ) async throws -> StudioPreviewImage {
        guard supports(tool) else {
            throw StudioError.unavailable("\(tool.title) has no preview.")
        }
        let scratch = environment.temporaryRoot.appendingPathComponent(
            "preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        var previewEnvironment = environment
        previewEnvironment.temporaryRoot = scratch.appendingPathComponent(
            "staging", isDirectory: true)
        let output = scratch.appendingPathComponent("out", isDirectory: true)
        let prepared =
            input.studioKind == .video
            ? try await prepareVideo(
                input, settings: settings, scratch: scratch, environment: environment,
                maxPixelSize: maxPixelSize)
            : try prepare(
                input, tool: tool, settings: settings, scratch: scratch, maxPixelSize: maxPixelSize)
        var runSettings = prepared.settings
        if tool.id == "pdf.scan" { runSettings["ocr"] = .bool(false) }
        let result = try await StudioRunner.run(
            tool: tool, inputs: [prepared.url], settings: runSettings,
            destination: .folder(output), environment: previewEnvironment)
        guard let produced = result.outputs.first?.url else {
            throw StudioError.nothingToDo("The preview produced nothing.")
        }
        let after =
            produced.studioKind == .video
            ? try await frame(
                of: produced, scratch: scratch, environment: environment, name: "after",
                maxPixelSize: maxPixelSize)
            : try image(of: produced, maxPixelSize: maxPixelSize)
        return StudioPreviewImage(before: prepared.before, after: after)
    }

    struct Prepared {
        let url: URL
        let settings: StudioSettings
        let before: CGImage
    }

    static func prepare(
        _ input: URL, tool: StudioTool, settings: StudioSettings, scratch: URL, maxPixelSize: Int
    ) throws -> Prepared {
        if input.studioKind == .pdf {
            let document = try StudioPDF.open(input, password: settings.text("password"))
            var index = 0
            var adjusted = settings.merged(over: tool.defaultSettings)
            if tool.options.contains(where: { $0.key == "pages" }) {
                let pages = try StudioPageSelection.pages(
                    adjusted.text("pages"), pageCount: document.pageCount)
                index = pages.first ?? 0
                adjusted["pages"] = .text("all")
            }
            if tool.id == "pdf.n-up" {
                let count = Int(adjusted.text("layout")) ?? 4
                let pages = Array(index..<min(document.pageCount, index + count))
                let excerpt = StudioPDF.fresh(from: document, pages: pages)
                let url = scratch.appendingPathComponent(input.studioStem + ".pdf")
                try StudioPDF.write(excerpt, to: url)
                return Prepared(
                    url: url, settings: adjusted,
                    before: try image(of: url, maxPixelSize: maxPixelSize))
            }
            let excerpt = StudioPDF.fresh(from: document, pages: [index])
            let url = scratch.appendingPathComponent(input.studioStem + ".pdf")
            try StudioPDF.write(excerpt, to: url)
            adjusted["password"] = .text("")
            return Prepared(
                url: url, settings: adjusted, before: try image(of: url, maxPixelSize: maxPixelSize)
            )
        }
        let source = try StudioImageIO.load(input, maxPixelSize: maxPixelSize)
        let format =
            StudioImageFormat.of(input).flatMap {
                StudioImageFormat.writable.contains($0) && $0 != .pdf && $0 != .ico && $0 != .icns
                    ? $0 : nil
            } ?? .png
        let url = scratch.appendingPathComponent(input.studioStem + "." + format.fileExtension)
        try StudioImageIO.write(source, to: url, format: format, options: .init(quality: 0.95))
        return Prepared(url: url, settings: settings, before: source)
    }

    static func prepareVideo(
        _ input: URL, settings: StudioSettings, scratch: URL, environment: StudioEnvironment,
        maxPixelSize: Int
    ) async throws -> Prepared {
        let ffmpeg = try environment.require(.ffmpeg)
        let duration = await StudioMedia.probe(input, environment: environment)?.duration ?? 0
        let start = duration > 2 ? min(1, duration * 0.3) : 0
        let snippet = scratch.appendingPathComponent(input.studioStem + ".mp4")
        let bound = max(2, maxPixelSize)
        let scale =
            "scale=w='min(\(bound),iw)':h='min(\(bound),ih)':"
            + "force_original_aspect_ratio=decrease:force_divisible_by=2"
        let result = try await StudioProcess.run(
            ffmpeg,
            [
                "-hide_banner", "-nostdin", "-y", "-ss", String(format: "%.2f", start), "-i",
                input.path, "-t", "0.6", "-an", "-map", "0:v:0", "-vf", scale, "-c:v", "libx264",
                "-preset", "ultrafast", "-crf", "18", "-pix_fmt", "yuv420p", snippet.path,
            ], timeout: 60)
        guard result.status == 0, FileManager.default.fileExists(atPath: snippet.path) else {
            throw StudioError.failed(
                "A preview clip could not be made from \(input.lastPathComponent).")
        }
        let before = try await frame(
            of: snippet, scratch: scratch, environment: environment, name: "before",
            maxPixelSize: maxPixelSize)
        return Prepared(url: snippet, settings: settings, before: before)
    }

    static func frame(
        of video: URL, scratch: URL, environment: StudioEnvironment, name: String,
        maxPixelSize: Int
    ) async throws -> CGImage {
        let ffmpeg = try environment.require(.ffmpeg)
        let still = scratch.appendingPathComponent("\(name).png")
        for seek in [["-ss", "0.2"], []] {
            let result = try await StudioProcess.run(
                ffmpeg,
                ["-hide_banner", "-nostdin", "-y"] + seek + [
                    "-i", video.path, "-map", "0:v:0", "-frames:v", "1", "-update", "1",
                    still.path,
                ],
                timeout: 60)
            if result.status == 0, FileManager.default.fileExists(atPath: still.path) {
                return try StudioImageIO.load(still, maxPixelSize: maxPixelSize)
            }
        }
        throw StudioError.failed("The preview frame could not be read.")
    }

    static func image(of url: URL, maxPixelSize: Int) throws -> CGImage {
        if url.studioKind == .pdf {
            guard let page = PDFDocument(url: url)?.page(at: 0) else {
                throw StudioError.unreadable(url.lastPathComponent)
            }
            let size = StudioPDF.displaySize(page)
            let dpi = 72 * Double(maxPixelSize) / max(size.width, size.height, 1)
            return try StudioPDF.render(page, dpi: dpi)
        }
        return try StudioImageIO.load(url, maxPixelSize: maxPixelSize)
    }
}
