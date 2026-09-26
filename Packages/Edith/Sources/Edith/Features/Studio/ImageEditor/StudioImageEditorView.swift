import AppKit
import EdithKit
import EdithStudio
import SwiftUI

struct StudioImageEditorView: View {
    let model: StudioModel
    @State private var editor: StudioImageEditorModel
    @State private var confirmingLeave = false
    @Environment(\.colorScheme) private var scheme

    @MainActor init(model: StudioModel, url: URL) {
        self.init(model: model, editor: StudioImageEditorModel(url: url))
    }

    init(model: StudioModel, editor: StudioImageEditorModel) {
        self.model = model
        _editor = State(initialValue: editor)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioBackBar(
                title: editor.url.lastPathComponent, subtitle: sizeText, symbol: "photo",
                back: leave
            ) {
                HStack(spacing: UIScale.pt(6)) {
                    Button {
                        editor.undo()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!editor.canUndo)
                    .help("Undo (⌘Z)")
                    Button {
                        editor.redo()
                    } label: {
                        Image(systemName: "arrow.uturn.forward")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!editor.canRedo)
                    .help("Redo (⇧⌘Z)")
                    Button("Reset") { editor.resetAll() }
                        .buttonStyle(.edith(.toolbar))
                        .disabled(!editor.hasChanges)
                    Divider().frame(height: UIScale.pt(16))
                    Button("Save as…") { editor.saveAs(studio: model) }
                        .buttonStyle(.edith(.secondary))
                    Button {
                        editor.save(studio: model)
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.edith(.primary))
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(editor.isSaving || editor.preview == nil)
                }
            }
            Divider()
            if let failure = editor.loadError, editor.preview == nil {
                StudioEmptyNote(symbol: "exclamationmark.triangle", text: failure).padding(
                    UIScale.pt(20))
                Spacer()
            } else {
                HStack(spacing: 0) {
                    StudioImageToolRail(editor: editor)
                    Divider()
                    StudioImageCanvas(editor: editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(scheme == .dark ? 0.35 : 0.06))
                    Divider()
                    StudioImageInspector(editor: editor)
                        .frame(width: UIScale.pt(280))
                }
            }
            if let status = editor.status {
                HStack {
                    Text(status).font(.system(size: UIScale.pt(11.5))).foregroundStyle(.secondary)
                    Spacer()
                    if let saved = editor.lastSaved {
                        Button("Show in Finder") { StudioFileActions.reveal([saved]) }
                            .buttonStyle(.edith(.toolbar))
                        Button("Open") { StudioFileActions.open(saved) }
                            .buttonStyle(.edith(.toolbar))
                    }
                }
                .padding(.horizontal, UIScale.pt(14))
                .padding(.vertical, UIScale.pt(6))
                .background(.bar)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .overlay(alignment: .topTrailing) {
            if editor.isRendering, editor.preview != nil {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, UIScale.pt(66))
                    .padding(.trailing, UIScale.pt(300))
            }
        }
        .overlay {
            if editor.isSaving {
                ZStack {
                    Color.black.opacity(0.15)
                    ProgressView("Saving full resolution…")
                        .padding(UIScale.pt(22))
                        .background(
                            .regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(14)))
                }
            }
        }
        .confirmationDialog(
            "Leave without saving?", isPresented: $confirmingLeave, titleVisibility: .visible
        ) {
            Button("Discard changes", role: .destructive) { model.goHome() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits to \(editor.url.lastPathComponent) have not been saved yet.")
        }
        .task { if editor.preview == nil { editor.load() } }
    }

    private func leave() {
        if editor.hasUnsavedChanges {
            confirmingLeave = true
        } else {
            model.goHome()
        }
    }

    private var sizeText: String? {
        guard let info = StudioImageIO.info(editor.url) else { return nil }
        return "\(info.width)×\(info.height)"
    }
}

struct StudioImageToolRail: View {
    let editor: StudioImageEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: UIScale.pt(4)) {
            ForEach(StudioImagePanel.allCases) { panel in
                Button {
                    editor.switchPanel(panel)
                } label: {
                    VStack(spacing: UIScale.pt(3)) {
                        Image(systemName: panel.symbol)
                            .font(.system(size: UIScale.pt(15)))
                        Text(panel.title.components(separatedBy: " ").first ?? panel.title)
                            .font(.system(size: UIScale.pt(9.5), weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(width: UIScale.pt(60), height: UIScale.pt(46))
                    .foregroundStyle(
                        editor.panel == panel ? DashSkin.accent(scheme == .dark) : Color.primary
                    )
                    .background(
                        editor.panel == panel
                            ? DashSkin.accent(scheme == .dark).opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: UIScale.pt(8))
                    )
                    .edithButtonTarget(.borderless)
                }
                .buttonStyle(.edith(.borderless))
                .help(panel.title)
                .accessibilityLabel(panel.title)
                .accessibilityAddTraits(editor.panel == panel ? .isSelected : [])
            }
            Spacer()
        }
        .padding(UIScale.pt(6))
    }
}

struct StudioImageCanvas: View {
    let editor: StudioImageEditorModel
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var stroke: [CGPoint] = []
    @State private var moveOrigin: (layer: UUID, frame: StudioRect, document: ImageEditDocument)?

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
                        .offset(x: rect.minX, y: rect.minY)
                    overlay(in: rect)
                }
                .contentShape(Rectangle())
                .gesture(gesture(in: rect))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func overlay(in rect: CGRect) -> some View {
        if let selected = editor.selected {
            let frame = ImageEditGeometry.viewRect(for: selected.frame, in: rect)
            Rectangle()
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                .frame(width: max(frame.width, 6), height: max(frame.height, 6))
                .offset(x: frame.minX, y: frame.minY)
                .allowsHitTesting(false)
            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
                .frame(width: 12, height: 12)
                .offset(x: frame.maxX - 6, y: frame.maxY - 6)
                .gesture(resizeGesture(in: rect, layer: selected))
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

    private func gesture(in rect: CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = clamp(ImageEditGeometry.normalized(value.location, in: rect))
                let start = clamp(ImageEditGeometry.normalized(value.startLocation, in: rect))
                switch editor.panel {
                case .draw:
                    stroke.append(point)
                case .shapes, .blur:
                    dragStart = start
                    dragCurrent = point
                default:
                    if moveOrigin == nil {
                        let hit = editor.document.hitTest(
                            CGPoint(
                                x: start.x * editor.canvasSize.width,
                                y: start.y * editor.canvasSize.height),
                            canvas: editor.canvasSize)
                        editor.selectedLayer = hit
                        if let hit, let layer = editor.document.layer(hit) {
                            moveOrigin = (hit, layer.frame, editor.document)
                        }
                    }
                    if let origin = moveOrigin {
                        let delta = CGPoint(x: point.x - start.x, y: point.y - start.y)
                        editor.preview { document in
                            document.updateLayer(origin.layer) {
                                $0.frame = origin.frame.moved(by: delta)
                            }
                        }
                    }
                }
            }
            .onEnded { value in
                let point = clamp(ImageEditGeometry.normalized(value.location, in: rect))
                let start = clamp(ImageEditGeometry.normalized(value.startLocation, in: rect))
                switch editor.panel {
                case .draw:
                    editor.addStroke(stroke)
                    stroke = []
                case .shapes:
                    editor.addShape(from: start, to: point)
                case .blur:
                    editor.addRedaction(from: start, to: point)
                case .text
                where moveOrigin == nil && hypot(point.x - start.x, point.y - start.y) < 0.01:
                    if editor.document.hitTest(
                        CGPoint(
                            x: point.x * editor.canvasSize.width,
                            y: point.y * editor.canvasSize.height),
                        canvas: editor.canvasSize) == nil
                    {
                        editor.addText(at: point)
                    }
                default:
                    break
                }
                if let origin = moveOrigin { editor.commitPreview(from: origin.document) }
                moveOrigin = nil
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func resizeGesture(in rect: CGRect, layer: ImageLayer) -> some Gesture {
        DragGesture()
            .onChanged { value in
                if moveOrigin == nil { moveOrigin = (layer.id, layer.frame, editor.document) }
                guard let origin = moveOrigin else { return }
                let point = clamp(ImageEditGeometry.normalized(value.location, in: rect))
                editor.preview { document in
                    document.updateLayer(origin.layer) { layer in
                        layer.frame = StudioRect(
                            x: origin.frame.x, y: origin.frame.y,
                            width: max(0.02, point.x - origin.frame.x),
                            height: max(0.02, point.y - origin.frame.y))
                    }
                }
            }
            .onEnded { _ in
                if let origin = moveOrigin { editor.commitPreview(from: origin.document) }
                moveOrigin = nil
            }
    }

    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
    }
}

struct StudioImageCropOverlay: View {
    let editor: StudioImageEditorModel
    let imageRect: CGRect
    @State private var origin: StudioRect?
    @State private var before: ImageEditDocument?

    var body: some View {
        let crop = ImageEditGeometry.viewRect(for: editor.document.crop, in: imageRect)
        ZStack(alignment: .topLeading) {
            Path { path in
                path.addRect(imageRect)
                path.addRect(crop)
            }
            .fill(Color.black.opacity(0.5), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .overlay {
                    GeometryReader { geometry in
                        Path { path in
                            for index in 1...2 {
                                let x = geometry.size.width * CGFloat(index) / 3
                                let y = geometry.size.height * CGFloat(index) / 3
                                path.move(to: CGPoint(x: x, y: 0))
                                path.addLine(to: CGPoint(x: x, y: geometry.size.height))
                                path.move(to: CGPoint(x: 0, y: y))
                                path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                            }
                        }
                        .stroke(Color.white.opacity(0.4), lineWidth: 0.5)
                    }
                }
                .frame(width: crop.width, height: crop.height)
                .offset(x: crop.minX, y: crop.minY)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { value in
                            begin()
                            guard let origin else { return }
                            let dx = value.translation.width / imageRect.width
                            let dy = value.translation.height / imageRect.height
                            editor.preview { document in
                                document.crop = origin.moved(by: CGPoint(x: dx, y: dy))
                            }
                        }
                        .onEnded { _ in end() })
            ForEach(0..<4, id: \.self) { corner in
                let x = corner % 2 == 0 ? crop.minX : crop.maxX
                let y = corner < 2 ? crop.minY : crop.maxY
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .offset(x: x - 7, y: y - 7)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                begin()
                                guard let origin else { return }
                                let point = ImageEditGeometry.normalized(
                                    value.location, in: imageRect)
                                editor.preview { document in
                                    document.crop = StudioCropMath.drag(
                                        corner: corner, of: origin, to: point)
                                }
                            }
                            .onEnded { _ in end() })
            }
        }
    }

    private func begin() {
        if origin == nil {
            origin = editor.document.crop
            before = editor.document
        }
    }

    private func end() {
        if let before { editor.commitPreview(from: before) }
        origin = nil
        before = nil
    }
}

enum StudioCropMath {
    static func drag(corner: Int, of rect: StudioRect, to point: CGPoint) -> StudioRect {
        let x = min(max(point.x, 0), 1)
        let y = min(max(point.y, 0), 1)
        var left = rect.x
        var top = rect.y
        var right = rect.x + rect.width
        var bottom = rect.y + rect.height
        if corner % 2 == 0 { left = min(x, right - 0.03) } else { right = max(x, left + 0.03) }
        if corner < 2 { top = min(y, bottom - 0.03) } else { bottom = max(y, top + 0.03) }
        return StudioRect(x: left, y: top, width: right - left, height: bottom - top).clamped
    }
}
