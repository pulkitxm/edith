import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import EdithStudio
import SwiftUI

struct StudioImageEditorView: View {
    let model: StudioModel
    @State private var editor: StudioImageEditorModel
    @State private var confirmingLeave = false
    @State private var showsInspector = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    @MainActor init(model: StudioModel, url: URL) {
        self.init(model: model, editor: model.imageEditor(for: url))
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
                    if compact {
                        Button("Inspector", systemImage: "sidebar.right") {
                            showsInspector.toggle()
                        }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.edith(.iconOnly))
                        .popover(isPresented: $showsInspector) {
                            StudioImageInspector(editor: editor)
                                .frame(width: UIScale.pt(280), height: UIScale.pt(480))
                        }
                    }
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
            PageLoading(
                state: editor.loadingState,
                message: editor.loadError ?? editor.rendering.errorMessage
                    ?? "The image could not be opened.",
                layout: .editor, retry: editor.load
            ) {
                HStack(spacing: 0) {
                    StudioImageToolRail(editor: editor)
                    Divider()
                    StudioImageCanvas(editor: editor)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(scheme == .dark ? 0.35 : 0.06))
                    if !compact {
                        Divider()
                        StudioImageInspector(editor: editor)
                            .frame(width: UIScale.pt(280))
                    }
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
        .navigationRoute(
            "panel",
            selection: Binding(get: { editor.panel }, set: { editor.panel = $0 })
        )
        .overlay(alignment: .topTrailing) {
            if editor.isRendering, editor.preview != nil {
                LoadingIndicator()
                    .controlSize(.small)
                    .padding(.top, UIScale.pt(66))
                    .padding(.trailing, UIScale.pt(compact ? 20 : 300))
            }
        }
        .overlay {
            if editor.isSaving {
                ZStack {
                    Color.black.opacity(0.15)
                    LoadingIndicator("Saving full resolution…")
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
        .pageTask { if editor.preview == nil { editor.load() } }
    }

    private func leave() {
        if editor.hasUnsavedChanges {
            confirmingLeave = true
        } else {
            model.goHome()
        }
    }

    private var sizeText: String? {
        guard let size = editor.source?.originalSize else { return nil }
        return "\(Int(size.width))×\(Int(size.height))"
    }
}

struct StudioImageToolRail: View {
    let editor: StudioImageEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
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
            }
            .padding(UIScale.pt(6))
        }
        .frame(width: UIScale.pt(72))
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
                    .frame(width: UIScale.pt(14), height: UIScale.pt(14))
                    .offset(x: x - 7, y: y - 7)
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                begin()
                                guard let origin else { return }
                                let anchor = CanvasSelectionGeometry.anchor(
                                    corner,
                                    in: ImageEditGeometry.viewRect(for: origin, in: imageRect))
                                let point = ImageEditGeometry.normalized(
                                    CGPoint(
                                        x: anchor.x + value.translation.width,
                                        y: anchor.y + value.translation.height), in: imageRect)
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
