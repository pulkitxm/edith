import AppKit
import CoreGraphics
import Foundation
import PDFKit
import Quartz

enum PDFOptimizeTools {
    static var all: [StudioTool] {
        [compress, grayscale, ocr, repair, flatten, decompress, linearize].map {
            $0.checkingChoices()
        }
    }

    static let compress = StudioTool(
        id: "pdf.compress", title: "Compress PDF",
        summary: "Reduce file size while keeping the PDF sharp enough to read and print.",
        symbol: "arrow.down.right.and.arrow.up.left", group: .optimize, inputs: [.pdf],
        options: [
            .choice(
                "level", "Compression",
                [
                    StudioChoice("low", "Less"), StudioChoice("recommended", "Recommended"),
                    StudioChoice("extreme", "Extreme"),
                ], default: "recommended",
                help:
                    "Extreme turns pages into compressed images with an invisible text layer, so text stays searchable."
            ),
            .toggle("grayscale", "Convert to grayscale", default: false),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["reduce", "shrink", "smaller", "optimize", "size"], actionTitle: "Compress"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let level = run.settings.text("level")
        let grayscale = run.settings.bool("grayscale")
        let output = run.output(for: run.input, suffix: "compressed", ext: "pdf")
        run.status("Compressing")
        switch level {
        case "extreme":
            try PDFCompression.rasterize(
                document, dpi: 110, quality: 0.5, grayscale: grayscale, to: output
            ) { run.progress($0 * 0.9) }
        default:
            let settings =
                level == "low"
                ? PDFCompression.ImageSettings(quality: 0.82, resolution: 220, maxSize: 3600)
                : PDFCompression.ImageSettings(quality: 0.68, resolution: 144, maxSize: 2400)
            try PDFCompression.recompress(
                document, settings: settings, grayscale: grayscale, to: output
            ) { run.progress($0 * 0.9) }
        }
        if let qpdf = run.environment.qpdf {
            try await PDFCompression.qpdfOptimize(output, qpdf: qpdf, scratch: run.scratch("qpdf"))
        }
        let before = StudioRunner.fileSize(run.input)
        let after = StudioRunner.fileSize(output)
        if after >= before {
            try FileManager.default.removeItem(at: output)
            try FileManager.default.copyItem(at: run.input, to: output)
            run.note("This PDF is already as small as this level allows, so the copy is unchanged.")
        }
        return [output]
    }

    static let grayscale = StudioTool(
        id: "pdf.grayscale", title: "Grayscale PDF",
        summary: "Convert every page to shades of gray for cheaper printing. Text stays sharp.",
        symbol: "circle.lefthalf.filled", group: .optimize, inputs: [.pdf],
        options: [PDFOrganizeTools.passwordOption],
        keywords: ["black and white", "monochrome", "gray", "print"], actionTitle: "Convert"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let output = run.output(for: run.input, suffix: "grayscale", ext: "pdf")
        try PDFCompression.grayscale(document, to: output) { run.progress($0) }
        return [output]
    }

    static let ocr = StudioTool(
        id: "pdf.ocr", title: "OCR PDF",
        summary: "Make scanned PDFs searchable and selectable with on-device text recognition.",
        symbol: "text.viewfinder", group: .optimize, inputs: [.pdf, .image],
        produces: .kind(.pdf),
        options: [
            .choice("language", "Language", StudioVision.languageChoices, default: "auto"),
            .choice(
                "accuracy", "Recognition",
                [StudioChoice("accurate", "Accurate"), StudioChoice("fast", "Fast")],
                default: "accurate"),
            .toggle("skipText", "Skip pages that already have text", default: true),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["scan", "searchable", "recognize", "text", "selectable"],
        actionTitle: "Recognize text", family: .pdf
    ) { run in
        var document: PDFDocument
        if run.input.studioKind == .image {
            let image = try StudioImageIO.load(run.input)
            let page = ImagesToPDF.page(
                for: image,
                layout: {
                    var layout = ImagesToPDF.Layout()
                    layout.paper = nil
                    return layout
                }())
            document = PDFDocument()
            if let page { document.insert(page, at: 0) }
        } else {
            document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        }
        let language = run.settings.text("language")
        let accurate = run.settings.text("accuracy") != "fast"
        let skip = run.settings.bool("skipText")
        var layers: [Int: [StudioPDF.TextLine]] = [:]
        var recognizedPages = 0
        for index in 0..<document.pageCount {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if skip, let text = page.string,
                text.trimmingCharacters(in: .whitespacesAndNewlines).count > 20
            {
                continue
            }
            run.status("Reading page \(index + 1) of \(document.pageCount)")
            let lines = try await recognizedLines(on: page, language: language, accurate: accurate)
            layers[index] = lines
            if !lines.isEmpty { recognizedPages += 1 }
            run.progress(Double(index + 1) / Double(document.pageCount) * 0.85)
        }
        guard !layers.isEmpty else {
            throw StudioError.nothingToDo("Every page already has selectable text.")
        }
        let output = run.output(for: run.input, suffix: "ocr", ext: "pdf")
        try StudioPDF.rebuild(
            document, to: output, pages: Set(layers.keys),
            over: { canvas in
                StudioPDF.drawInvisibleText(layers[canvas.index] ?? [], in: canvas.context)
            }, progress: { run.progress(0.85 + $0 * 0.15) })
        run.note("Recognized text on \(recognizedPages) of \(document.pageCount) pages.")
        return [output]
    }

    static func recognizedLines(
        on page: PDFPage, language: String = "auto", accurate: Bool = true
    ) async throws -> [StudioPDF.TextLine] {
        let image = try StudioPDF.render(page, dpi: 240, maxPixels: 40_000_000)
        let size = StudioPDF.displaySize(page)
        return try await StudioVision.recognizeText(
            in: image, language: language, accurate: accurate
        )
        .map { line in
            StudioPDF.TextLine(
                text: line.text,
                rect: CGRect(
                    x: line.box.minX * size.width, y: line.box.minY * size.height,
                    width: line.box.width * size.width, height: line.box.height * size.height))
        }
    }

    static let repair = StudioTool(
        id: "pdf.repair", title: "Repair PDF",
        summary: "Rebuild a damaged PDF and recover as much of it as possible.",
        symbol: "bandage", group: .optimize, inputs: [.pdf],
        options: [PDFOrganizeTools.passwordOption],
        keywords: ["fix", "corrupt", "broken", "recover", "damaged"], actionTitle: "Repair"
    ) { run in
        let output = run.output(for: run.input, suffix: "repaired", ext: "pdf")
        if let qpdf = run.environment.qpdf {
            let result = try await StudioProcess.run(
                qpdf, ["--warning-exit-0", run.input.path, output.path], timeout: 600)
            if result.status == 0, PDFDocument(url: output) != nil { return [output] }
            try? FileManager.default.removeItem(at: output)
        }
        if let document = PDFDocument(url: run.input) {
            if document.isLocked {
                _ = try StudioPDF.open(run.input, password: run.settings.text("password"))
                guard document.unlock(withPassword: run.settings.text("password")) else {
                    throw StudioError.wrongPassword(run.input.lastPathComponent)
                }
            }
            try StudioPDF.write(document, to: output)
            return [output]
        }
        guard let document = CGPDFDocument(run.input as CFURL), document.numberOfPages > 0 else {
            throw StudioError.failed(
                "\(run.input.lastPathComponent) is too damaged to recover on this Mac.")
        }
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw StudioError.failed("Could not create \(output.lastPathComponent).")
        }
        for index in 1...document.numberOfPages {
            guard let page = document.page(at: index) else { continue }
            var box = page.getBoxRect(.cropBox)
            context.beginPage(mediaBox: &box)
            context.drawPDFPage(page)
            context.endPage()
        }
        context.closePDF()
        return [output]
    }

    static let flatten = StudioTool(
        id: "pdf.flatten", title: "Flatten PDF",
        summary: "Burn comments, drawings and form fields into the page so they cannot be edited.",
        symbol: "square.3.layers.3d.down.right", group: .security, inputs: [.pdf],
        options: [PDFOrganizeTools.passwordOption],
        keywords: ["annotations", "forms", "burn", "lock", "fields"], actionTitle: "Flatten"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let output = run.output(for: run.input, suffix: "flattened", ext: "pdf")
        try StudioPDF.write(document, to: output, options: [.burnInAnnotationsOption: true])
        try StudioPDF.restoreLinks(from: document, into: output)
        return [output]
    }

    static let decompress = StudioTool(
        id: "pdf.decompress", title: "Decompress PDF",
        summary: "Expand compressed streams so the PDF can be inspected or edited by hand.",
        symbol: "arrow.up.left.and.arrow.down.right", group: .optimize, inputs: [.pdf],
        options: [PDFOrganizeTools.passwordOption], requirements: [.engine(.qpdf)],
        keywords: ["uncompress", "inflate", "qdf", "streams", "debug"], actionTitle: "Decompress"
    ) { run in
        let qpdf = try run.environment.require(.qpdf)
        let output = run.output(for: run.input, suffix: "uncompressed", ext: "pdf")
        var arguments = [
            "--qdf", "--object-streams=disable", "--stream-data=uncompress", "--warning-exit-0",
        ]
        let password = run.settings.text("password")
        if !password.isEmpty { arguments.append("--password=\(password)") }
        let result = try await StudioProcess.run(
            qpdf, arguments + [run.input.path, output.path], timeout: 900)
        guard result.status == 0 else {
            throw StudioError.failed(
                "qpdf could not decompress the file: \(result.errorTail.suffix(300))")
        }
        return [output]
    }

    static let linearize = StudioTool(
        id: "pdf.linearize", title: "Optimize for web",
        summary: "Linearize a PDF so browsers show the first page before the rest downloads.",
        symbol: "bolt.horizontal", group: .optimize, inputs: [.pdf],
        options: [PDFOrganizeTools.passwordOption], requirements: [.engine(.qpdf)],
        keywords: ["linearize", "fast web view", "streaming"], actionTitle: "Optimize"
    ) { run in
        let qpdf = try run.environment.require(.qpdf)
        let output = run.output(for: run.input, suffix: "web", ext: "pdf")
        var arguments = ["--linearize", "--object-streams=generate", "--warning-exit-0"]
        let password = run.settings.text("password")
        if !password.isEmpty { arguments.append("--password=\(password)") }
        let result = try await StudioProcess.run(
            qpdf, arguments + [run.input.path, output.path], timeout: 900)
        guard result.status == 0 else {
            throw StudioError.failed(
                "qpdf could not optimize the file: \(result.errorTail.suffix(300))")
        }
        return [output]
    }
}

enum PDFCompression {
    static func rasterize(
        _ document: PDFDocument, dpi: Double, quality: Double, grayscale: Bool, to url: URL,
        progress: (Double) -> Void
    ) throws {
        let navigation = PDFNavigation(
            original: document, placements: StudioPDF.identityPlacements(document))
        guard
            let context = CGContext(
                url as CFURL, mediaBox: nil, StudioPDF.documentInfo(document) as CFDictionary)
        else { throw StudioError.failed("Could not create \(url.lastPathComponent).") }
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let size = StudioPDF.displaySize(page)
            var box = CGRect(origin: .zero, size: size)
            let rendered = try StudioPDF.render(page, dpi: dpi)
            let image = try StudioPDF.jpegImage(rendered, quality: quality, grayscale: grayscale)
            context.beginPage(mediaBox: &box)
            navigation.begin(page: index, in: context)
            context.interpolationQuality = .high
            context.draw(image, in: box)
            StudioPDF.drawInvisibleText(StudioPDF.textLines(of: page), in: context)
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        navigation.finish(in: context)
        context.closePDF()
    }

    struct ImageSettings {
        let quality: Double
        let resolution: Double
        let maxSize: Int

        var filter: QuartzFilter? {
            QuartzFilter(properties: [
                "Name": "Studio Compress", "FilterType": 1,
                "Domains": ["Applications": true, "Printing": true],
                "FilterData": [
                    "ColorSettings": [
                        "ImageSettings": [
                            "Compression Quality": quality,
                            "ImageCompression": "ImageJPEGCompress",
                            "ImageScaleSettings": [
                                "ImageResolution": resolution, "ImageScaleInterpolate": true,
                                "ImageSizeMax": maxSize, "ImageSizeMin": 0,
                            ],
                        ]
                    ]
                ],
            ])
        }
    }

    static var grayFilter: QuartzFilter? {
        QuartzFilter(url: URL(fileURLWithPath: "/System/Library/Filters/Gray Tone.qfilter"))
    }

    static func recompress(
        _ document: PDFDocument, settings: ImageSettings, grayscale: Bool, to url: URL,
        progress: ((Double) -> Void)? = nil
    ) throws {
        let filters = [settings.filter, grayscale ? grayFilter : nil].compactMap { $0 }
        guard !filters.isEmpty else {
            try StudioPDF.write(document, to: url, options: [.saveImagesAsJPEGOption: true])
            return
        }
        try StudioPDF.rebuild(
            document, to: url,
            pageSetup: { context in
                for filter in filters { _ = filter.apply(to: context) }
            }, adjust: grayscale ? grayAnnotation : nil, progress: progress)
    }

    static func grayscale(
        _ document: PDFDocument, to url: URL, progress: ((Double) -> Void)? = nil
    ) throws {
        guard let filter = grayFilter else {
            try rasterize(document, dpi: 200, quality: 0.8, grayscale: true, to: url) {
                progress?($0)
            }
            return
        }
        try StudioPDF.rebuild(
            document, to: url, pageSetup: { context in _ = filter.apply(to: context) },
            adjust: grayAnnotation, progress: progress)
    }

    static func grayAnnotation(_ annotation: PDFAnnotation) {
        annotation.color = gray(annotation.color) ?? annotation.color
        annotation.interiorColor = gray(annotation.interiorColor)
        annotation.fontColor = gray(annotation.fontColor)
        annotation.backgroundColor = gray(annotation.backgroundColor)
    }

    static func gray(_ color: NSColor?) -> NSColor? {
        guard let color, let rgb = color.usingColorSpace(.sRGB) else { return color }
        let luminance =
            0.299 * rgb.redComponent + 0.587 * rgb.greenComponent + 0.114 * rgb.blueComponent
        return NSColor(white: luminance, alpha: rgb.alphaComponent)
    }

    static func qpdfOptimize(_ url: URL, qpdf: URL, scratch: URL) async throws {
        let candidate = scratch.appendingPathComponent("optimized.pdf")
        let result = try await StudioProcess.run(
            qpdf,
            [
                "--object-streams=generate", "--compress-streams=y", "--recompress-flate",
                "--compression-level=9", "--warning-exit-0", url.path, candidate.path,
            ], timeout: 900)
        guard result.status == 0,
            StudioRunner.fileSize(candidate) > 0,
            StudioRunner.fileSize(candidate) < StudioRunner.fileSize(url)
        else { return }
        _ = try FileManager.default.replaceItemAt(url, withItemAt: candidate)
    }
}
