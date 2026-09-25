import AppKit
import EdithKit
import EdithStudio
import PDFKit
import SwiftUI

struct StudioPDFEditorView: View {
    let model: StudioModel
    @State private var editor: StudioPDFEditorModel
    @State private var showsThumbnails = true
    @State private var showsSignaturePad = false
    @State private var confirmingLeave = false
    @Environment(\.colorScheme) private var scheme

    @MainActor init(model: StudioModel, url: URL, mode: StudioPDFEditorMode) {
        self.init(model: model, editor: StudioPDFEditorModel(url: url, mode: mode))
    }

    init(model: StudioModel, editor: StudioPDFEditorModel) {
        self.model = model
        _editor = State(initialValue: editor)
    }

    var body: some View {
        VStack(spacing: 0) {
            StudioBackBar(
                title: editor.url.lastPathComponent,
                subtitle: editor.pageCount > 0 ? "\(editor.pageCount) pages" : nil,
                symbol: "doc.richtext", back: leave
            ) {
                trailing
            }
            Divider()
            if editor.needsPassword {
                StudioPDFPasswordPrompt(editor: editor)
            } else if let failure = editor.loadError {
                StudioEmptyNote(symbol: "exclamationmark.triangle", text: failure)
                    .padding(UIScale.pt(20))
                Spacer()
            } else if editor.session != nil {
                StudioPDFModeBar(editor: editor)
                Divider()
                HStack(spacing: 0) {
                    if editor.mode == .organize {
                        StudioPDFOrganizeGrid(editor: editor)
                    } else {
                        StudioPDFCanvas(editor: editor, showsThumbnails: showsThumbnails)
                    }
                    Divider()
                    StudioPDFInspector(
                        model: model, editor: editor, showsSignaturePad: $showsSignaturePad
                    )
                    .frame(width: UIScale.pt(270))
                }
                if let status = editor.status {
                    HStack {
                        Text(status)
                            .font(.system(size: UIScale.pt(11.5)))
                            .foregroundStyle(.secondary)
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
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .overlay {
            if editor.isSaving {
                ZStack {
                    Color.black.opacity(0.15)
                    ProgressView("Saving…")
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
        .sheet(isPresented: $showsSignaturePad) {
            StudioSignaturePad { image in
                editor.saveSignature(image)
                showsSignaturePad = false
            } cancel: {
                showsSignaturePad = false
            }
        }
        .task { if editor.session == nil { editor.load() } }
    }

    private func leave() {
        if editor.isDirty {
            confirmingLeave = true
        } else {
            model.goHome()
        }
    }

    @ViewBuilder private var trailing: some View {
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
            if editor.mode != .organize {
                Divider().frame(height: UIScale.pt(16))
                Button {
                    editor.zoom(0.8)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .buttonStyle(.edith(.iconOnly))
                .keyboardShortcut("-", modifiers: .command)
                Button {
                    editor.zoomToFit()
                } label: {
                    Image(systemName: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .buttonStyle(.edith(.iconOnly))
                .keyboardShortcut("0", modifiers: .command)
                Button {
                    editor.zoom(1.25)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .buttonStyle(.edith(.iconOnly))
                .keyboardShortcut("=", modifiers: .command)
                Button {
                    showsThumbnails.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Show or hide page thumbnails")
            }
            Divider().frame(height: UIScale.pt(16))
            Button("Save as…") { editor.saveAs(studio: model) }
                .buttonStyle(.edith(.secondary))
            Button {
                editor.save(studio: model)
            } label: {
                Label(
                    editor.mode == .redact ? "Apply & save" : "Save",
                    systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.edith(.primary))
            .keyboardShortcut("s", modifiers: .command)
            .disabled(editor.isSaving)
            .help("Save a new PDF next to the original (⌘S)")
        }
    }
}

struct StudioPDFPasswordPrompt: View {
    let editor: StudioPDFEditorModel

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            Image(systemName: "lock.doc")
                .font(.system(size: UIScale.pt(34), weight: .light))
            Text("This PDF is protected").font(.system(size: UIScale.pt(15), weight: .semibold))
            SecureField(
                "Password", text: Binding(get: { editor.password }, set: { editor.password = $0 })
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: UIScale.pt(240))
            .onSubmit { editor.load() }
            if let status = editor.status {
                Text(status).font(.system(size: UIScale.pt(11.5))).foregroundStyle(DashSkin.danger)
            }
            Button("Unlock") { editor.load() }
                .buttonStyle(.edith(.primary))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct StudioPDFModeBar: View {
    let editor: StudioPDFEditorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(2)) {
                ForEach(StudioPDFEditorMode.allCases, id: \.self) { mode in
                    Button {
                        editor.switchMode(mode)
                    } label: {
                        Text(mode.title)
                            .font(
                                .system(
                                    size: UIScale.pt(12),
                                    weight: editor.mode == mode ? .semibold : .regular)
                            )
                            .padding(.horizontal, UIScale.pt(10))
                            .padding(.vertical, UIScale.pt(4))
                            .background(
                                editor.mode == mode
                                    ? DashSkin.paper2(scheme == .dark) : Color.clear,
                                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                            )
                            .edithButtonTarget(.borderless)
                    }
                    .buttonStyle(.edith(.borderless))
                    .accessibilityAddTraits(editor.mode == mode ? .isSelected : [])
                }
            }
            .padding(UIScale.pt(3))
            .background(
                DashSkin.grid(scheme == .dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            Divider().frame(height: UIScale.pt(18))
            HStack(spacing: UIScale.pt(2)) {
                ForEach(StudioPDFTool.tools(for: editor.mode)) { tool in
                    Button {
                        editor.tool = tool
                    } label: {
                        Image(systemName: tool.symbol)
                            .font(.system(size: UIScale.pt(13)))
                            .frame(width: UIScale.pt(30), height: UIScale.pt(26))
                            .background(
                                editor.tool == tool
                                    ? DashSkin.accent(scheme == .dark).opacity(0.18) : Color.clear,
                                in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                            )
                            .foregroundStyle(
                                editor.tool == tool
                                    ? DashSkin.accent(scheme == .dark) : Color.primary
                            )
                            .edithButtonTarget(.borderless)
                    }
                    .buttonStyle(.edith(.borderless))
                    .help(tool.title)
                    .accessibilityLabel(tool.title)
                }
            }
            Spacer()
            if editor.mode != .organize, editor.pageCount > 0 {
                Text("Page \(editor.currentPage + 1) of \(editor.pageCount)")
                    .font(DashSkin.mono(11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, UIScale.pt(14))
        .padding(.vertical, UIScale.pt(7))
    }
}

struct StudioPDFInspector: View {
    let model: StudioModel
    let editor: StudioPDFEditorModel
    @Binding var showsSignaturePad: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                Text(StudioPDFHelp.text(for: editor.mode, tool: editor.tool))
                    .font(.system(size: UIScale.pt(11.5)))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                switch editor.mode {
                case .annotate: annotateSection
                case .sign: signSection
                case .redact: redactSection
                case .forms: formsSection
                case .crop: cropSection
                case .organize: organizeSection
                }
                if let selected = editor.selected {
                    selectionSection(selected)
                }
            }
            .padding(UIScale.pt(16))
        }
    }

    private var styleBinding: Binding<PDFEditSession.Style> {
        Binding(get: { editor.style }, set: { editor.style = $0 })
    }

    @ViewBuilder private var annotateSection: some View {
        if editor.tool == .text || editor.tool == .note {
            StudioInspectorGroup("Text") {
                TextField(
                    editor.tool == .note ? "Note" : "Text to add",
                    text: Binding(get: { editor.pendingText }, set: { editor.pendingText = $0 }),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...4)
            }
        }
        if editor.tool == .image {
            StudioInspectorGroup("Image") {
                Button(editor.pendingImageName ?? "Choose image…") { editor.chooseImage() }
                    .buttonStyle(.edith(.secondary))
            }
        }
        StudioPDFStyleControls(style: styleBinding, showsFont: editor.tool == .text)
    }

    @ViewBuilder private var signSection: some View {
        StudioInspectorGroup("Signatures") {
            Button {
                showsSignaturePad = true
            } label: {
                Label("New signature", systemImage: "plus")
            }
            .buttonStyle(.edith(.primary))
            if editor.signatures.isEmpty {
                Text("Draw, type or import your signature once and reuse it.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(.secondary)
            }
            ForEach(editor.signatures) { signature in
                HStack {
                    Button {
                        editor.useSignature(signature)
                    } label: {
                        Image(decorative: signature.image, scale: 2)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(height: UIScale.pt(40))
                            .frame(maxWidth: .infinity)
                            .padding(UIScale.pt(6))
                            .background(
                                Color.white, in: RoundedRectangle(cornerRadius: UIScale.pt(6))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: UIScale.pt(6))
                                    .strokeBorder(
                                        editor.pendingImageName == signature.name
                                            ? Color.accentColor : Color.primary.opacity(0.15),
                                        lineWidth: 1.5)
                            )
                            .edithButtonTarget(.borderless)
                    }
                    .buttonStyle(.edith(.borderless))
                    Button {
                        editor.deleteSignature(signature)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Delete this signature")
                }
            }
        }
        StudioInspectorGroup("Date or initials") {
            TextField(
                "Text", text: Binding(get: { editor.pendingText }, set: { editor.pendingText = $0 })
            )
            .textFieldStyle(.roundedBorder)
            Button("Use today's date") {
                editor.pendingText = Date().formatted(date: .long, time: .omitted)
                editor.tool = .text
            }
            .buttonStyle(.edith(.secondary))
        }
    }

    @ViewBuilder private var redactSection: some View {
        StudioInspectorGroup("Find and mark") {
            TextField(
                "Names, words, numbers",
                text: Binding(get: { editor.redactTerms }, set: { editor.redactTerms = $0 }),
                axis: .vertical
            )
            .textFieldStyle(.roundedBorder)
            .lineLimit(1...4)
            Toggle(
                "Email addresses",
                isOn: Binding(get: { editor.redactEmails }, set: { editor.redactEmails = $0 }))
            Toggle(
                "Phone numbers",
                isOn: Binding(get: { editor.redactPhones }, set: { editor.redactPhones = $0 }))
            Toggle(
                "Card numbers",
                isOn: Binding(get: { editor.redactCards }, set: { editor.redactCards = $0 }))
            Button("Mark matches") { editor.findRedactions() }
                .buttonStyle(.edith(.secondary))
        }
        StudioInspectorGroup("Marked") {
            Text("\(editor.session?.redactionCount ?? 0) areas will be removed when you save.")
                .font(.system(size: UIScale.pt(11.5)))
            Button("Clear all marks") { editor.mutate { $0.clearRedactions() } }
                .buttonStyle(.edith(.secondary))
                .disabled((editor.session?.redactionCount ?? 0) == 0)
        }
    }

    @ViewBuilder private var formsSection: some View {
        StudioInspectorGroup("Fields") {
            Button("Detect fields automatically") { editor.detectFields() }
                .buttonStyle(.edith(.secondary))
            if editor.tool == .dropdown {
                TextField(
                    "Choices, comma separated",
                    text: Binding(
                        get: { editor.dropdownOptions }, set: { editor.dropdownOptions = $0 })
                )
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    @ViewBuilder private var cropSection: some View {
        StudioInspectorGroup("Crop") {
            Button("Apply to this page") { editor.applyCrop(toAllPages: false) }
                .buttonStyle(.edith(.primary))
                .disabled(editor.cropRect == nil)
            Button("Apply to every page") { editor.applyCrop(toAllPages: true) }
                .buttonStyle(.edith(.secondary))
                .disabled(editor.cropRect == nil)
            Divider()
            Button("Trim white margins on every page") { editor.trimAllMargins() }
                .buttonStyle(.edith(.secondary))
        }
    }

    @ViewBuilder private var organizeSection: some View {
        StudioInspectorGroup("Selected pages") {
            let pages = editor.pageSelection
            Text(pages.isEmpty ? "Select pages with their checkboxes." : "\(pages.count) selected")
                .font(.system(size: UIScale.pt(11.5)))
            Button("Rotate right") { editor.rotate(Array(pages), by: 90) }
                .buttonStyle(.edith(.secondary)).disabled(pages.isEmpty)
            Button("Rotate left") { editor.rotate(Array(pages), by: -90) }
                .buttonStyle(.edith(.secondary)).disabled(pages.isEmpty)
            Button("Save selected as new PDF…") { editor.extract(pages) }
                .buttonStyle(.edith(.secondary)).disabled(pages.isEmpty)
            Button("Delete selected") { editor.delete(pages) }
                .buttonStyle(.edith(.destructive)).disabled(
                    pages.isEmpty || pages.count >= editor.pageCount)
        }
        StudioInspectorGroup("Add pages") {
            Button("Insert blank page at end") { editor.insertBlank(after: editor.pageCount - 1) }
                .buttonStyle(.edith(.secondary))
            Button("Insert PDF or image at end…") { editor.insertFile(after: editor.pageCount - 1) }
                .buttonStyle(.edith(.secondary))
        }
    }

    @ViewBuilder private func selectionSection(_ selected: PDFAnnotation) -> some View {
        StudioInspectorGroup("Selection") {
            if selected.type == "FreeText" {
                TextField(
                    "Text",
                    text: Binding(
                        get: { selected.contents ?? "" }, set: { editor.updateSelectedText($0) }),
                    axis: .vertical
                )
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            }
            HStack {
                Button("Apply style") { editor.applyStyleToSelection() }
                    .buttonStyle(.edith(.secondary))
                Button("Delete") { editor.deleteSelected() }
                    .buttonStyle(.edith(.destructive))
            }
        }
    }
}

struct StudioInspectorGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    init(_ title: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Text(title.uppercased())
                .font(DashSkin.mono(9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .controlSize(.small)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct StudioPDFStyleControls: View {
    @Binding var style: PDFEditSession.Style
    let showsFont: Bool

    private let swatches = [
        "#D9211A", "#F5A623", "#F8E71C", "#34C759", "#1E88E5", "#8E44AD", "#000000", "#FFFFFF",
    ]

    var body: some View {
        StudioInspectorGroup("Style") {
            HStack(spacing: UIScale.pt(5)) {
                ForEach(swatches, id: \.self) { hex in
                    let color = StudioColor(hex: hex) ?? .black
                    Button {
                        style.color = color
                    } label: {
                        Circle()
                            .fill(Color(cgColor: color.cgColor))
                            .frame(width: UIScale.pt(18), height: UIScale.pt(18))
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(style.color == color ? 0.9 : 0.2),
                                    lineWidth: style.color == color ? 2 : 1)
                            )
                            .edithButtonTarget(.borderless)
                    }
                    .buttonStyle(.edith(.borderless))
                    .help(hex)
                }
            }
            HStack {
                Text("Line").font(.system(size: UIScale.pt(11)))
                Slider(value: $style.lineWidth, in: 0.5...12, step: 0.5)
                Text(String(format: "%.1f", style.lineWidth)).font(DashSkin.mono(10)).frame(
                    width: 30)
            }
            Toggle(
                "Fill shapes",
                isOn: Binding(
                    get: { style.fill != nil },
                    set: {
                        style.fill =
                            $0
                            ? StudioColor(
                                red: style.color.red, green: style.color.green,
                                blue: style.color.blue, alpha: 0.25) : nil
                    })
            )
            if showsFont {
                StudioFontField(family: $style.fontName)
                HStack {
                    Text("Size").font(.system(size: UIScale.pt(11)))
                    Slider(value: $style.fontSize, in: 6...72, step: 1)
                    Text("\(Int(style.fontSize))").font(DashSkin.mono(10)).frame(width: 30)
                }
            }
        }
    }
}

enum StudioPDFHelp {
    static func text(for mode: StudioPDFEditorMode, tool: StudioPDFTool) -> String {
        switch (mode, tool) {
        case (.organize, _): "Drag pages to reorder. Hover a page for rotate, duplicate and delete."
        case (_, .select):
            "Click an annotation to select it, drag to move it, press Delete to remove it."
        case (_, .fill): "Click a field to type into it. Checkboxes toggle with a click."
        case (_, .text): "Click where the text should go. Edit it in Selection afterwards."
        case (_, .draw): "Drag to draw freehand."
        case (_, .highlight), (_, .underline), (_, .strike): "Select text on the page to mark it."
        case (_, .note): "Click to pin a note to the page."
        case (_, .image): "Choose an image, then click or drag on the page to place it."
        case (_, .signature): "Pick a signature, then click or drag on the page to place it."
        case (_, .redact):
            "Drag over anything to remove. Saving flattens those pages so the content is gone for good."
        case (_, .crop): "Drag the area to keep, then apply it to this page or every page."
        case (_, .textField), (_, .checkbox), (_, .dropdown): "Drag on the page to add the field."
        default: "Drag on the page to draw the shape."
        }
    }
}
