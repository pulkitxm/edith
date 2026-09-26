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
    private var editing:
        (annotation: PDFAnnotation, origin: CGRect, start: CGPoint, grip: StudioPDFGrip)?

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

    private var editsAnnotations: Bool { tool == .select || tool == .redact }

    override func keyDown(with event: NSEvent) {
        guard let selected = selectedAnnotation, editsAnnotations else {
            super.keyDown(with: event)
            return
        }
        let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 51, 117:
            coordinator?.deleteSelection()
            selectedAnnotation = nil
        case 53:
            coordinator?.select(nil)
            selectedAnnotation = nil
        case 123: nudge(selected, view: CGPoint(x: -1, y: 0), by: step)
        case 124: nudge(selected, view: CGPoint(x: 1, y: 0), by: step)
        case 125: nudge(selected, view: CGPoint(x: 0, y: isFlipped ? 1 : -1), by: step)
        case 126: nudge(selected, view: CGPoint(x: 0, y: isFlipped ? -1 : 1), by: step)
        default:
            super.keyDown(with: event)
            return
        }
        overlay.needsDisplay = true
    }

    func nudge(_ annotation: PDFAnnotation, view direction: CGPoint, by amount: CGFloat) {
        guard let page = annotation.page else { return }
        let origin = convert(NSPoint.zero, to: page)
        let moved = convert(NSPoint(x: direction.x * 100, y: direction.y * 100), to: page)
        let delta = StudioPDFGrip.nudge(
            CGPoint(x: moved.x - origin.x, y: moved.y - origin.y), by: amount)
        coordinator?.move(to: annotation.bounds.offsetBy(dx: delta.x, dy: delta.y))
    }

    func grip(at viewPoint: NSPoint, of annotation: PDFAnnotation) -> StudioPDFGrip? {
        guard StudioPDFGrip.resizable(annotation), let page = annotation.page else { return nil }
        for grip in StudioPDFGrip.handles {
            let anchor = convert(grip.anchor(in: annotation.bounds), from: page)
            if hypot(anchor.x - viewPoint.x, anchor.y - viewPoint.y) <= 7 { return grip }
        }
        return nil
    }

    private func begin(_ annotation: PDFAnnotation, at point: CGPoint, grip: StudioPDFGrip) {
        coordinator?.select(annotation)
        selectedAnnotation = annotation
        editing = (annotation, annotation.bounds, point, grip)
        overlay.needsDisplay = true
    }

    private func deselect() {
        coordinator?.select(nil)
        selectedAnnotation = nil
        overlay.needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        guard editsAnnotations else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let selected = selectedAnnotation, let page = selected.page,
            let grip = grip(at: viewPoint, of: selected)
        {
            let anchor = convert(grip.anchor(in: selected.bounds), from: page)
            let center = convert(
                CGPoint(x: selected.bounds.midX, y: selected.bounds.midY), from: page)
            let dx = abs(anchor.x - center.x)
            let dy = abs(anchor.y - center.y)
            let cursor: NSCursor =
                dy < 1 ? .resizeLeftRight : dx < 1 ? .resizeUpDown : .crosshair
            cursor.set()
        } else if let (page, point) = location(event), let annotation = page.annotation(at: point),
            tool == .select || StudioPDFGrip.isRedaction(annotation)
        {
            NSCursor.openHand.set()
        }
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
        let viewPoint = convert(event.locationInWindow, from: nil)
        if editsAnnotations, let selected = selectedAnnotation, let selectedPage = selected.page,
            let grip = grip(at: viewPoint, of: selected)
        {
            begin(selected, at: convert(viewPoint, to: selectedPage), grip: grip)
            return
        }
        switch tool {
        case .fill:
            super.mouseDown(with: event)
        case .select:
            if let annotation = page.annotation(at: point) {
                begin(annotation, at: point, grip: .move)
                return
            }
            deselect()
            super.mouseDown(with: event)
        case .redact:
            if let mark = page.annotation(at: point), StudioPDFGrip.isRedaction(mark) {
                begin(mark, at: point, grip: .move)
                return
            }
            deselect()
            dragPage = page
            dragStart = point
            dragCurrent = point
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
        if let editing, let page = editing.annotation.page {
            let point = convert(convert(event.locationInWindow, from: nil), to: page)
            let delta = CGPoint(x: point.x - editing.start.x, y: point.y - editing.start.y)
            editing.annotation.bounds = editing.grip.apply(to: editing.origin, delta: delta)
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
        if let editing {
            let bounds = editing.annotation.bounds
            editing.annotation.bounds = editing.origin
            self.editing = nil
            if bounds != editing.origin { coordinator?.move(to: bounds) }
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
            if editsAnnotations, StudioPDFGrip.resizable(annotation) {
                for grip in StudioPDFGrip.handles {
                    let center = convert(grip.anchor(in: annotation.bounds), from: page)
                    let handle = NSBezierPath(
                        rect: NSRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8))
                    NSColor.white.setFill()
                    handle.fill()
                    handle.lineWidth = 1.5
                    NSColor.controlAccentColor.setStroke()
                    handle.stroke()
                }
            }
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
