import AppKit
import EdithKit
import EdithStudio
import Observation

enum StudioImagePanel: String, CaseIterable, Identifiable {
    case crop
    case adjust
    case filters
    case text
    case draw
    case shapes
    case stickers
    case blur
    case frame
    case export

    var id: String { rawValue }

    var title: String {
        switch self {
        case .crop: "Crop & rotate"
        case .adjust: "Adjust"
        case .filters: "Filters"
        case .text: "Text"
        case .draw: "Draw"
        case .shapes: "Shapes"
        case .stickers: "Stickers"
        case .blur: "Blur & redact"
        case .frame: "Frame"
        case .export: "Size & format"
        }
    }

    var symbol: String {
        switch self {
        case .crop: "crop.rotate"
        case .adjust: "slider.horizontal.3"
        case .filters: "camera.filters"
        case .text: "textformat"
        case .draw: "scribble.variable"
        case .shapes: "square.on.circle"
        case .stickers: "face.smiling"
        case .blur: "eye.slash"
        case .frame: "square.dashed"
        case .export: "arrow.up.left.and.arrow.down.right"
        }
    }
}

struct StudioImageSource: @unchecked Sendable {
    let image: CGImage
}

@MainActor
@Observable
final class StudioImageEditorModel {
    let url: URL
    var document: ImageEditDocument
    var panel: StudioImagePanel = .adjust
    var preview: CGImage?
    var renderedDocument: ImageEditDocument?
    var savedDocument: ImageEditDocument?
    var geometry: CGImage?
    var selectedLayer: UUID?
    var loadError: String?
    var isSaving = false
    var status: String?
    var lastSaved: URL?
    var drawColor = "#FF3B30"
    var drawWidth = 0.01
    var highlighter = false
    var shapeKind: ImageShapeKind = .rectangle
    var shapeColor = "#FF3B30"
    var shapeFill = false
    var redactStyle: ImageRedactionStyle = .pixelate
    var redactStrength = 0.6
    var filterThumbnails: [ImageFilterPreset: CGImage] = [:]
    private(set) var source: StudioImageSource?
    private var undoStack: [ImageEditDocument] = []
    private var redoStack: [ImageEditDocument] = []
    private var renderTask: Task<Void, Never>?
    private var loadTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var thumbnailTask: Task<Void, Never>?
    private var faceTask: Task<Void, Never>?

    static let previewSize = 1800

    init(url: URL) {
        self.url = url
        document = ImageEditDocument(source: url)
    }

    var isRendering: Bool { preview == nil || renderedDocument != document }
    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var hasChanges: Bool { !document.isUnchanged }
    var hasUnsavedChanges: Bool { document != (savedDocument ?? ImageEditDocument(source: url)) }

    var canvasSize: CGSize {
        guard let preview else { return CGSize(width: 1, height: 1) }
        return CGSize(width: preview.width, height: preview.height)
    }

    var selected: ImageLayer? { selectedLayer.flatMap { document.layer($0) } }

    func load() {
        loadTask?.cancel()
        let url = self.url
        loadTask = Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) {
                StudioImageEditorWork.loadSource(
                    url, maxPixelSize: StudioImageEditorModel.previewSize)
            }.value
            guard let self, !Task.isCancelled else { return }
            switch loaded {
            case let .success(image):
                self.source = image
                self.render()
                self.renderThumbnails()
            case let .failure(error):
                self.loadError = error.localizedDescription
            }
        }
    }

    func edit(_ change: (inout ImageEditDocument) -> Void) {
        var next = document
        change(&next)
        guard next != document else { return }
        undoStack.append(document)
        if undoStack.count > 60 { undoStack.removeFirst() }
        redoStack.removeAll()
        document = next
        render()
    }

    func preview(_ change: (inout ImageEditDocument) -> Void) {
        change(&document)
        render(fast: true)
    }

    func commitPreview(from original: ImageEditDocument) {
        guard original != document else { return }
        undoStack.append(original)
        redoStack.removeAll()
        render()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(document)
        document = previous
        render()
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(document)
        document = next
        render()
    }

    func resetAll() {
        edit { $0 = ImageEditDocument(source: url) }
        selectedLayer = nil
    }

    func render(fast: Bool = false) {
        guard let source else { return }
        renderTask?.cancel()
        let document = self.document
        let size = fast ? 900 : Self.previewSize
        let wantsGeometry = panel == .crop
        renderTask = Task { [weak self] in
            let rendered = await Task.detached(priority: .userInitiated) {
                StudioImageEditorWork.render(
                    document, source: source, size: size, geometry: wantsGeometry)
            }.value
            guard let self, !Task.isCancelled else { return }
            switch rendered {
            case let .success(images):
                self.preview = images.preview
                self.renderedDocument = document
                if let geometry = images.geometry { self.geometry = geometry }
                self.loadError = nil
            case let .failure(error):
                self.status = error.localizedDescription
            }
        }
    }

    func switchPanel(_ next: StudioImagePanel) {
        panel = next
        if next == .crop { render() }
    }

    func renderThumbnails() {
        guard let source else { return }
        thumbnailTask?.cancel()
        let document = self.document
        thumbnailTask = Task { [weak self] in
            let thumbnails = await Task.detached(priority: .utility) {
                StudioImageEditorWork.filterThumbnails(document, source: source)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.filterThumbnails = thumbnails
        }
    }

    func addText(at point: CGPoint? = nil, text: String = "Your text") {
        let center = point ?? CGPoint(x: 0.5, y: 0.5)
        let frame = StudioRect(
            x: min(max(center.x - 0.3, 0), 0.4), y: min(max(center.y - 0.06, 0), 0.88), width: 0.6,
            height: 0.12)
        let layer = ImageLayer.text(text, at: frame)
        edit { $0.add(layer) }
        selectedLayer = layer.id
    }

    func addMeme() {
        var top = ImageTextStyle(
            text: "TOP TEXT", font: "Impact", size: 0.1, strokeColor: "#000000", strokeWidth: 3)
        top.alignment = .center
        var bottom = top
        bottom.text = "BOTTOM TEXT"
        let topLayer = ImageLayer(
            content: .text(top), frame: StudioRect(x: 0.04, y: 0.02, width: 0.92, height: 0.18))
        let bottomLayer = ImageLayer(
            content: .text(bottom), frame: StudioRect(x: 0.04, y: 0.8, width: 0.92, height: 0.18))
        edit { document in
            document.add(topLayer)
            document.add(bottomLayer)
        }
        selectedLayer = topLayer.id
    }

    func addSticker(_ value: String) {
        let aspect = canvasSize.width / max(canvasSize.height, 1)
        let height = 0.18
        let width = height / aspect
        let layer = ImageLayer(
            content: .sticker(value),
            frame: StudioRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height)
        )
        edit { $0.add(layer) }
        selectedLayer = layer.id
    }

    func addImageLayer() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let file = panel.url, let info = StudioImageIO.info(file)
        else { return }
        let aspect =
            (Double(info.width) / Double(max(info.height, 1)))
            / (canvasSize.width / max(canvasSize.height, 1))
        let width = 0.35
        let height = min(0.9, width / aspect)
        let layer = ImageLayer(
            content: .image(path: file.path),
            frame: StudioRect(x: 0.5 - width / 2, y: 0.5 - height / 2, width: width, height: height)
        )
        edit { $0.add(layer) }
        selectedLayer = layer.id
    }

    func addStroke(_ points: [CGPoint]) {
        let normalized = points.map { ImagePoint(x: $0.x, y: $0.y) }
        guard
            let layer = ImageLayer.drawing(
                canvasStrokes: [normalized], color: drawColor, width: drawWidth,
                highlighter: highlighter)
        else { return }
        edit { $0.add(layer) }
    }

    func addShape(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
            height: abs(end.y - start.y))
        guard rect.width > 0.005 || rect.height > 0.005 else { return }
        let frame = StudioRect(
            x: rect.minX, y: rect.minY, width: max(rect.width, 0.002),
            height: max(rect.height, 0.002))
        let localStart = ImagePoint(
            x: rect.width > 0 ? (start.x - rect.minX) / rect.width : 0,
            y: rect.height > 0 ? (start.y - rect.minY) / rect.height : 0)
        let localEnd = ImagePoint(
            x: rect.width > 0 ? (end.x - rect.minX) / rect.width : 1,
            y: rect.height > 0 ? (end.y - rect.minY) / rect.height : 1)
        let style = ImageShapeStyle(
            shape: shapeKind, strokeColor: shapeColor,
            fillColor: shapeFill ? shapeColor + "55" : nil,
            start: localStart, end: localEnd)
        let layer = ImageLayer(content: .shape(style), frame: frame)
        edit { $0.add(layer) }
        selectedLayer = layer.id
    }

    func addRedaction(from start: CGPoint, to end: CGPoint) {
        let rect = CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x),
            height: abs(end.y - start.y))
        guard rect.width > 0.01, rect.height > 0.01 else { return }
        let layer = ImageLayer(
            content: .redaction(ImageRedaction(style: redactStyle, strength: redactStrength)),
            frame: StudioRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        edit { $0.add(layer) }
        selectedLayer = layer.id
    }

    func blurFaces() {
        guard let preview else { return }
        faceTask?.cancel()
        let style = redactStyle
        let strength = redactStrength
        let image = StudioImageSource(image: preview)
        faceTask = Task { [weak self] in
            let faces = await Task.detached(priority: .userInitiated) {
                StudioImageEditorWork.faces(in: image)
            }.value
            guard let self, !Task.isCancelled else { return }
            guard !faces.isEmpty else {
                self.status = "No faces found in this picture."
                return
            }
            self.edit { document in
                for face in faces {
                    document.add(
                        ImageLayer(
                            content: .redaction(ImageRedaction(style: style, strength: strength)),
                            frame: face))
                }
            }
            self.status = "Blurred \(faces.count) face\(faces.count == 1 ? "" : "s")."
        }
    }

    func updateSelected(_ change: (inout ImageLayer) -> Void) {
        guard let selectedLayer else { return }
        edit { $0.updateLayer(selectedLayer, change) }
    }

    func deleteSelected() {
        guard let selectedLayer else { return }
        edit { $0.removeLayer(selectedLayer) }
        self.selectedLayer = nil
    }

    func save(to destination: URL? = nil, studio: StudioModel) {
        guard !isSaving else { return }
        saveTask?.cancel()
        let document = self.document
        let format = document.outputFormat
        let target =
            destination
            ?? StudioImageEditorWork.defaultOutput(
                for: url, ext: format.fileExtension, destination: studio.destination)
        isSaving = true
        saveTask = Task { [weak self] in
            let failure = await Task.detached(priority: .userInitiated) {
                StudioImageEditorWork.export(document, to: target)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.isSaving = false
            if let failure {
                self.status = failure
                return
            }
            self.lastSaved = target
            self.savedDocument = document
            self.status = "Saved \(target.lastPathComponent)"
            studio.add([target])
            studio.recordSaved(toolID: "image.edit", title: "Image editor", outputs: [target])
        }
    }

    func saveAs(studio: StudioModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [document.outputFormat.utType]
        panel.nameFieldStringValue =
            url.studioStem + "-edited." + document.outputFormat.fileExtension
        guard panel.runModal() == .OK, let target = panel.url else { return }
        save(to: target, studio: studio)
    }
}

enum StudioImageEditorWork {
    struct Rendered: @unchecked Sendable {
        let preview: CGImage
        let geometry: CGImage?
    }

    static func loadSource(_ url: URL, maxPixelSize: Int) -> Result<StudioImageSource, Error> {
        do {
            return .success(
                StudioImageSource(image: try StudioImageIO.load(url, maxPixelSize: maxPixelSize)))
        } catch {
            return .failure(error)
        }
    }

    static func render(
        _ document: ImageEditDocument, source: StudioImageSource, size: Int, geometry: Bool
    ) -> Result<Rendered, Error> {
        do {
            let preview = try ImageEditRenderer.render(
                document: document, source: source.image, maxPixelSize: size)
            let uncropped =
                geometry
                ? try ImageEditRenderer.geometryPreview(
                    document: document, source: source.image, maxPixelSize: size)
                : nil
            return .success(Rendered(preview: preview, geometry: uncropped))
        } catch {
            return .failure(error)
        }
    }

    static func filterThumbnails(
        _ document: ImageEditDocument, source: StudioImageSource
    ) -> [ImageFilterPreset: CGImage] {
        let small = StudioImageOps.fitted(source.image, maxDimension: 160)
        var result: [ImageFilterPreset: CGImage] = [:]
        for preset in ImageFilterPreset.allCases {
            if let image = try? ImageEditRenderer.adjust(
                small, adjustments: ImageAdjustments(), filter: preset, intensity: 1)
            {
                result[preset] = image
            }
        }
        return result
    }

    static func faces(in image: StudioImageSource) -> [StudioRect] {
        let size = CGSize(width: image.image.width, height: image.image.height)
        let boxes = (try? StudioVision.faces(in: image.image)) ?? []
        return boxes.map { box in
            let pixel = StudioVision.pixelRect(box, in: size, expandedBy: 0.18)
            return StudioRect(
                x: pixel.minX / size.width, y: 1 - pixel.maxY / size.height,
                width: pixel.width / size.width,
                height: pixel.height / size.height
            ).clamped
        }
    }

    static func defaultOutput(for url: URL, ext: String, destination: StudioDestination) -> URL {
        let directory =
            (try? StudioRunner.destinationDirectory(destination, for: url))
            ?? url.deletingLastPathComponent()
        return StudioNaming.unique(
            directory.appendingPathComponent("\(url.studioStem)-edited.\(ext)"))
    }

    static func export(_ document: ImageEditDocument, to url: URL) -> String? {
        do {
            try ImageEditRenderer.export(document: document, to: url)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
