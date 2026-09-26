import AppKit
import CoreGraphics
import Foundation

enum WebTools {
    static var all: [StudioTool] { [toPDF, toImage, htmlToPDF] }

    static let urlOption = StudioOption.text(
        "url", "Web address", placeholder: "https://example.com",
        help: "A web address, or the path of an HTML file on this Mac.", required: true)

    static let widthOption = StudioOption.choice(
        "width", "Viewport",
        [
            StudioChoice("1280", "Desktop"), StudioChoice("1024", "Laptop"),
            StudioChoice("768", "Tablet"), StudioChoice("390", "Phone"),
        ], default: "1280")

    static let pagesOption = StudioOption.choice(
        "pages", "Pages",
        [
            StudioChoice("a4", "A4 pages"), StudioChoice("letter", "Letter pages"),
            StudioChoice("single", "One long page"),
        ], default: "a4")

    static let toPDF = StudioTool(
        id: "web.to-pdf", title: "HTML to PDF",
        summary: "Save any web page as a PDF, split into printable pages or as one long page.",
        symbol: "globe", group: .convert, inputs: [], arity: .none, produces: .kind(.pdf),
        options: [urlOption, widthOption, pagesOption],
        keywords: ["web", "url", "website", "html", "page", "save"], actionTitle: "Convert to PDF",
        family: .document
    ) { run in
        let target = try WebCapture.target(from: run.settings.text("url"))
        run.status("Loading \(target.host ?? target.lastPathComponent)")
        return [
            try await capturePDF(
                target, width: width(run.settings), pages: run.settings.text("pages"), run: run)
        ]
    }

    static let toImage = StudioTool(
        id: "web.to-image", title: "HTML to image",
        summary: "Capture a web page as a PNG or JPG screenshot, including the full scroll height.",
        symbol: "camera.viewfinder", group: .convert, inputs: [], arity: .none,
        produces: .kind(.image),
        options: [
            urlOption, widthOption,
            .choice(
                "format", "Format", [StudioChoice("png", "PNG"), StudioChoice("jpg", "JPG")],
                default: "png"),
            .toggle("fullPage", "Capture the whole page", default: true),
        ],
        keywords: ["screenshot", "web", "url", "website", "capture"], actionTitle: "Capture",
        family: .image
    ) { run in
        let target = try WebCapture.target(from: run.settings.text("url"))
        run.status("Loading \(target.host ?? target.lastPathComponent)")
        let format: StudioImageFormat = run.settings.text("format") == "jpg" ? .jpeg : .png
        let (image, name, truncated) = try await captureImage(
            target, width: width(run.settings), fullPage: run.settings.bool("fullPage"))
        if truncated {
            run.note("The page is taller than \(image.height) pixels, so the capture stops there.")
        }
        let output = run.output(named: name + "." + format.fileExtension)
        try StudioImageIO.write(image, to: output, format: format, options: .init(quality: 0.9))
        return [output]
    }

    static let htmlToPDF = StudioTool(
        id: "web.html-to-pdf", title: "HTML file to PDF",
        summary: "Render saved HTML pages to PDF with the same engine as Safari.",
        symbol: "chevron.left.forwardslash.chevron.right", group: .convert, inputs: [],
        extraExtensions: ["html", "htm", "xhtml", "webarchive"], produces: .kind(.pdf),
        options: [widthOption, pagesOption],
        keywords: ["html", "web", "page", "convert"], actionTitle: "Convert to PDF",
        family: .document
    ) { run in
        [
            try await capturePDF(
                run.input, width: width(run.settings), pages: run.settings.text("pages"), run: run)
        ]
    }

    static func width(_ settings: StudioSettings) -> CGFloat {
        CGFloat(Double(settings.text("width")) ?? 1280)
    }

    static func paper(for pages: String) -> CGSize? {
        switch pages {
        case "single": nil
        case "letter": StudioPaperSize.letter.points
        default: StudioPaperSize.a4.points
        }
    }

    static func name(for target: URL, title: String?) -> String {
        if target.isFileURL { return target.studioStem }
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return StudioNaming.safeStem(title)
        }
        return StudioNaming.safeStem(target.host ?? "page")
    }

    static func capturePDF(_ target: URL, width: CGFloat, pages: String, run: StudioRun)
        async throws
        -> URL
    {
        let (output, count, truncated) = try await renderPDF(
            target, width: width, paper: paper(for: pages), margin: 28
        ) { name in
            run.output(named: name + ".pdf")
        } progress: {
            run.progress($0)
        }
        run.note("Saved \(count) page\(count == 1 ? "" : "s").")
        if truncated { run.note("The page is very long, so the PDF stops partway through.") }
        return output
    }

    @MainActor
    static func renderPDF(
        _ target: URL, width: CGFloat, paper: CGSize?, margin: CGFloat,
        output: (String) -> URL, progress: (Double) -> Void
    ) async throws -> (URL, Int, Bool) {
        let capture = WebCapture(width: width)
        defer { capture.close() }
        try await capture.load(target)
        let name = name(for: target, title: capture.title)
        let url = output(name)
        let (pages, truncated) = try await WebPDFLayout.render(
            capture, paper: paper, margin: margin, title: name,
            label: target.isFileURL ? target.lastPathComponent : (target.host ?? name), to: url,
            progress: progress)
        return (url, pages, truncated)
    }

    @MainActor
    static func captureImage(_ target: URL, width: CGFloat, fullPage: Bool) async throws -> (
        CGImage, String, Bool
    ) {
        let capture = WebCapture(width: width)
        defer { capture.close() }
        try await capture.load(target)
        let (image, truncated) = try await capture.snapshot(fullPage: fullPage)
        return (image, name(for: target, title: capture.title), truncated)
    }
}
