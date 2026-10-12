import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI

struct StudioImageCanvas: View {
    let editor: StudioImageEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var moveOrigin:
        (layer: UUID, frame: StudioRect, document: ImageEditDocument, corner: Int?)?

    var body: some View {
        GeometryReader { geometry in
            let bounds = CGRect(origin: .zero, size: geometry.size).insetBy(dx: 24, dy: 24)
            if editor.panel == .crop, let image = editor.geometry {
                let size = CGSize(width: image.width, height: image.height)
                let rect = ImageEditGeometry.fittedRect(content: size, in: bounds)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    StudioImageCropOverlay(editor: editor, imageRect: rect)
                }
            } else if let image = editor.preview {
                let size = CGSize(width: image.width, height: image.height)
                let rect = ImageEditGeometry.fittedRect(content: size, in: bounds)
                ZStack(alignment: .topLeading) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .frame(width: rect.width, height: rect.height)
                        .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                        .allowsHitTesting(false)
                        .offset(x: rect.minX, y: rect.minY)
                    overlay(in: rect)
                }
                .frame(
                    width: geometry.size.width, height: geometry.size.height, alignment: .topLeading
                )
                .contentShape(Rectangle())
                .overlay {
                    CanvasPointerSurface(
                        onChanged: { dragChanged($0, in: rect) },
                        onEnded: { dragEnded($0, in: rect) },
                        onKeyDown: editor.handleCanvasKey)
                }
                .onContinuousHover { phase in
                    switch phase {
                    case let .active(point):
                        if let selected = editor.selected, !selected.isHidden {
                            let frame = ImageEditGeometry.viewRect(for: selected.frame, in: rect)
                            if CanvasSelectionGeometry.corner(at: point, frame: frame) != nil {
                                NSCursor.crosshair.set()
                            } else if frame.contains(point) {
                                NSCursor.openHand.set()
                            } else {
                                NSCursor.arrow.set()
                            }
                        } else {
                            NSCursor.arrow.set()
                        }
                    case .ended: NSCursor.arrow.set()
                    }
                }
            } else {
                LoadingIndicator().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .overlay(alignment: .bottom) { selectionControls }
    }

    @ViewBuilder private var selectionControls: some View {
        if let selected = editor.selected, !selected.isHidden, editor.panel != .crop {
            HStack(spacing: UIScale.pt(8)) {
                if case let .text(style) = selected.content {
                    TextField(
                        "Selected text",
                        text: Binding(
                            get: { style.text },
                            set: { value in
                                editor.updateSelected { layer in
                                    StudioImageTextStyleEditor.modify(&layer) { $0.text = value }
                                }
                            })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.edithText(.body))
                    .frame(maxWidth: UIScale.pt(300))
                } else {
                    TextField(
                        "Layer name",
                        text: Binding(
                            get: { selected.title },
                            set: { value in editor.updateSelected { $0.name = value } })
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.edithText(.body))
                    .frame(maxWidth: UIScale.pt(240))
                }
                Button("Duplicate", systemImage: "plus.square.on.square") {
                    editor.duplicateSelected()
                }
                .labelStyle(.iconOnly)
                .help("Duplicate layer (⌘D)")
                .accessibilityLabel("Duplicate selected layer")
                Button("Delete", systemImage: "trash", role: .destructive) {
                    editor.deleteSelected()
                }
                .labelStyle(.iconOnly)
                .help("Delete layer (Delete)")
                .accessibilityLabel("Delete selected layer")
            }
            .buttonStyle(.edith(.iconOnly))
            .padding(UIScale.pt(10))
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
            .padding(UIScale.pt(12))
        }
    }

    @ViewBuilder private func overlay(in rect: CGRect) -> some View {
        if let selected = editor.selected, !selected.isHidden {
            let frame = ImageEditGeometry.viewRect(for: selected.frame, in: rect)
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: max(frame.width, 6), height: max(frame.height, 6))
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            ForEach(0..<4, id: \.self) { corner in
                let anchor = CanvasSelectionGeometry.anchor(corner, in: frame)
                RoundedRectangle(cornerRadius: UIScale.pt(2))
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: UIScale.pt(2)).strokeBorder(
                            Color.accentColor, lineWidth: 1.5)
                    )
                    .frame(width: UIScale.pt(10), height: UIScale.pt(10))
                    .offset(x: anchor.x - UIScale.pt(5), y: anchor.y - UIScale.pt(5))
                    .allowsHitTesting(false)
            }
        }
        if let start = dragStart, let current = dragCurrent,
            editor.panel == .shapes || editor.panel == .blur
        {
            let a = ImageEditGeometry.viewPoint(start, in: rect)
            let b = ImageEditGeometry.viewPoint(current, in: rect)
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .background(editor.panel == .blur ? Color.black.opacity(0.25) : Color.clear)
                .frame(width: abs(b.x - a.x), height: abs(b.y - a.y))
                .offset(x: min(a.x, b.x), y: min(a.y, b.y))
                .allowsHitTesting(false)
        }
        if editor.panel == .draw, stroke.count > 1 {
            Path { path in
                path.addLines(stroke.map { ImageEditGeometry.viewPoint($0, in: rect) })
            }
            .stroke(
                Color(cgColor: (StudioColor(hex: editor.drawColor) ?? .black).cgColor)
                    .opacity(editor.highlighter ? 0.45 : 1),
                style: StrokeStyle(
                    lineWidth: max(1, editor.drawWidth * rect.height), lineCap: .round,
                    lineJoin: .round)
            )
            .allowsHitTesting(false)
        }
    }

    private func dragChanged(_ value: CanvasPointerDrag, in rect: CGRect) {
        let point = ImageEditGeometry.normalized(value.location, in: rect)
        let start = ImageEditGeometry.normalized(value.startLocation, in: rect)
        if moveOrigin == nil && dragStart == nil && stroke.isEmpty {
            if let selected = editor.selected, !selected.isHidden,
                let corner = CanvasSelectionGeometry.corner(
                    at: value.startLocation,
                    frame: ImageEditGeometry.viewRect(for: selected.frame, in: rect))
            {
                moveOrigin = (selected.id, selected.frame, editor.document, corner)
            } else if ![.draw, .shapes, .blur].contains(editor.panel) {
                let hit =
                    rect.contains(value.startLocation)
                    ? editor.document.hitTest(start, canvas: editor.canvasSize) : nil
                if let hit, let layer = editor.document.layer(hit) {
                    editor.selectLayer(hit)
                    moveOrigin = (hit, layer.frame, editor.document, nil)
                } else {
                    editor.selectedLayer = nil
                }
            }
        }
        if let origin = moveOrigin {
            let delta = CGPoint(
                x: value.translation.width / rect.width,
                y: value.translation.height / rect.height)
            editor.preview { document in
                document.updateLayer(origin.layer) { layer in
                    if let corner = origin.corner {
                        let preserveAspect: Bool
                        if case .image = layer.content {
                            preserveAspect = true
                        } else if case .sticker = layer.content {
                            preserveAspect = true
                        } else {
                            preserveAspect = false
                        }
                        let frame = CanvasSelectionGeometry.resize(
                            CGRect(
                                x: origin.frame.x, y: origin.frame.y,
                                width: origin.frame.width, height: origin.frame.height),
                            corner: corner, delta: delta,
                            preserveAspect: preserveAspect
                                && !value.modifierFlags.contains(.shift))
                        layer.frame = StudioRect(
                            x: frame.minX, y: frame.minY,
                            width: frame.width, height: frame.height)
                        if case var .text(style) = layer.content,
                            let original = origin.document.layer(origin.layer),
                            case let .text(originalStyle) = original.content
                        {
                            style.size =
                                originalStyle.size * frame.height
                                / max(0.02, origin.frame.height)
                            layer.content = .text(style)
                        }
                    } else {
                        layer.frame = origin.frame.moved(by: delta)
                    }
                }
            }
            return
        }
        guard rect.contains(value.startLocation) else { return }
        switch editor.panel {
        case .draw: stroke.append(clamp(point))
        case .shapes, .blur:
            dragStart = clamp(start)
            dragCurrent = clamp(point)
        default: break
        }
    }

    private func dragEnded(_ value: CanvasPointerDrag, in rect: CGRect) {
        if let origin = moveOrigin {
            editor.commitPreview(from: origin.document)
        } else if rect.contains(value.startLocation) {
            let point = clamp(ImageEditGeometry.normalized(value.location, in: rect))
            let start = clamp(ImageEditGeometry.normalized(value.startLocation, in: rect))
            switch editor.panel {
            case .draw: editor.addStroke(stroke)
            case .shapes: editor.addShape(from: start, to: point)
            case .blur: editor.addRedaction(from: start, to: point)
            case .text where hypot(point.x - start.x, point.y - start.y) < 0.01:
                editor.addText(at: point)
            default: break
            }
        }
        moveOrigin = nil
        stroke = []
        dragStart = nil
        dragCurrent = nil
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}
