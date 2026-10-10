import AppKit
import EdithExtensionSupport
import EdithExtensionUI
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
    private struct LoadedSession: @unchecked Sendable {
        let session: PDFEditSession
    }
    let url: URL
    let facade: StudioUIFacade?
    var isWorking = false
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
    private var mutationTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    let loading = ContentLoad()

    init(url: URL, mode: StudioPDFEditorMode, facade: StudioUIFacade? = nil) {
        self.url = url
        self.facade = facade
        self.mode = mode
        tool = StudioPDFTool.tools(for: mode).first ?? .select
    }

    var redactionCount: Int {
        _ = revision
        return session?.redactionCount ?? 0
    }

    var selectedRedaction: PDFAnnotation? {
        guard let selected, selected.userName == PDFEditSession.redactionMarker else { return nil }
        return selected
    }

    func clearRedactions() {
        mutate { $0.clearRedactions() }
        selected = nil
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var isDirty: Bool { session?.isDirty ?? false }
    var pageCount: Int { session?.pageCount ?? 0 }

    func load() {
        loadTask?.cancel()
        let generation = loading.begin(preservingContent: session != nil)
        let url = url
        let password = password.isEmpty ? nil : password
        loadTask = Task { [weak self] in
            do {
                let loaded: LoadedSession
                if let facade = self?.facade {
                    var object: [String: Any] = ["path": url.path]
                    if let password { object["password"] = password }
                    let reply: StudioUIPDFLoad = try await facade.read(
                        "studio.ui.pdf.load", object: object)
                    guard let self, self.loading.isCurrent(generation) else { return }
                    if let handle = reply.resource {
                        let snapshot: PDFEditSession.Snapshot = try await facade.download(handle)
                        guard let session = PDFEditSession(snapshot: snapshot, source: url) else {
                            throw StudioError.unreadable(url.lastPathComponent)
                        }
                        loaded = LoadedSession(session: session)
                    } else {
                        self.needsPassword = reply.needsPassword
                        self.loadError = reply.needsPassword ? nil : reply.failure
                        if reply.wrongPassword { self.status = "That password did not work." }
                        self.loading.fail(
                            generation,
                            error: StudioUIOperationFailure(
                                message: reply.failure ?? "The PDF could not be opened."))
                        return
                    }
                } else {
                    loaded = try await Task.detached(priority: .userInitiated) {
                        LoadedSession(session: try PDFEditSession(url: url, password: password))
                    }.value
                }
                guard let self, self.loading.isCurrent(generation) else { return }
                self.session = loaded.session
                self.needsPassword = false
                self.loadError = nil
                self.revision += 1
                self.loading.complete(generation)
            } catch {
                guard let self, self.loading.owns(generation) else { return }
                self.loading.fail(generation, error: error)
                if let error = error as? StudioError {
                    switch error {
                    case .needsPassword, .wrongPassword: self.needsPassword = true
                    default: self.loadError = error.localizedDescription
                    }
                    if case .wrongPassword = error { self.status = "That password did not work." }
                } else {
                    self.loadError = error.localizedDescription
                }
            }
        }
        loadSignatures()
    }

    func cancelLoading() {
        loading.cancel()
        loadTask?.cancel()
        loadTask = nil
        signaturesTask?.cancel()
        signaturesTask = nil
        mutationTask?.cancel()
        saveTask?.cancel()
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
            tool = .select
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
            placeImage(image, in: rect, page: page)
        default:
            break
        }
    }

    private func placeImage(_ image: CGImage, in rect: CGRect, page: Int) {
        mutate { session in
            guard session.place(image, in: rect, page: page) != nil else { return }
            selected = session.page(page)?.annotations.last
        }
        tool = .select
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
        case .redact:
            var created: PDFAnnotation?
            mutate { created = $0.markRedaction(rect, page: page) }
            selected = created
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
            placeImage(image, in: rect, page: page)
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
        if facade != nil {
            remoteChange(
                "redactions",
                parameters: [
                    "terms": redactTerms, "emails": redactEmails, "phones": redactPhones,
                    "cards": redactCards,
                ]);
            return
        }
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
        if facade != nil { remoteChange("trim", parameters: [:]); return }
        var trimmed = 0
        mutate { trimmed = try $0.trimMargins(pages: Array(0..<pageCount)) }
        status =
            trimmed == 0
            ? "No white margins to trim." : "Trimmed \(trimmed) page\(trimmed == 1 ? "" : "s")."
    }

    func detectFields() {
        if facade != nil { remoteChange("fields", parameters: [:]); return }
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
        if facade != nil {
            remoteChange("insert", parameters: ["file": file.path, "page": page + 1]); return
        }
        mutate { _ = try $0.insertPages(from: file, at: page + 1) }
    }

    func extract(_ pages: Set<Int>) {
        guard let session, !pages.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = url.studioStem + "-pages.pdf"
        guard panel.runModal() == .OK, let target = panel.url else { return }
        if facade != nil {
            remoteChange(
                "extract", parameters: ["pages": Array(pages).sorted(), "output": target.path]);
            return
        }
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
        if let facade {
            mutationTask?.cancel()
            mutationTask = Task { [weak self] in
                do {
                    let handle: StudioUIResource = try await facade.read(
                        "studio.ui.image.load", object: ["path": file.path, "size": 2400])
                    let value: StudioUIImageData = try await facade.download(handle)
                    guard let self, !Task.isCancelled, let image = value.image else { return }
                    self.pendingImage = image; self.pendingImageName = file.lastPathComponent;
                    self.tool = .image
                } catch { if !Task.isCancelled { self?.status = error.localizedDescription } }
            }
            return
        }
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
            if let facade = self?.facade {
                do {
                    let handle: StudioUIResource = try await facade.read(
                        "studio.ui.pdf.signatures.list")
                    let values: [StudioUISignature] = try await facade.download(handle)
                    guard let self, !Task.isCancelled else { return }
                    self.signatures = values.compactMap { value in
                        value.image.image.map { StudioSavedSignature(url: value.url, image: $0) }
                    }
                } catch { if !Task.isCancelled { self?.status = error.localizedDescription } }
                return
            }
            let loaded = await Task.detached(priority: .utility) { StudioSignatureStore.load() }
                .value
            guard let self, !Task.isCancelled else { return }
            self.signatures = loaded
        }
    }

    func saveSignature(_ image: CGImage) {
        if let facade {
            mutationTask?.cancel()
            mutationTask = Task { [weak self] in
                do {
                    let handle = try await facade.upload(StudioUIImageData(image))
                    let value: StudioUISignature = try await facade.read(
                        "studio.ui.pdf.signatures.save",
                        object: ["image": try facade.object(handle)])
                    guard let self, !Task.isCancelled, let pixels = value.image.image else {
                        return
                    }
                    let saved = StudioSavedSignature(url: value.url, image: pixels)
                    self.signatures.insert(saved, at: 0); self.useSignature(saved)
                } catch { if !Task.isCancelled { self?.status = error.localizedDescription } }
            }
            return
        }

        do {
            let saved = try StudioSignatureStore.save(image)
            signatures.insert(saved, at: 0)
            useSignature(saved)
        } catch {
            status = error.localizedDescription
        }
    }

    func deleteSignature(_ signature: StudioSavedSignature) {
        if let facade {
            mutationTask?.cancel()
            mutationTask = Task { [weak self] in
                do {
                    let _: [String: String] = try await facade.read(
                        "studio.ui.pdf.signatures.remove", object: ["path": signature.url.path])
                    guard !Task.isCancelled else { return }; self?.loadSignatures()
                } catch { if !Task.isCancelled { self?.status = error.localizedDescription } }
            }
            return
        }

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
        if let facade {
            isSaving = true; saveProgress = 0
            saveTask = Task { [weak self] in
                do {
                    let handle = try await facade.upload(snapshot)
                    var object: [String: Any] = [
                        "path": self?.url.path ?? session.source.path,
                        "snapshot": try facade.object(handle),
                        "suffix": self?.mode.suffix ?? "edited", "flatten": self?.mode == .sign,
                    ]
                    if let destination { object["output"] = destination.path }
                    let target: URL = try await facade.perform(
                        "studio.ui.pdf.export", object: object
                    ) { [weak self] in self?.saveProgress = $0 }
                    guard let self, !Task.isCancelled else { return }
                    self.isSaving = false; session.markSaved(); self.lastSaved = target
                    self.status = "Saved \(target.lastPathComponent)"; facade.refresh()
                } catch {
                    guard let self, !Task.isCancelled else { return }
                    self.isSaving = false; self.status = error.localizedDescription
                }
            }
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
            let failure = await StudioPDFEditorText.export(
                snapshot, source: source, to: target, flatten: flatten)
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

    private func remoteChange(_ action: String, parameters: [String: Any]) {
        guard !isWorking, let facade, let session, let snapshot = session.snapshot() else { return }
        let version = revision
        isWorking = true
        mutationTask = Task { [weak self] in
            defer { self?.isWorking = false }
            do {
                let uploaded = try await facade.upload(snapshot)
                let handle: StudioUIResource = try await facade.perform(
                    "studio.ui.pdf.change",
                    object: [
                        "path": session.source.path, "snapshot": try facade.object(uploaded),
                        "action": action, "parameters": parameters,
                    ])
                let value: StudioUIPDFChange = try await facade.download(handle)
                guard let self, !Task.isCancelled, self.revision == version else { return }
                self.undoStack.append(snapshot); self.redoStack.removeAll()
                session.restore(value.snapshot); self.revision += 1; self.selected = nil
                if let status = value.status { self.status = status }
            } catch { if !Task.isCancelled { self?.status = error.localizedDescription } }
        }
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
    ) async -> String? {
        guard let session = PDFEditSession(snapshot: snapshot, source: source) else {
            return "The PDF could not be prepared for saving."
        }
        do {
            try await session.export(to: target, flatten: flatten)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
