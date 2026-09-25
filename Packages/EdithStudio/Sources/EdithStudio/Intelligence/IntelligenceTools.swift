import Foundation
import NaturalLanguage
import PDFKit

enum IntelligenceTools {
    static var all: [StudioTool] { [summarize, translate, StudioTranscription.tool] }

    static let summarize = StudioTool(
        id: "ai.summarize", title: "AI summarizer",
        summary: "Get the key points of a PDF or document in seconds, generated on this Mac.",
        symbol: "sparkles", group: .intelligence, inputs: [.pdf, .document],
        produces: .kind(.document),
        options: [
            .choice(
                "length", "Length",
                [
                    StudioChoice("short", "Short"), StudioChoice("medium", "Medium"),
                    StudioChoice("detailed", "Detailed"),
                ], default: "medium"),
            .choice(
                "style", "Style",
                [
                    StudioChoice("bullets", "Bullet points"),
                    StudioChoice("paragraph", "Paragraphs"),
                ],
                default: "bullets"),
            PDFOrganizeTools.passwordOption,
        ],
        requirements: [.appleIntelligence],
        keywords: ["summary", "tldr", "key points", "ai", "apple intelligence", "digest"],
        actionTitle: "Summarize", family: .pdf
    ) { run in
        let blocks = try await IntelligenceSource.blocks(
            of: run.input, password: run.settings.text("password"))
        let text = blocks.map(\.text).joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw StudioError.nothingToDo(
                "No text was found in \(run.input.lastPathComponent). Run OCR first if it is a scan."
            )
        }
        run.status("Summarizing with Apple Intelligence")
        let summary = try await StudioSummarizer.summarize(
            text, length: run.settings.text("length"),
            bullets: run.settings.text("style") == "bullets"
        ) { run.progress($0) }
        let output = run.output(for: run.input, suffix: "summary", ext: "md")
        let markdown = "# Summary of \(run.input.studioStem)\n\n" + summary + "\n"
        try markdown.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static let languages: [StudioChoice] = [
        StudioChoice("en", "English"), StudioChoice("es", "Spanish"),
        StudioChoice("fr", "French"), StudioChoice("de", "German"),
        StudioChoice("it", "Italian"), StudioChoice("pt", "Portuguese"),
        StudioChoice("nl", "Dutch"), StudioChoice("pl", "Polish"),
        StudioChoice("tr", "Turkish"), StudioChoice("ru", "Russian"),
        StudioChoice("uk", "Ukrainian"), StudioChoice("ar", "Arabic"),
        StudioChoice("hi", "Hindi"), StudioChoice("id", "Indonesian"),
        StudioChoice("vi", "Vietnamese"), StudioChoice("th", "Thai"),
        StudioChoice("ja", "Japanese"), StudioChoice("ko", "Korean"),
        StudioChoice("zh-Hans", "Chinese, Simplified"),
        StudioChoice("zh-Hant", "Chinese, Traditional"),
    ]

    static let translate = StudioTool(
        id: "ai.translate", title: "Translate PDF",
        summary:
            "Translate PDFs on this Mac and keep their layout, or save any document as Word or Markdown.",
        symbol: "character.bubble", group: .intelligence, inputs: [.pdf, .document],
        produces: .kind(.document),
        options: [
            .choice("target", "Translate to", languages, default: "es"),
            .choice(
                "source", "From", [StudioChoice("auto", "Detect automatically")] + languages,
                default: "auto"),
            .choice(
                "format", "Save as",
                [
                    StudioChoice("pdf", "PDF, same layout"), StudioChoice("docx", "Word document"),
                    StudioChoice("md", "Markdown"),
                ],
                default: "pdf",
                help:
                    "Same layout puts each translated paragraph where the original was. Documents that are not PDFs are saved as Word."
            ),
            PDFOrganizeTools.passwordOption,
        ],
        requirements: [.translation],
        keywords: ["translate", "language", "translation", "localize", "spanish", "french"],
        actionTitle: "Translate", family: .pdf
    ) { run in
        let blocks = try await IntelligenceSource.blocks(
            of: run.input, password: run.settings.text("password"))
        guard !blocks.isEmpty else {
            throw StudioError.nothingToDo(
                "No text was found in \(run.input.lastPathComponent). Run OCR first if it is a scan."
            )
        }
        let target = run.settings.text("target")
        let source =
            run.settings.text("source") == "auto"
            ? try StudioTranslator.detectLanguage(blocks.map(\.text).joined(separator: "\n"))
            : run.settings.text("source")
        guard StudioTranslator.normalized(source) != StudioTranslator.normalized(target) else {
            throw StudioError.nothingToDo("The document is already in that language.")
        }
        run.status("Translating")
        let translated = try await StudioTranslator.translate(
            blocks, from: source, to: target
        ) { run.progress($0 * 0.95) }
        let suffix = target.lowercased()
        if run.settings.text("format") == "pdf", run.input.studioKind == .pdf {
            let document = try StudioPDF.open(run.input, password: run.settings.text("password"))
            let layout = LayoutTranslation.blocks(of: document)
            let wanted = layout.filter(\.translatable)
            let translated = try await StudioTranslator.translateStrings(
                wanted.map(\.text), from: source, to: target
            ) { run.progress($0 * 0.7) }
            var lookup: [String: String] = [:]
            for (block, text) in zip(wanted, translated) { lookup[block.text] = text }
            let strings = layout.map { lookup[$0.text] ?? $0.text }
            let output = run.output(for: run.input, suffix: suffix, ext: "pdf")
            try LayoutTranslation.write(document, blocks: layout, translations: strings, to: output)
            {
                run.progress(0.7 + $0 * 0.3)
            }
            return [output]
        }
        if run.settings.text("format") == "md" {
            let output = run.output(for: run.input, suffix: suffix, ext: "md")
            try DocumentMarkdown.render(translated).write(
                to: output, atomically: true, encoding: .utf8)
            return [output]
        }
        let output = run.output(for: run.input, suffix: suffix, ext: "docx")
        try DOCXWriter.write(
            IntelligenceSource.docxBlocks(translated), title: run.input.studioStem, to: output)
        return [output]
    }
}

enum IntelligenceSource {
    static func blocks(of url: URL, password: String) async throws -> [DocumentMarkdown.Block] {
        if url.studioKind == .pdf {
            let document = try StudioPDF.open(url, password: password)
            var pages: [[PDFTextAnalysis.Line]] = []
            for index in 0..<document.pageCount {
                pages.append(document.page(at: index).map(PDFTextAnalysis.lines(of:)) ?? [])
            }
            let body = PDFTextAnalysis.bodySize(pages)
            return pages.flatMap { PDFTextAnalysis.paragraphs($0, body: body) }.map { paragraph in
                DocumentMarkdown.Block(
                    text: paragraph.text, markdown: paragraph.text, heading: paragraph.heading,
                    listLevel: paragraph.bullet ? 1 : 0, ordered: false)
            }
        }
        return try await DocumentText.paragraphs(url)
    }

    static func docxBlocks(_ blocks: [DocumentMarkdown.Block]) -> [DOCXWriter.Block] {
        blocks.map { block in
            if block.markdown.hasPrefix("|") {
                let rows = block.markdown.split(separator: "\n").map(String.init).filter {
                    !$0.replacingOccurrences(of: " ", with: "").hasPrefix("|---")
                }
                return .table(rows.map(tableCells))
            }
            let prefix = block.listLevel > 0 ? "• " : ""
            let size: Double = block.heading.map { [0, 20, 16, 13][min($0, 3)] } ?? 11
            return .paragraph(
                [DOCXWriter.Run(text: prefix + block.text, size: size, bold: block.heading != nil)],
                heading: block.heading)
        }
    }

    static func tableCells(_ row: String) -> [String] {
        var trimmed = row.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: " | ").map {
            $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\\|", with: "|")
        }
    }
}
