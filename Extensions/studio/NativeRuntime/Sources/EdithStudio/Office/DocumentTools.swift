import AppKit
import Foundation

enum DocumentTools {
    static var all: [StudioTool] {
        [toPDF, wordToPDF, excelToPDF, powerPointToPDF, toMarkdown, toText] + WebTools.all
    }

    static let pageOptions: [StudioOption] = [
        DocumentPageSetup.paperOption, DocumentPageSetup.orientationOption,
        DocumentPageSetup.marginOption,
    ]

    static let headerOption = StudioOption.toggle(
        "headerRow", "Repeat the first row on every page", default: true,
        help: "Applies to spreadsheets.")

    static let toPDF = StudioTool(
        id: "document.to-pdf", title: "Office to PDF",
        summary: "Convert Word, Excel, PowerPoint, text, Markdown and HTML files into PDF.",
        symbol: "doc.richtext", group: .convert, inputs: [.document, .spreadsheet, .presentation],
        produces: .kind(.pdf), options: pageOptions + [headerOption],
        keywords: [
            "word", "docx", "excel", "xlsx", "powerpoint", "pptx", "csv", "markdown", "rtf",
        ],
        actionTitle: "Convert to PDF", family: .document, perform: { try await convert($0) })

    static let wordToPDF = StudioTool(
        id: "document.word-to-pdf", title: "Word to PDF",
        summary: "Make DOC, DOCX, RTF, ODT, text and Markdown files easy to read and share as PDF.",
        symbol: "doc.text", group: .convert, inputs: [.document], produces: .kind(.pdf),
        options: pageOptions, keywords: ["docx", "doc", "rtf", "odt", "pages", "text", "markdown"],
        actionTitle: "Convert to PDF", family: .document, perform: { try await convert($0) })

    static let excelToPDF = StudioTool(
        id: "document.excel-to-pdf", title: "Excel to PDF",
        summary: "Print XLSX and CSV spreadsheets as clean, paginated PDF tables.",
        symbol: "tablecells", group: .convert, inputs: [.spreadsheet], produces: .kind(.pdf),
        options: pageOptions + [headerOption], keywords: ["xlsx", "xls", "csv", "tsv", "sheet"],
        actionTitle: "Convert to PDF", family: .document, perform: { try await convert($0) })

    static let powerPointToPDF = StudioTool(
        id: "document.powerpoint-to-pdf", title: "PowerPoint to PDF",
        summary: "Turn PPTX slideshows into a PDF with one slide per page.",
        symbol: "rectangle.on.rectangle.angled", group: .convert, inputs: [.presentation],
        produces: .kind(.pdf), keywords: ["pptx", "ppt", "slides", "deck", "keynote"],
        actionTitle: "Convert to PDF", family: .document, perform: { try await convert($0) })

    static let toMarkdown = StudioTool(
        id: "document.to-markdown", title: "Convert to Markdown",
        summary:
            "Turn Word, HTML, RTF, slides and spreadsheets into clean Markdown for notes or LLMs.",
        symbol: "number.square", group: .convert, inputs: [.document, .spreadsheet, .presentation],
        excludedExtensions: ["md", "markdown"], produces: .kind(.document),
        keywords: ["md", "markdown", "llm", "notes", "docx", "html"], actionTitle: "Convert",
        family: .document
    ) { run in
        run.status("Reading \(run.input.lastPathComponent)")
        let markdown = try await DocumentText.markdown(run.input)
        let output = run.output(for: run.input, suffix: nil, ext: "md")
        try markdown.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static let toText = StudioTool(
        id: "document.to-text", title: "Extract text",
        summary: "Save the plain text of documents, slides and spreadsheets as a .txt file.",
        symbol: "text.alignleft", group: .convert,
        inputs: [.document, .spreadsheet, .presentation],
        excludedExtensions: ["txt", "text"], produces: .kind(.document),
        keywords: ["txt", "plain text", "copy"], actionTitle: "Extract text", family: .document
    ) { run in
        run.status("Reading \(run.input.lastPathComponent)")
        let text = try await DocumentText.plain(run.input)
        let output = run.output(for: run.input, suffix: nil, ext: "txt")
        try text.write(to: output, atomically: true, encoding: .utf8)
        return [output]
    }

    static func convert(_ run: StudioRun) async throws -> [URL] {
        let input = run.input
        let ext = input.pathExtension.lowercased()
        let output = run.output(for: input, suffix: nil, ext: "pdf")
        run.status("Converting \(input.lastPathComponent)")
        let pages: Int
        switch input.studioKind {
        case .presentation:
            pages = try PresentationRenderer.render(input, to: output, title: input.studioStem) {
                run.progress($0)
            }
        case .spreadsheet:
            let sheets = try SpreadsheetReader.read(input)
            pages = try SpreadsheetRenderer.render(
                sheets, settings: run.settings, title: input.studioStem, to: output,
                headerRow: run.settings.values["headerRow"]?.bool ?? true
            ) { run.progress($0) }
        default:
            if WebTools.htmlToPDF.extraExtensions.contains(ext) {
                let setup = DocumentPageSetup.resolve(
                    run.settings, documentPaper: nil,
                    documentMargins: NSEdgeInsets(top: 36, left: 36, bottom: 36, right: 36))
                (_, pages, _) = try await WebTools.renderPDF(
                    input, width: 1024, paper: setup.paper, margin: setup.margins.left
                ) { _ in
                    output
                } progress: {
                    run.progress($0)
                }
            } else {
                let document = try await DocumentLoader.load(input)
                guard
                    !document.text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || document.text.containsAttachments(
                            in: NSRange(location: 0, length: document.text.length))
                else {
                    throw StudioError.nothingToDo("\(input.lastPathComponent) is empty.")
                }
                var sections =
                    document.sections ?? [
                        DocumentSection(
                            text: document.text,
                            setup: DocumentPageSetup(
                                paper: document.paperSize ?? StudioPaperSize.a4.points,
                                margins: document.margins
                                    ?? NSEdgeInsets(top: 72, left: 72, bottom: 72, right: 72)))
                    ]
                for index in sections.indices {
                    sections[index].setup = DocumentPageSetup.resolve(
                        run.settings,
                        documentPaper: document.sections == nil && document.paperSize == nil
                            ? nil : sections[index].setup.paper,
                        documentMargins: document.sections == nil && document.margins == nil
                            ? nil : sections[index].setup.margins)
                }
                pages = try TextPaginator.render(sections, title: input.studioStem, to: output) {
                    run.progress($0)
                }
            }
        }
        run.note("Created \(pages) page\(pages == 1 ? "" : "s").")
        return [output]
    }
}

public enum DocumentText {
    public static func markdown(_ url: URL) async throws -> String {
        switch url.studioKind {
        case .presentation:
            return PresentationRenderer.markdown(try PresentationRenderer.text(url))
        case .spreadsheet:
            return try SpreadsheetReader.read(url).map(markdownTable).joined(separator: "\n\n")
                + "\n"
        default:
            if ["txt", "text"].contains(url.pathExtension.lowercased()) {
                let raw = try DocumentLoader.readText(url)
                    .replacingOccurrences(of: "\r\n", with: "\n")
                return raw.hasSuffix("\n") ? raw : raw + "\n"
            }
            let document = try await DocumentLoader.load(url)
            return DocumentMarkdown.markdown(document.text)
        }
    }

    public static func plain(_ url: URL) async throws -> String {
        switch url.studioKind {
        case .presentation:
            return try PresentationRenderer.text(url).enumerated().map { index, slide in
                let heading =
                    "Slide \(index + 1)" + (slide.hidden ? " (hidden)" : "")
                    + (slide.title.map { ": \($0)" } ?? "")
                let notes =
                    slide.notes.map { ["Notes: " + $0.replacingOccurrences(of: "\n", with: " ")] }
                    ?? []
                return ([heading] + slide.lines + notes).joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        case .spreadsheet:
            return try SpreadsheetReader.read(url).map { sheet in
                ([sheet.name]
                    + sheet.rows.map { row in
                        row.map { cell in
                            cell.replacingOccurrences(of: "\r\n", with: " ")
                                .replacingOccurrences(of: "\n", with: " ")
                                .replacingOccurrences(of: "\t", with: " ")
                        }.joined(separator: "\t")
                    }).joined(separator: "\n")
            }.joined(separator: "\n\n") + "\n"
        default:
            let document = try await DocumentLoader.load(url)
            return DocumentMarkdown.plain(document.text)
        }
    }

    public static func paragraphs(_ url: URL) async throws -> [DocumentMarkdown.Block] {
        let document = try await DocumentLoader.load(url)
        return DocumentMarkdown.blocks(document.text)
    }

    static func markdownTable(_ sheet: SpreadsheetSheet) -> String {
        let rows = sheet.rows.filter { $0.contains { !$0.isEmpty } }
        let columns = max(1, rows.map(\.count).max() ?? 1)
        var lines = ["## " + sheet.name, ""]
        for (index, row) in rows.enumerated() {
            let cells = (0..<columns).map { column in
                column < row.count
                    ? row[column].replacingOccurrences(of: "|", with: "\\|")
                        .replacingOccurrences(of: "\r\n", with: "<br>")
                        .replacingOccurrences(of: "\n", with: "<br>") : ""
            }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 { lines.append("|" + String(repeating: " --- |", count: columns)) }
        }
        return lines.joined(separator: "\n")
    }
}

extension PresentationRenderer {
    public static func markdown(_ slides: [SlideText]) -> String {
        slides.enumerated().map { index, slide in
            var lines = [
                "## Slide \(index + 1)" + (slide.hidden ? " (hidden)" : "")
                    + (slide.title.map { ": \($0)" } ?? "")
            ]
            if !slide.lines.isEmpty {
                lines.append("")
                lines += slide.lines.map { "- " + $0.replacingOccurrences(of: "\n", with: " ") }
            }
            if let notes = slide.notes {
                lines.append("")
                lines.append("**Notes:** " + notes.replacingOccurrences(of: "\n", with: " "))
            }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }
}
