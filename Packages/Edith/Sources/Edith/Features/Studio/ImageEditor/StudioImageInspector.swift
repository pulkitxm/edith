import AppKit
import EdithKit
import EdithStudio
import SwiftUI

struct StudioImageInspector: View {
    let editor: StudioImageEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: UIScale.pt(18)) {
                Text(editor.panel.title)
                    .font(.system(size: UIScale.pt(14), weight: .semibold))
                switch editor.panel {
                case .crop: StudioImageCropPanel(editor: editor)
                case .adjust: StudioImageAdjustPanel(editor: editor)
                case .filters: StudioImageFilterPanel(editor: editor)
                case .text: StudioImageTextPanel(editor: editor)
                case .draw: StudioImageDrawPanel(editor: editor)
                case .shapes: StudioImageShapePanel(editor: editor)
                case .stickers: StudioImageStickerPanel(editor: editor)
                case .blur: StudioImageBlurPanel(editor: editor)
                case .frame: StudioImageFramePanel(editor: editor)
                case .export: StudioImageExportPanel(editor: editor)
                }
                if !editor.document.layers.isEmpty {
                    StudioImageLayerList(editor: editor)
                }
            }
            .padding(UIScale.pt(16))
            .controlSize(.small)
        }
    }
}

struct StudioImageCropPanel: View {
    let editor: StudioImageEditorModel

    private let ratios: [(String, Double?)] = [
        ("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5),
        ("16:9", 16.0 / 9),
        ("9:16", 9.0 / 16), ("4:5", 0.8),
    ]

    var body: some View {
        StudioInspectorGroup("Aspect ratio") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(56)))], spacing: UIScale.pt(6)
            ) {
                ForEach(ratios, id: \.0) { ratio in
                    Button(ratio.0) { apply(ratio.1) }
                        .buttonStyle(.edith(.secondary))
                }
            }
        }
        StudioInspectorGroup("Rotate and flip") {
            HStack {
                iconButton("rotate.left", "Rotate left") {
                    editor.edit { $0.rotateCounterclockwise() }
                }
                iconButton("rotate.right", "Rotate right") { editor.edit { $0.rotateClockwise() } }
                iconButton(
                    "arrow.left.and.right.righttriangle.left.righttriangle.right", "Flip horizontal"
                ) {
                    editor.edit { $0.flipHorizontally() }
                }
                iconButton("arrow.up.and.down.righttriangle.up.righttriangle.down", "Flip vertical")
                {
                    editor.edit { $0.flipVertically() }
                }
            }
        }
        StudioInspectorGroup("Straighten") {
            StudioImageSlider(
                value: editor.document.straighten, range: -45...45,
                format: { "\(Int($0.rounded()))°" }
            ) { value, live in
                if live {
                    editor.preview { $0.straighten = value }
                } else {
                    editor.edit { $0.straighten = value }
                }
            }
        }
        Button("Reset crop and rotation") { editor.edit { $0.resetGeometry() } }
            .buttonStyle(.edith(.secondary))
    }

    private func apply(_ ratio: Double?) {
        guard let geometry = editor.geometry else { return }
        let size = CGSize(width: geometry.width, height: geometry.height)
        guard let ratio else { return }
        let target = ratio < 0 ? size.width / max(size.height, 1) : ratio
        editor.edit { $0.crop = ImageEditGeometry.aspectCrop(target, in: size) }
    }

    private func iconButton(_ symbol: String, _ help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol).frame(width: UIScale.pt(30), height: UIScale.pt(24))
        }
        .buttonStyle(.edith(.secondary))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct StudioImageSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let change: (Double, Bool) -> Void
    @State private var draft: Double?

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            Slider(
                value: Binding(
                    get: { draft ?? value },
                    set: { newValue in
                        draft = newValue
                        change(newValue, true)
                    }), in: range
            ) { editing in
                if !editing, let draft {
                    change(draft, false)
                    self.draft = nil
                }
            }
            Text(format(draft ?? value))
                .font(DashSkin.mono(10))
                .foregroundStyle(.secondary)
                .frame(width: UIScale.pt(40), alignment: .trailing)
        }
    }
}

struct StudioImageAdjustPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        ForEach(ImageAdjustments.Key.allCases, id: \.self) { key in
            VStack(alignment: .leading, spacing: UIScale.pt(3)) {
                HStack {
                    Label(key.title, systemImage: key.symbolName)
                        .font(.system(size: UIScale.pt(11.5)))
                    Spacer()
                    if abs(editor.document.adjustments[key]) > 0.0001 {
                        Button("Reset") { editor.edit { $0.adjustments[key] = 0 } }
                            .buttonStyle(.edith(.toolbar))
                            .font(.system(size: UIScale.pt(10)))
                    }
                }
                StudioImageSlider(
                    value: editor.document.adjustments[key], range: key.range,
                    format: { String(format: "%+.0f", $0 * 100) }
                ) { value, live in
                    if live {
                        editor.preview { $0.adjustments[key] = value }
                    } else {
                        editor.edit { $0.adjustments[key] = value }
                    }
                }
            }
        }
        Button("Reset all adjustments") { editor.edit { $0.adjustments = ImageAdjustments() } }
            .buttonStyle(.edith(.secondary))
            .disabled(editor.document.adjustments.isNeutral)
    }
}

struct StudioImageFilterPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: UIScale.pt(72)), spacing: UIScale.pt(8))],
            spacing: UIScale.pt(10)
        ) {
            ForEach(ImageFilterPreset.allCases, id: \.self) { preset in
                Button {
                    editor.edit { $0.filter = preset }
                } label: {
                    VStack(spacing: UIScale.pt(4)) {
                        Group {
                            if let thumbnail = editor.filterThumbnails[preset] {
                                Image(decorative: thumbnail, scale: 1).resizable().aspectRatio(
                                    contentMode: .fill)
                            } else {
                                Rectangle().fill(Color.gray.opacity(0.2))
                            }
                        }
                        .frame(width: UIScale.pt(68), height: UIScale.pt(56))
                        .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIScale.pt(6))
                                .strokeBorder(
                                    editor.document.filter == preset
                                        ? Color.accentColor : Color.clear, lineWidth: 2.5))
                        Text(preset.title).font(.system(size: UIScale.pt(10.5)))
                    }
                    .edithButtonTarget(.borderless)
                }
                .buttonStyle(.edith(.borderless))
                .accessibilityLabel(preset.title)
            }
        }
        if editor.document.filter != .none {
            StudioInspectorGroup("Intensity") {
                StudioImageSlider(
                    value: editor.document.filterIntensity, range: 0...1,
                    format: { "\(Int(($0 * 100).rounded()))%" }
                ) { value, live in
                    if live {
                        editor.preview { $0.filterIntensity = value }
                    } else {
                        editor.edit { $0.filterIntensity = value }
                    }
                }
            }
        }
    }
}

struct StudioImageTextPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        HStack {
            Button {
                editor.addText()
            } label: {
                Label("Add text", systemImage: "plus")
            }
            .buttonStyle(.edith(.primary))
            Button("Meme") { editor.addMeme() }
                .buttonStyle(.edith(.secondary))
                .help("Add top and bottom meme captions")
        }
        Text(
            "Click the picture to add text there. Drag text to move it, drag the corner to resize."
        )
        .font(.system(size: UIScale.pt(11)))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        if let layer = editor.selected, case let .text(style) = layer.content {
            StudioImageTextStyleEditor(editor: editor, style: style)
        }
    }
}

struct StudioImageTextStyleEditor: View {
    let editor: StudioImageEditorModel
    let style: ImageTextStyle

    var body: some View {
        StudioInspectorGroup("Selected text") {
            TextField("Text", text: bind(\.text), axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...5)
            StudioFontField(family: bind(\.font))
            HStack {
                Text("Size").font(.system(size: UIScale.pt(11)))
                StudioImageSlider(
                    value: style.size, range: 0.02...0.3,
                    format: { String(format: "%.0f", $0 * 100) }
                ) {
                    value, _ in
                    editor.updateSelected { layer in Self.modify(&layer) { $0.size = value } }
                }
            }
            HStack {
                StudioColorField(hex: bind(\.color))
            }
            HStack {
                Toggle("Bold", isOn: bind(\.bold)).toggleStyle(.checkbox)
                Toggle("Italic", isOn: bind(\.italic)).toggleStyle(.checkbox)
                Toggle("Shadow", isOn: bind(\.shadow)).toggleStyle(.checkbox)
            }
            Picker("Align", selection: bind(\.alignment)) {
                ForEach(ImageTextAlignment.allCases, id: \.self) {
                    Text($0.rawValue.capitalized).tag($0)
                }
            }
            .pickerStyle(.segmented)
            Toggle(
                "Outline",
                isOn: Binding(
                    get: { style.strokeColor != nil && style.strokeWidth > 0 },
                    set: { on in
                        editor.updateSelected { layer in
                            Self.modify(&layer) {
                                $0.strokeColor = on ? "#000000" : nil
                                $0.strokeWidth = on ? 3 : 0
                            }
                        }
                    })
            )
            .toggleStyle(.checkbox)
            Toggle(
                "Background",
                isOn: Binding(
                    get: { style.background != nil },
                    set: { on in
                        editor.updateSelected { layer in
                            Self.modify(&layer) { $0.background = on ? "#000000AA" : nil }
                        }
                    })
            )
            .toggleStyle(.checkbox)
        }
    }

    private func bind<Value>(_ path: WritableKeyPath<ImageTextStyle, Value>) -> Binding<Value> {
        Binding(
            get: { style[keyPath: path] },
            set: { value in
                editor.updateSelected { layer in Self.modify(&layer) { $0[keyPath: path] = value } }
            })
    }

    static func modify(_ layer: inout ImageLayer, _ change: (inout ImageTextStyle) -> Void) {
        guard case var .text(style) = layer.content else { return }
        change(&style)
        layer.content = .text(style)
    }
}

struct StudioImageDrawPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        Text("Drag on the picture to draw.")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(.secondary)
        StudioInspectorGroup("Brush") {
            StudioColorField(
                hex: Binding(get: { editor.drawColor }, set: { editor.drawColor = $0 }))
            HStack {
                Text("Width").font(.system(size: UIScale.pt(11)))
                StudioImageSlider(
                    value: editor.drawWidth, range: 0.002...0.05,
                    format: { String(format: "%.1f", $0 * 100) }
                ) {
                    value, _ in editor.drawWidth = value
                }
            }
            Toggle(
                "Highlighter",
                isOn: Binding(get: { editor.highlighter }, set: { editor.highlighter = $0 })
            )
            .toggleStyle(.checkbox)
        }
    }
}

struct StudioImageShapePanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        Picker(
            "Shape", selection: Binding(get: { editor.shapeKind }, set: { editor.shapeKind = $0 })
        ) {
            ForEach(ImageShapeKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
        }
        .pickerStyle(.segmented)
        Text("Drag on the picture to add the shape.")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(.secondary)
        StudioColorField(hex: Binding(get: { editor.shapeColor }, set: { editor.shapeColor = $0 }))
        Toggle("Fill", isOn: Binding(get: { editor.shapeFill }, set: { editor.shapeFill = $0 }))
            .toggleStyle(.checkbox)
    }
}

struct StudioImageStickerPanel: View {
    let editor: StudioImageEditorModel

    static let stickers = [
        "😀", "😂", "😍", "😎", "🤔", "😮", "😢", "😡", "👍", "👎", "👏", "🙌", "🔥", "✨", "⭐️", "❤️",
        "💯", "✅", "❌", "⚠️", "➡️", "⬅️", "⬆️", "⬇️", "🎉", "🎂", "📌", "💡", "🚀", "🐶", "🐱", "🌈",
    ]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: UIScale.pt(34)))], spacing: UIScale.pt(6)) {
            ForEach(Self.stickers, id: \.self) { sticker in
                Button {
                    editor.addSticker(sticker)
                } label: {
                    Text(sticker).font(.system(size: UIScale.pt(22))).frame(
                        width: UIScale.pt(34), height: UIScale.pt(34))
                }
                .buttonStyle(.edith(.iconOnly))
            }
        }
        Button {
            editor.addImageLayer()
        } label: {
            Label("Add an image or logo…", systemImage: "photo.badge.plus")
        }
        .buttonStyle(.edith(.secondary))
    }
}

struct StudioImageBlurPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        Picker(
            "Style",
            selection: Binding(get: { editor.redactStyle }, set: { editor.redactStyle = $0 })
        ) {
            ForEach(ImageRedactionStyle.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        HStack {
            Text("Strength").font(.system(size: UIScale.pt(11)))
            StudioImageSlider(
                value: editor.redactStrength, range: 0.1...1,
                format: { "\(Int(($0 * 100).rounded()))%" }
            ) {
                value, _ in editor.redactStrength = value
            }
        }
        Text("Drag over faces, plates, names or anything private.")
            .font(.system(size: UIScale.pt(11)))
            .foregroundStyle(.secondary)
        Button {
            editor.blurFaces()
        } label: {
            Label("Blur faces automatically", systemImage: "face.dashed")
        }
        .buttonStyle(.edith(.secondary))
    }
}

struct StudioImageFramePanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        Picker(
            "Frame",
            selection: Binding(
                get: { editor.document.frame?.kind.rawValue ?? "none" },
                set: { value in
                    editor.edit { document in
                        if let kind = ImageFrameKind(rawValue: value) {
                            var frame = document.frame ?? ImageFrameStyle()
                            frame.kind = kind
                            document.frame = frame
                        } else {
                            document.frame = nil
                        }
                    }
                })
        ) {
            Text("None").tag("none")
            ForEach(ImageFrameKind.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
        }
        if let frame = editor.document.frame {
            HStack {
                Text("Width").font(.system(size: UIScale.pt(11)))
                StudioImageSlider(
                    value: frame.width, range: 0.005...0.2,
                    format: { String(format: "%.0f", $0 * 100) }
                ) {
                    value, live in
                    if live {
                        editor.preview { $0.frame?.width = value }
                    } else {
                        editor.edit { $0.frame?.width = value }
                    }
                }
            }
            StudioColorField(
                hex: Binding(
                    get: { frame.color }, set: { value in editor.edit { $0.frame?.color = value } })
            )
        }
    }
}

struct StudioImageExportPanel: View {
    let editor: StudioImageEditorModel

    var body: some View {
        StudioInspectorGroup("Format") {
            Picker(
                "Format",
                selection: Binding(
                    get: { editor.document.export.format?.rawValue ?? "auto" },
                    set: { value in
                        editor.edit { $0.export.format = StudioImageFormat(rawValue: value) }
                    })
            ) {
                Text("Same as original").tag("auto")
                ForEach(
                    StudioImageFormat.writable.filter { $0 != .pdf && $0 != .icns && $0 != .ico },
                    id: \.self
                ) {
                    Text($0.title).tag($0.rawValue)
                }
            }
            if editor.document.outputFormat.isLossy {
                HStack {
                    Text("Quality").font(.system(size: UIScale.pt(11)))
                    StudioImageSlider(
                        value: editor.document.export.quality, range: 0.3...1,
                        format: { "\(Int(($0 * 100).rounded()))%" }
                    ) {
                        value, _ in editor.edit { $0.export.quality = value }
                    }
                }
            }
        }
        StudioInspectorGroup("Size") {
            Picker(
                "Longest side",
                selection: Binding(
                    get: { editor.document.export.maxDimension ?? 0 },
                    set: { value in
                        editor.edit { $0.export.maxDimension = value == 0 ? nil : value }
                    })
            ) {
                Text("Original size").tag(0)
                ForEach([4096, 3000, 2048, 1600, 1280, 1080, 800, 512], id: \.self) {
                    Text("\($0) px").tag($0)
                }
            }
            Text("Saves as \(editor.document.outputFormat.title).")
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(.secondary)
        }
    }
}

struct StudioImageLayerList: View {
    let editor: StudioImageEditorModel

    var body: some View {
        StudioInspectorGroup("Layers") {
            ForEach(editor.document.layers.reversed()) { layer in
                HStack(spacing: UIScale.pt(6)) {
                    Button {
                        editor.selectedLayer = layer.id
                    } label: {
                        Text(layer.title)
                            .font(
                                .system(
                                    size: UIScale.pt(11.5),
                                    weight: editor.selectedLayer == layer.id ? .semibold : .regular)
                            )
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .edithButtonTarget(.borderless)
                    }
                    .buttonStyle(.edith(.borderless))
                    Button {
                        editor.edit { $0.updateLayer(layer.id) { $0.isHidden.toggle() } }
                    } label: {
                        Image(systemName: layer.isHidden ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help(layer.isHidden ? "Show" : "Hide")
                    Button {
                        editor.edit { $0.moveLayer(layer.id, by: 1) }
                    } label: {
                        Image(systemName: "arrow.up")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Bring forward")
                    Button {
                        editor.selectedLayer = layer.id
                        editor.deleteSelected()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Delete layer")
                }
            }
        }
    }
}
