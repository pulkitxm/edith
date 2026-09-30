import SwiftUI

struct VideoCaptionStyleEditor: View {
    let caption: VideoProject.Annotation
    let model: VideoEditorModel
    @State private var style = VideoCaptionStyle()
    @State private var json = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference-canvas pixels, top-origin Y").font(.caption).foregroundStyle(.secondary)
            TextField("Font family", text: $style.fontFamily)
            TextField("Font style", text: $style.fontStyle)
            number("Canvas width", value: $style.canvasWidth)
            number("Canvas height", value: $style.canvasHeight)
            number("Font size", value: $style.fontSize)
            number("Line advance", value: $style.lineAdvance)
            Picker(
                "Font metrics",
                selection: Binding(
                    get: { style.metrics ?? .typographic }, set: { style.metrics = $0 })
            ) {
                Text("Typographic").tag(VideoCaptionStyle.Metrics.typographic)
                Text("Integer font bounds").tag(VideoCaptionStyle.Metrics.fontBounds)
            }
            Picker("Alignment", selection: $style.alignment) {
                Text("Left").tag(VideoCaptionStyle.Alignment.left)
                Text("Center").tag(VideoCaptionStyle.Alignment.center)
                Text("Right").tag(VideoCaptionStyle.Alignment.right)
            }
            Picker("Vertical anchor", selection: $style.anchor) {
                Text("Top").tag(VideoCaptionStyle.Anchor.top)
                Text("Center").tag(VideoCaptionStyle.Anchor.center)
                Text("Bottom").tag(VideoCaptionStyle.Anchor.bottom)
            }
            number("X", value: $style.x)
            number("Y", value: $style.y)
            number("Text width", value: $style.width)
            Button("Apply style") { apply(style) }
            DisclosureGroup("Fill, outline, shadow & gradient JSON") {
                Text("RGBA channels use 0 through 1. Omit optional effects to remove them.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $json).font(.system(.caption, design: .monospaced)).frame(
                    height: 240)
                Button("Apply JSON") {
                    do { apply(try VideoCaptionStyle.decode(Data(json.utf8))) } catch {
                        failure = error.localizedDescription
                    }
                }
            }
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { refresh() }
        .onChange(of: caption.captionStyle) { _, _ in refresh() }
    }

    private func number(_ title: String, value: Binding<Double>) -> some View {
        HStack {
            Text(title)
            TextField(title, value: value, format: .number).accessibilityLabel(title)
        }
    }

    private func refresh() {
        style = caption.captionStyle ?? VideoCaptionStyle()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        json = (try? encoder.encode(style)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func apply(_ requested: VideoCaptionStyle) {
        do {
            _ = try VideoStyledCaptionImage.layout(caption.text, style: requested)
            var raw = caption.raw
            try requested.store(in: &raw)
            model.mutate { $0.editRegion("annotations", id: caption.id) { $0 = raw } }
            style = requested
            failure = nil
            model.rebuild()
        } catch { failure = error.localizedDescription }
    }
}
