import AppKit
import EdithKit
import EdithStudio
import Observation
import PDFKit

enum StudioPDFTool: String, CaseIterable, Identifiable {
    case select
    case fill
    case text
    case draw
    case highlight
    case underline
    case strike
    case rectangle
    case ellipse
    case line
    case arrow
    case note
    case image
    case signature
    case redact
    case crop
    case textField
    case checkbox
    case dropdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .select: "Select"
        case .fill: "Fill"
        case .text: "Text"
        case .draw: "Draw"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strike: "Strike out"
        case .rectangle: "Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .note: "Note"
        case .image: "Image"
        case .signature: "Signature"
        case .redact: "Redact"
        case .crop: "Crop"
        case .textField: "Text field"
        case .checkbox: "Checkbox"
        case .dropdown: "Dropdown"
        }
    }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .fill: "character.cursor.ibeam"
        case .text: "textformat"
        case .draw: "scribble.variable"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strike: "strikethrough"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .note: "note.text"
        case .image: "photo"
        case .signature: "signature"
        case .redact: "rectangle.fill"
        case .crop: "crop"
        case .textField: "character.textbox"
        case .checkbox: "checkmark.square"
        case .dropdown: "filemenu.and.selection"
        }
    }

    var isDragTool: Bool {
        switch self {
        case .rectangle, .ellipse, .line, .arrow, .redact, .crop, .textField, .checkbox, .dropdown,
            .draw:
            true
        default:
            false
        }
    }

    var isMarkup: Bool { self == .highlight || self == .underline || self == .strike }

    static func tools(for mode: StudioPDFEditorMode) -> [StudioPDFTool] {
        switch mode {
        case .annotate:
            [
                .select, .text, .draw, .highlight, .underline, .strike, .rectangle, .ellipse, .line,
                .arrow, .note, .image,
            ]
        case .sign: [.signature, .text, .select]
        case .redact: [.redact, .select]
        case .forms: [.fill, .select, .textField, .checkbox, .dropdown]
        case .crop: [.crop]
        case .organize: []
        }
    }
}

extension StudioPDFEditorMode {
    var title: String {
        switch self {
        case .organize: "Organize"
        case .annotate: "Edit"
        case .sign: "Sign"
        case .redact: "Redact"
        case .forms: "Forms"
        case .crop: "Crop"
        }
    }

    var suffix: String {
        switch self {
        case .organize: "organized"
        case .annotate: "edited"
        case .sign: "signed"
        case .redact: "redacted"
        case .forms: "form"
        case .crop: "cropped"
        }
    }
}

@MainActor
@Observable
final class StudioPDFEditorModel {
    let url: URL
    var mode: StudioPDFEditorMode
    var tool: StudioPDFTool
    var session: PDFEditSession?
    var loadError: String?
    var needsPassword = false
    var password = ""
    var currentPage = 0
    var revision = 0
    var selected: PDFAnnotation?
    var pageSelection: Set<Int> = []
    var style = PDFEditSession.Style()
    var pendingText = "Text"
    var pendingImage: CGImage?
    var pendingImageName: String?
    var redactTerms = ""
    var redactEmails = true
    var redactPhones = true
    var redactCards = false
    var dropdownOptions = "Option 1, Option 2, Option 3"
    var cropRect: CGRect?
    var isSaving = false
    var saveProgress = 0.0
    var lastSaved: URL?
    var status: String?
    var signatures: [StudioSavedSignature] = []
    weak var pdfView: PDFView?
    private var undoStack: [PDFEditSession.Snapshot] = []
    private var redoStack: [PDFEditSession.Snapshot] = []
    private var saveTask: Task<Void, Never>?
    private var signaturesTask: Task<Void, Never>?

    init(url: URL, mode: StudioPDFEditorMode) {
        self.url = url
        self.mode = mode
        tool = StudioPDFTool.tools(for: mode).first ?? .select
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { session?.isDirty ?? false }
    var pageCount: Int { session?.pageCount ?? 0 }

    func load() {
        do {
            session = try PDFEditSession(url: url, password: password.isEmpty ? nil : password)
            needsPassword = false
            loadError = nil
            revision += 1
        } catch let error as StudioError {
            switch error {
            case .needsPassword, .wrongPassword: needsPassword = true
            default: loadError = error.localizedDescription
            }
            if case .wrongPassword = error { status = "That password did not work." }
        } catch {
            loadError = error.localizedDescription
        }
        loadSignatures()
    }

    func switchMode(_ next: StudioPDFEditorMode) {
        mode = next
        tool = StudioPDFTool.tools(for: next).first ?? .select
        selected = nil
        cropRect = nil
    }

    func mutate(_ change: (PDFEditSession) throws -> Void) {
        guard let session else { return }
        let before = session.snapshot()
        do {
            try change(session)
            if let before { undoStack.append(before) }
            if undoStack.count > 30 { undoStack.removeFirst() }
            redoStack.removeAll()
            revision += 1
        } catch {
            status = error.localizedDescription
        }
    }

    func undo() {
        guard let session, let previous = undoStack.popLast() else { return }
        if let current = session.snapshot() { redoStack.append(current) }
        session.restore(previous)
        selected = nil
        revision += 1
    }

    func redo() {
        guard let session, let next = redoStack.popLast() else { return }
        if let current = session.snapshot() { undoStack.append(current) }
        session.restore(next)
        selected = nil
        revision += 1
    }

    func click(at point: CGPoint, page: Int) {
        switch tool {
        case .text:
            let text = pendingText.isEmpty ? "Text" : pendingText
            let bounds = PDFEditSession.textBounds(text, at: point, style: style)
            var created: PDFAnnotation?
            mutate { created = $0.addText(text, in: bounds, page: page, style: style) }
            selected = created
        case .note:
            mutate { $0.addNote(pendingText, at: point, page: page, color: style.color) }
        case .image, .signature:
            guard let image = pendingImage else {
                status =
                    tool == .signature
                    ? "Create or pick a signature first." : "Choose an image first."
                return
            }
            let width = tool == .signature ? 180.0 : 220.0
            let height = width * Double(image.height) / Double(max(image.width, 1))
            let rect = CGRect(
                x: point.x - width / 2, y: point.y - height / 2, width: width, height: height)
            mutate { _ = $0.place(image, in: rect, page: page) }
        default:
            break
        }
    }

    func drag(from start: CGPoint, to end: CGPoint, page: Int) {
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
            height: abs(end.y - start.y))
        switch tool {
        case .rectangle:
            mutate { $0.addShape(.rectangle, from: start, to: end, page: page, style: style) }
        case .ellipse:
            mutate { $0.addShape(.ellipse, from: start, to: end, page: page, style: style) }
        case .line: mutate { $0.addShape(.line, from: start, to: end, page: page, style: style) }
        case .arrow: mutate { $0.addShape(.arrow, from: start, to: end, page: page, style: style) }
        case .redact: mutate { $0.markRedaction(rect, page: page) }
        case .crop: cropRect = rect.width > 8 && rect.height > 8 ? rect : nil
        case .textField:
            guard rect.width > 6 else { return }
            mutate { session in
                session.addField(
                    .text(multiline: rect.height > 40), in: rect, page: page,
                    name: session.nextFieldName())
            }
        case .checkbox:
            let side = max(12, min(rect.width, rect.height))
            let box = CGRect(x: rect.minX, y: rect.minY, width: side, height: side)
            mutate { session in
                session.addField(
                    .checkbox, in: box, page: page, name: session.nextFieldName(prefix: "Check"))
            }
        case .dropdown:
            guard rect.width > 6 else { return }
            let options = StudioPDFEditorText.options(dropdownOptions)
            mutate { session in
                session.addField(
                    .choice(options), in: rect, page: page,
                    name: session.nextFieldName(prefix: "Choice"))
            }
        case .image, .signature:
            guard let image = pendingImage, rect.width > 8, rect.height > 8 else {
                click(at: start, page: page)
                return
            }
            mutate { _ = $0.place(image, in: rect, page: page) }
        default:
            break
        }
    }

    func ink(_ points: [CGPoint], page: Int) {
        guard points.count > 1 else { return }
        mutate { $0.addInk([points], page: page, style: style) }
    }

    func markup(_ selection: PDFSelection) {
        let markup: PDFEditSession.Markup =
            switch tool {
            case .underline: .underline
            case .strike: .strikeOut
            default: .highlight
            }
        let color = tool == .highlight ? StudioColor(red: 1, green: 0.85, blue: 0.1) : style.color
        mutate { _ = $0.addMarkup(markup, for: selection, color: color) }
    }

    func moveSelected(to bounds: CGRect) {
        guard let selected else { return }
        mutate { $0.move(selected, to: bounds) }
    }

    func deleteSelected() {
        guard let selected else { return }
        mutate { $0.remove(selected) }
        self.selected = nil
    }

    func updateSelectedText(_ text: String) {
        guard let selected, selected.type == "FreeText" else { return }
        selected.contents = text
        session.map { _ in revision += 1 }
    }

    func applyStyleToSelection() {
        guard let selected else { return }
        mutate { _ in
            let color = NSColor(cgColor: style.color.cgColor) ?? .red
            if selected.type == "FreeText" {
                selected.fontColor = color
                selected.font =
                    NSFont(name: style.fontName, size: style.fontSize)
                    ?? NSFont.systemFont(ofSize: style.fontSize)
            } else {
                selected.color = color
                let border = selected.border ?? PDFBorder()
                border.lineWidth = style.lineWidth
                selected.border = border
            }
        }
    }

    func findRedactions() {
        var patterns: [PDFRedaction.Pattern] = []
        if redactEmails { patterns.append(.email) }
        if redactPhones { patterns.append(.phone) }
        if redactCards { patterns.append(.card) }
        let terms = PDFRedaction.terms(from: redactTerms)
        var found = 0
        mutate { found = $0.markRedactions(terms: terms, patterns: patterns) }
        status =
            found == 0 ? "No matches found." : "Marked \(found) match\(found == 1 ? "" : "es")."
    }

    func applyCrop(toAllPages: Bool) {
        guard let cropRect else { return }
        let pages = toAllPages ? Array(0..<pageCount) : [currentPage]
        mutate { $0.crop(pages: pages, to: cropRect) }
        self.cropRect = nil
    }

    func trimAllMargins() {
        var trimmed = 0
        mutate { trimmed = try $0.trimMargins(pages: Array(0..<pageCount)) }
        status =
            trimmed == 0
            ? "No white margins to trim." : "Trimmed \(trimmed) page\(trimmed == 1 ? "" : "s")."
    }

    func detectFields() {
        var created = 0
        mutate { created = $0.detectFormFields() }
        status =
            created == 0
            ? "No blanks or boxes found to turn into fields."
            : "Added \(created) field\(created == 1 ? "" : "s")."
    }

    func rotate(_ pages: [Int], by degrees: Int) {
        mutate { $0.rotatePages(pages, by: degrees) }
    }

    func delete(_ pages: Set<Int>) {
        mutate { try $0.deletePages(pages) }
        pageSelection.removeAll()
    }

    func duplicate(_ page: Int) {
        mutate { $0.duplicatePage(page) }
    }

    func move(_ page: Int, to target: Int) {
        mutate { $0.movePage(from: page, to: target) }
    }

    func insertBlank(after page: Int) {
        mutate { $0.insertBlankPage(at: page + 1) }
    }

    func insertFile(after page: Int) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.message = "Choose a PDF or image to insert."
        guard panel.runModal() == .OK, let file = panel.url else { return }
        mutate { _ = try $0.insertPages(from: file, at: page + 1) }
    }

    func extract(_ pages: Set<Int>) {
        guard let session, !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.studioStem + "-pages.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        do {
            try session.extractPages(Array(pages), to: target)
            status =
                "Saved \(pages.count) page\(pages.count == 1 ? "" : "s") to \(target.lastPathComponent)."
        } catch {
            status = error.localizedDescription
        }
    }

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let file = panel.url else { return }
        do {
            pendingImage = try StudioImageIO.load(file, maxPixelSize: 2400)
            pendingImageName = file.lastPathComponent
            tool = .image
        } catch {
            status = error.localizedDescription
        }
    }

    func useSignature(_ signature: StudioSavedSignature) {
        pendingImage = signature.image
        pendingImageName = signature.name
        tool = .signature
    }

    func loadSignatures() {
        signaturesTask?.cancel()
        signaturesTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { StudioSignatureStore.load() }
                .value
            guard let self, !Task.isCancelled else { return }
            self.signatures = loaded
        }
    }

    func saveSignature(_ image: CGImage) {
        do {
            let saved = try StudioSignatureStore.save(image)
            signatures.insert(saved, at: 0)
            useSignature(saved)
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteSignature(_ signature: StudioSavedSignature) {
        try? FileManager.default.removeItem(at: signature.url)
        signatures.removeAll { $0.url == signature.url }
        if pendingImageName == signature.name { pendingImage = nil }
    }

    func save(to destination: URL? = nil, studio: StudioModel) {
        guard let session, !isSaving else { return }
        saveTask?.cancel()
        guard let snapshot = session.snapshot() else {
            status = "The PDF could not be prepared for saving."
            return
        }
        let target =
            destination
            ?? StudioPDFEditorText.defaultOutput(
                for: url, suffix: mode.suffix, destination: studio.destination)
        let source = url
        let flatten = mode == .sign
        isSaving = true
        saveProgress = 0
        saveTask = Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                StudioPDFEditorText.export(snapshot, source: source, to: target, flatten: flatten)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isSaving = false
            if let failure {
                self.status = failure
                return
            }
            session.markSaved()
            self.lastSaved = target
            self.status = "Saved \(target.lastPathComponent)"
            studio.add([target])
            studio.recordSaved(
                toolID: "pdf.\(self.mode.rawValue)", title: "PDF editor", outputs: [target])
        }
    }

    func saveAs(studio: StudioModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.studioStem + "-\(mode.suffix).pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        save(to: target, studio: studio)
    }

    func zoom(_ factor: CGFloat) {
        guard let pdfView else { return }
        pdfView.autoScales = false
        pdfView.scaleFactor = min(max(pdfView.scaleFactor * factor, 0.2), 6)
    }

    func zoomToFit() {
        pdfView?.autoScales = true
    }

    func go(to page: Int) {
        guard let pdfPage = session?.page(page) else { return }
        pdfView?.go(to: pdfPage)
    }
}

struct StudioSavedSignature: Identifiable, @unchecked Sendable {
    let url: URL
    let image: CGImage

    var id: URL { url }
    var name: String { url.deletingPathExtension().lastPathComponent }
}

enum StudioSignatureStore {
    static func load() -> [StudioSavedSignature] {
        let folder = StudioLibraryStore.signatures
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return [] }
        return files.filter { $0.pathExtension == "png" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { file in
                (try? StudioImageIO.load(file)).map { StudioSavedSignature(url: file, image: $0) }
            }
    }

    static func save(_ image: CGImage) throws -> StudioSavedSignature {
        let folder = StudioLibraryStore.signatures
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
            of: ":", with: "-")
        let file = StudioNaming.unique(folder.appendingPathComponent("Signature \(stamp).png"))
        try StudioImageIO.write(image, to: file, format: .png)
        return StudioSavedSignature(url: file, image: image)
    }
}

enum StudioPDFEditorText {
    static func options(_ raw: String) -> [String] {
        let parsed = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let options = parsed.filter { !$0.isEmpty }
        return options.isEmpty ? ["Option 1"] : options
    }

    static func defaultOutput(for url: URL, suffix: String, destination: StudioDestination) -> URL {
        let directory =
            (try? StudioRunner.destinationDirectory(destination, for: url))
            ?? url.deletingLastPathComponent()
        return StudioNaming.unique(
            directory.appendingPathComponent("\(url.studioStem)-\(suffix).pdf"))
    }

    static func export(
        _ snapshot: PDFEditSession.Snapshot, source: URL, to target: URL, flatten: Bool
    ) -> String? {
        guard let session = PDFEditSession(snapshot: snapshot, source: source) else {
            return "The PDF could not be prepared for saving."
        }
        do {
            try session.export(to: target, flatten: flatten)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
