import AppKit
import EdithStudio
import PDFKit
import SwiftUI

struct StudioPDFCanvas: NSViewRepresentable {
    let editor: StudioPDFEditorModel
    let showsThumbnails: Bool

    func makeCoordinator() -> Coordinator { Coordinator(editor: editor) }

    func makeNSView(context: Context) -> StudioPDFCanvasContainer {
        let container = StudioPDFCanvasContainer()
        container.canvas.coordinator = context.coordinator
        container.canvas.document = editor.session?.document
        editor.pdfView = container.canvas
        context.coordinator.observe(container.canvas)
        container.setThumbnailsVisible(showsThumbnails)
        return container
    }

    func updateNSView(_ container: StudioPDFCanvasContainer, context: Context) {
        let canvas = container.canvas
        context.coordinator.editor = editor
        if canvas.document !== editor.session?.document {
            canvas.document = editor.session?.document
            editor.pdfView = canvas
        }
        canvas.tool = editor.tool
        canvas.selectedAnnotation = editor.selected
        canvas.cropRect = editor.cropRect
        canvas.cropPage = editor.session?.page(editor.currentPage)
        if context.coordinator.revision != editor.revision {
            context.coordinator.revision = editor.revision
            canvas.layoutDocumentView()
            canvas.needsDisplay = true
            canvas.documentView?.needsDisplay = true
        }
        canvas.overlay.needsDisplay = true
        container.setThumbnailsVisible(showsThumbnails)
    }

    @MainActor
    final class Coordinator: NSObject {
        var editor: StudioPDFEditorModel
        var revision = -1
        private var observer: NSObjectProtocol?

        init(editor: StudioPDFEditorModel) {
            self.editor = editor
        }

        func observe(_ view: PDFView) {
            observer = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self, weak view] _ in
                MainActor.assumeIsolated {
                    guard let self, let view, let page = view.currentPage,
                        let document = view.document
                    else { return }
                    let index = document.index(for: page)
                    if index != NSNotFound { self.editor.currentPage = index }
                }
            }
        }

        func pageIndex(_ page: PDFPage) -> Int? {
            editor.session?.index(of: page)
        }

        func select(_ annotation: PDFAnnotation?) { editor.selected = annotation }
        func click(at point: CGPoint, page: PDFPage) {
            guard let index = pageIndex(page) else { return }
            editor.currentPage = index
            editor.click(at: point, page: index)
        }
        func drag(from start: CGPoint, to end: CGPoint, page: PDFPage) {
            guard let index = pageIndex(page) else { return }
            editor.currentPage = index
            editor.drag(from: start, to: end, page: index)
        }
        func ink(_ points: [CGPoint], page: PDFPage) {
            guard let index = pageIndex(page) else { return }
            editor.ink(points, page: index)
        }
        func markup(_ selection: PDFSelection) { editor.markup(selection) }
        func move(to bounds: CGRect) { editor.moveSelected(to: bounds) }
        func deleteSelection() { editor.deleteSelected() }
    }
}

final class StudioPDFCanvasContainer: NSView {
    let canvas = StudioPDFCanvasView()
    let thumbnails = PDFThumbnailView()
    private var thumbnailWidth: NSLayoutConstraint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        canvas.autoScales = true
        canvas.displayMode = .singlePageContinuous
        canvas.displaysPageBreaks = true
        canvas.backgroundColor = NSColor.windowBackgroundColor
        thumbnails.pdfView = canvas
        thumbnails.thumbnailSize = CGSize(width: 76, height: 98)
        thumbnails.backgroundColor = NSColor.controlBackgroundColor
        for view in [thumbnails, canvas] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        let width = thumbnails.widthAnchor.constraint(equalToConstant: 104)
        thumbnailWidth = width
        NSLayoutConstraint.activate([
            thumbnails.leadingAnchor.constraint(equalTo: leadingAnchor),
            thumbnails.topAnchor.constraint(equalTo: topAnchor),
            thumbnails.bottomAnchor.constraint(equalTo: bottomAnchor),
            width,
            canvas.leadingAnchor.constraint(equalTo: thumbnails.trailingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setThumbnailsVisible(_ visible: Bool) {
        thumbnails.isHidden = !visible
        thumbnailWidth?.constant = visible ? 104 : 0
    }
}

final class StudioPDFCanvasView: PDFView {
    weak var coordinator: StudioPDFCanvas.Coordinator?
    var tool: StudioPDFTool = .select
    var selectedAnnotation: PDFAnnotation?
    var cropRect: CGRect?
    var cropPage: PDFPage?
    let overlay = StudioPDFOverlayView()
    private var dragPage: PDFPage?
    private var dragStart: CGPoint?
    private var dragCurrent: CGPoint?
    private var inkPoints: [CGPoint] = []
    private var moving: (annotation: PDFAnnotation, origin: CGRect, start: CGPoint)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        overlay.canvas = self
        overlay.autoresizingMask = [.width, .height]
        overlay.frame = bounds
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        overlay.frame = bounds
        if overlay.superview === self, subviews.last !== overlay {
            overlay.removeFromSuperview()
            addSubview(overlay)
        }
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if selectedAnnotation != nil, event.keyCode == 51 || event.keyCode == 117 {
            coordinator?.deleteSelection()
            return
        }
        super.keyDown(with: event)
    }

    private func location(_ event: NSEvent) -> (PDFPage, CGPoint)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: true) else { return nil }
        return (page, convert(point, to: page))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard let (page, point) = location(event) else {
            super.mouseDown(with: event)
            return
        }
        switch tool {
        case .fill:
            super.mouseDown(with: event)
        case .select:
            if let annotation = page.annotation(at: point) {
                coordinator?.select(annotation)
                selectedAnnotation = annotation
                moving = (annotation, annotation.bounds, point)
                overlay.needsDisplay = true
                return
            }
            coordinator?.select(nil)
            selectedAnnotation = nil
            overlay.needsDisplay = true
            super.mouseDown(with: event)
        case .highlight, .underline, .strike:
            super.mouseDown(with: event)
        case .text, .note:
            coordinator?.click(at: point, page: page)
        default:
            dragPage = page
            dragStart = point
            dragCurrent = point
            inkPoints = [point]
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if let moving, let (page, point) = location(event), page === moving.annotation.page {
            let delta = CGPoint(x: point.x - moving.start.x, y: point.y - moving.start.y)
            moving.annotation.bounds = moving.origin.offsetBy(dx: delta.x, dy: delta.y)
            overlay.needsDisplay = true
            return
        }
        guard let dragPage else {
            super.mouseDragged(with: event)
            return
        }
        let point = convert(convert(event.locationInWindow, from: nil), to: dragPage)
        dragCurrent = point
        if tool == .draw { inkPoints.append(point) }
        overlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if let moving {
            let bounds = moving.annotation.bounds
            moving.annotation.bounds = moving.origin
            self.moving = nil
            if bounds != moving.origin { coordinator?.move(to: bounds) }
            overlay.needsDisplay = true
            return
        }
        if tool.isMarkup {
            super.mouseUp(with: event)
            if let selection = currentSelection, !(selection.string ?? "").isEmpty {
                coordinator?.markup(selection)
                clearSelection()
            }
            return
        }
        guard let page = dragPage, let start = dragStart else {
            super.mouseUp(with: event)
            return
        }
        let end = dragCurrent ?? start
        if tool == .draw {
            coordinator?.ink(inkPoints, page: page)
        } else if hypot(end.x - start.x, end.y - start.y) < 3,
            tool == .image || tool == .signature
        {
            coordinator?.click(at: start, page: page)
        } else {
            coordinator?.drag(from: start, to: end, page: page)
        }
        dragPage = nil
        dragStart = nil
        dragCurrent = nil
        inkPoints = []
        overlay.needsDisplay = true
    }

    fileprivate func drawOverlay() {
        NSColor.controlAccentColor.setStroke()
        if let page = dragPage, let start = dragStart, let current = dragCurrent {
            let a = convert(start, from: page)
            let b = convert(current, from: page)
            let path = NSBezierPath()
            switch tool {
            case .draw:
                let points = inkPoints.map { convert($0, from: page) }
                if let first = points.first {
                    path.move(to: first)
                    for point in points.dropFirst() { path.line(to: point) }
                }
                path.lineWidth = 2
                NSColor.systemRed.setStroke()
            case .line, .arrow:
                path.move(to: a)
                path.line(to: b)
                path.lineWidth = 2
            case .ellipse:
                path.appendOval(
                    in: NSRect(
                        x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x),
                        height: abs(b.y - a.y)))
                path.lineWidth = 1.5
            default:
                let rect = NSRect(
                    x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x),
                    height: abs(b.y - a.y))
                if tool == .redact {
                    NSColor.black.withAlphaComponent(0.5).setFill()
                    rect.fill()
                }
                path.appendRect(rect)
                path.lineWidth = 1.5
                path.setLineDash([5, 3], count: 2, phase: 0)
            }
            path.stroke()
        }
        if let annotation = selectedAnnotation, let page = annotation.page {
            let rect = convert(annotation.bounds, from: page).insetBy(dx: -3, dy: -3)
            let path = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            path.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            path.stroke()
        }
        if let crop = cropRect, let page = cropPage {
            let rect = convert(crop, from: page)
            let shade = NSBezierPath(rect: convert(page.bounds(for: .cropBox), from: page))
            shade.append(NSBezierPath(rect: rect).reversed)
            NSColor.black.withAlphaComponent(0.35).setFill()
            shade.fill()
            let border = NSBezierPath(rect: rect)
            border.lineWidth = 2
            NSColor.white.setStroke()
            border.stroke()
        }
    }
}

final class StudioPDFOverlayView: NSView {
    weak var canvas: StudioPDFCanvasView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { canvas?.isFlipped ?? false }

    override func draw(_ dirtyRect: NSRect) {
        canvas?.drawOverlay()
    }
}
