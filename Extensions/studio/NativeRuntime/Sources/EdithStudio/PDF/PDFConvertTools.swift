import AppKit
import CoreGraphics
import Foundation
import PDFKit

enum PDFConvertTools {
    static var all: [StudioTool] {
        [toWord, toPowerPoint, toExcel, toText, toMarkdown, toPDFA].map { $0.checkingChoices() }
    }

    static let toWord = StudioTool(
        id: "pdf.to-word", title: "PDF to Word",
        summary: "Turn a PDF into an editable DOCX with headings, paragraphs and images.",
        symbol: "doc.text", group: .convert, inputs: [.pdf], produces: .kind(.document),
        options: [
            .choice(
                "mode", "Result",
                [
                    StudioChoice("editable", "Editable text"),
                    StudioChoice("layout", "Exact look (page images)"),
                ], default: "editable"),
            .toggle("images", "Include images", default: true, when: .init("mode", ["editable"])),
            .toggle(
                "pageBreaks", "Keep page breaks", default: true, when: .init("mode", ["editable"])),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["docx", "doc", "word", "editable", "convert"], actionTitle: "Convert to Word"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let output = run.output(for: run.input, suffix: nil, ext: "docx")
        let firstSize =
            document.page(at: 0).map(StudioPDF.displaySize) ?? CGSize(width: 612, height: 792)
        var blocks: [DOCXWriter.Block] = []
        if run.settings.text("mode") == "layout" {
            for index in 0..<document.pageCount {
                try run.checkCancellation()
                guard let page = document.page(at: index) else { continue }
                let image = try StudioPDF.render(page, dpi: 150)
                let data = try StudioImageIO.encode(
                    image, format: .jpeg, options: .init(quality: 0.85))
                let size = StudioPDF.displaySize(page)
                if index > 0 { blocks.append(.pageBreak) }
                blocks.append(.image(data, ext: "jpg", width: size.width, height: size.height))
                run.progress(Double(index + 1) / Double(document.pageCount))
            }
            try DOCXWriter.write(
                blocks, title: run.input.studioStem, pageSize: firstSize, margin: 0, to: output)
            return [output]
        }
        var pages: [[PDFTextAnalysis.Line]] = []
        for index in 0..<document.pageCount {
            pages.append(document.page(at: index).map(PDFTextAnalysis.lines(of:)) ?? [])
        }
        let body = PDFTextAnalysis.bodySize(pages)
        let scratch = try run.scratch("images")
        for (index, lines) in pages.enumerated() {
            try run.checkCancellation()
            if index > 0, run.settings.bool("pageBreaks") { blocks.append(.pageBreak) }
            for block in PDFTextAnalysis.blocks(lines, body: body) {
                guard case .paragraph(let paragraph) = block else {
                    if case .table(let rows) = block { blocks.append(.table(rows)) }
                    continue
                }
                let text = paragraph.bullet ? "• " + paragraph.text : paragraph.text
                blocks.append(
                    .paragraph(
                        [
                            DOCXWriter.Run(
                                text: text, size: Double(paragraph.size), bold: paragraph.bold,
                                italic: paragraph.italic)
                        ], heading: paragraph.heading))
            }
            if run.settings.bool("images"), let page = document.page(at: index) {
                let single = PDFDocument()
                if let copy = page.copy() as? PDFPage { single.insert(copy, at: 0) }
                let files = try PDFImageExtractor.extract(
                    from: single, stem: "p\(index)", into: scratch
                ) { _ in }
                for file in files {
                    guard let info = StudioImageIO.info(file), info.width > 24, info.height > 24,
                        let data = try? Data(contentsOf: file)
                    else { continue }
                    let ext = file.pathExtension == "jp2" ? "png" : file.pathExtension
                    let payload =
                        ext == file.pathExtension
                        ? data : try StudioImageIO.encode(StudioImageIO.load(file), format: .png)
                    blocks.append(
                        .image(
                            payload, ext: ext, width: Double(info.width) * 0.5,
                            height: Double(info.height) * 0.5))
                }
            }
            run.progress(Double(index + 1) / Double(document.pageCount))
        }
        if blocks.isEmpty {
            run.note("No text was found. Try OCR PDF first if this is a scan.")
            blocks.append(.paragraph([DOCXWriter.Run(text: "")], heading: nil))
        }
        try DOCXWriter.write(blocks, title: run.input.studioStem, pageSize: firstSize, to: output)
        return [output]
    }

    static let toPowerPoint = StudioTool(
        id: "pdf.to-powerpoint", title: "PDF to PowerPoint",
        summary: "Turn each PDF page into a PowerPoint slide that looks exactly the same.",
        symbol: "rectangle.on.rectangle.angled", group: .convert, inputs: [.pdf],
        produces: .kind(.presentation),
        options: [
            .choice(
                "dpi", "Quality",
                [
                    StudioChoice("110", "Smaller file"), StudioChoice("160", "Balanced"),
                    StudioChoice("220", "Sharp"),
                ],
                default: "160"),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["pptx", "ppt", "slides", "keynote", "convert"],
        actionTitle: "Convert to PowerPoint"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let dpi = Double(run.settings.text("dpi")) ?? 160
        var slides: [PPTXWriter.Slide] = []
        var size = CGSize(width: 720, height: 405)
        for index in 0..<document.pageCount {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            if index == 0 { size = StudioPDF.displaySize(page) }
            let image = try letterboxed(StudioPDF.render(page, dpi: dpi), to: size)
            let data = try StudioImageIO.encode(image, format: .jpeg, options: .init(quality: 0.88))
            slides.append(PPTXWriter.Slide(image: data, imageExtension: "jpg", notes: page.string))
            run.progress(Double(index + 1) / Double(document.pageCount) * 0.9)
        }
        let output = run.output(for: run.input, suffix: nil, ext: "pptx")
        try PPTXWriter.write(slides, size: size, title: run.input.studioStem, to: output)
        return [output]
    }

    static func letterboxed(_ image: CGImage, to slide: CGSize) throws -> CGImage {
        let ratio = slide.width / slide.height
        let width = Double(image.width)
        let height = Double(image.height)
        guard abs(width / height - ratio) > 0.002 else { return image }
        let canvas =
            width / height > ratio
            ? CGSize(width: width, height: (width / ratio).rounded())
            : CGSize(width: (height * ratio).rounded(), height: height)
        guard
            let context = StudioImageOps.context(
                width: Int(canvas.width), height: Int(canvas.height), opaque: true)
        else { throw StudioError.failed("Not enough memory to draw the slide.") }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(origin: .zero, size: canvas))
        context.draw(
            image,
            in: CGRect(
                x: ((canvas.width - width) / 2).rounded(),
                y: ((canvas.height - height) / 2).rounded(),
                width: width, height: height))
        guard let result = context.makeImage() else {
            throw StudioError.failed("The slide could not be drawn.")
        }
        return result
    }

    static let toExcel = StudioTool(
        id: "pdf.to-excel", title: "PDF to Excel",
        summary: "Pull tables and aligned text out of a PDF into an XLSX spreadsheet.",
        symbol: "tablecells", group: .convert, inputs: [.pdf], produces: .kind(.spreadsheet),
        options: [
            .choice(
                "sheets", "Sheets",
                [
                    StudioChoice("page", "One sheet per page"),
                    StudioChoice("single", "Everything on one sheet"),
                ],
                default: "page"),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["xlsx", "xls", "spreadsheet", "table", "csv", "numbers"],
        actionTitle: "Convert to Excel"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        var sheets: [XLSXWriter.Sheet] = []
        var combined: [[String]] = []
        for index in 0..<document.pageCount {
            try run.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let rows = PDFTextAnalysis.table(PDFTextAnalysis.lines(of: page))
            if run.settings.text("sheets") == "single" {
                if !combined.isEmpty, !rows.isEmpty { combined.append([]) }
                combined += rows
            } else {
                sheets.append(XLSXWriter.Sheet(name: "Page \(index + 1)", rows: rows))
            }
            run.progress(Double(index + 1) / Double(document.pageCount))
        }
        if run.settings.text("sheets") == "single" {
            sheets = [XLSXWriter.Sheet(name: run.input.studioStem, rows: combined)]
        }
        if sheets.allSatisfy({ $0.rows.isEmpty }) {
            run.note("No text was found. Try OCR PDF first if this is a scan.")
        }
        let output = run.output(for: run.input, suffix: nil, ext: "xlsx")
        try XLSXWriter.write(sheets, title: run.input.studioStem, to: output)
        return [output]
    }

    static let toText = StudioTool(
        id: "pdf.to-text", title: "PDF to text",
        summary: "Save all the text in a PDF as a plain text file.",
        symbol: "text.alignleft", group: .convert, inputs: [.pdf], produces: .kind(.document),
        options: [
            .toggle("pageMarkers", "Mark where each page starts", default: false),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["txt", "extract text", "copy"], actionTitle: "Extract text"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        var parts: [String] = []
        for index in 0..<document.pageCount {
            let text = document.page(at: index)?.string ?? ""
            parts.append(
                run.settings.bool("pageMarkers") ? "--- Page \(index + 1) ---\n" + text : text)
        }
        let joined = parts.joined(
            separator: run.settings.bool("pageMarkers") ? "\n\n" : "\n\u{0C}\n")
        if joined.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            run.note("No text was found. Try OCR PDF first if this is a scan.")
        }
        let output = run.output(for: run.input, suffix: nil, ext: "txt")
        try joined.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static let toMarkdown = StudioTool(
        id: "pdf.to-markdown", title: "PDF to Markdown",
        summary: "Turn PDFs into clean Markdown with headings and lists, ready for notes or LLMs.",
        symbol: "number.square", group: .convert, inputs: [.pdf], produces: .kind(.document),
        options: [PDFOrganizeTools.passwordOption],
        keywords: ["md", "markdown", "llm", "notes", "headings"], actionTitle: "Convert to Markdown"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let markdown = PDFTextAnalysis.markdown(document) { run.progress($0) }
        let output = run.output(for: run.input, suffix: nil, ext: "md")
        try markdown.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static let toPDFA = StudioTool(
        id: "pdf.to-pdfa", title: "PDF to PDF/A",
        summary:
            "Make an archival copy with an embedded color profile and PDF/A-2b identification.",
        symbol: "archivebox", group: .convert, inputs: [.pdf], produces: .kind(.pdf),
        options: [
            .choice(
                "mode", "Pages",
                [
                    StudioChoice("vector", "Keep text and vectors"),
                    StudioChoice("flatten", "Flatten to images"),
                ],
                default: "vector",
                help:
                    "Flattening removes transparency and fonts, the most common reasons archives fail validation."
            ),
            PDFOrganizeTools.passwordOption,
        ],
        keywords: ["archive", "iso", "long-term", "pdfa", "preservation"], actionTitle: "Convert"
    ) { run in
        let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
        let output = run.output(for: run.input, suffix: "pdfa", ext: "pdf")
        try PDFArchival.write(
            document, title: run.input.studioStem, flatten: run.settings.text("mode") == "flatten",
            to: output
        ) { run.progress($0) }
        run.note(
            "Includes an sRGB output intent and PDF/A-2b metadata. Check with a validator such as veraPDF if an archive requires certified compliance."
        )
        return [output]
    }
}

enum PDFArchival {
    static func write(
        _ document: PDFDocument, title: String, flatten: Bool, to url: URL,
        progress: (Double) -> Void
    ) throws {
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        let intent: [CFString: Any] = [
            kCGPDFXOutputIntentSubtype: "GTS_PDFA1",
            kCGPDFXOutputConditionIdentifier: "sRGB IEC61966-2.1",
            kCGPDFXOutputCondition: "sRGB IEC61966-2.1",
            kCGPDFXRegistryName: "http://www.color.org",
            kCGPDFXInfo: "sRGB IEC61966-2.1",
            kCGPDFXDestinationOutputProfile: sRGB,
        ]
        var info = StudioPDF.documentInfo(document)
        info[kCGPDFContextOutputIntent] = intent
        if info[kCGPDFContextTitle] == nil { info[kCGPDFContextTitle] = title }
        let navigation = PDFNavigation(
            original: document, placements: StudioPDF.identityPlacements(document))
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw StudioError.failed("Could not create \(url.lastPathComponent).")
        }
        context.addDocumentMetadata(
            xmp(title: info[kCGPDFContextTitle] as? String ?? title) as CFData)
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { continue }
            let size = StudioPDF.displaySize(page)
            var box = CGRect(origin: .zero, size: size)
            context.beginPage(mediaBox: &box)
            navigation.begin(page: index, in: context)
            if flatten {
                let image = try StudioPDF.render(page, dpi: 200)
                context.draw(try StudioPDF.jpegImage(image, quality: 0.9), in: box)
                StudioPDF.drawInvisibleText(StudioPDF.textLines(of: page), in: context)
            } else {
                StudioPDF.drawDisplayed(page, in: context)
            }
            context.endPage()
            progress(Double(index + 1) / Double(document.pageCount))
        }
        navigation.finish(in: context)
        context.closePDF()
    }

    static func xmp(title: String) -> Data {
        let date = ISO8601DateFormatter().string(from: Date())
        let escaped = OOXMLPackage.escape(title)
        let xml =
            "<?xpacket begin=\"\u{FEFF}\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>"
            + "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:pdfaid=\"http://www.aiim.org/pdfa/ns/id/\"><pdfaid:part>2</pdfaid:part><pdfaid:conformance>B</pdfaid:conformance></rdf:Description>"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:format>application/pdf</dc:format><dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">\(escaped)</rdf:li></rdf:Alt></dc:title></rdf:Description>"
            + "<rdf:Description rdf:about=\"\" xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"><xmp:CreateDate>\(date)</xmp:CreateDate><xmp:ModifyDate>\(date)</xmp:ModifyDate><xmp:CreatorTool>Edith Studio</xmp:CreatorTool></rdf:Description>"
            + "</rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
        return Data(xml.utf8)
    }
}
