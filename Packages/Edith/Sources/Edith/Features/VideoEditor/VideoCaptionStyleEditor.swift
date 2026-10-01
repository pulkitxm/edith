import SwiftUI
import EdithKit

struct VideoCaptionStyleEditor: View {
    let caption: VideoProject.Annotation
    let model: VideoEditorModel
    private var draft: VideoCaptionDraft { model.captionDraft(caption) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reference-canvas pixels, top-origin Y").font(.caption).foregroundStyle(.secondary)
            TextField("Font family", text: field("fontFamily"))
            TextField("Font style", text: field("fontStyle"))
            number("Canvas width", key: "canvasWidth")
            number("Canvas height", key: "canvasHeight")
            number("Font size", key: "fontSize")
            number("Line advance", key: "lineAdvance")
            Picker("Font metrics", selection: field("metrics")) {
                Text("Typographic").tag("typographic")
                Text("Integer font bounds").tag("fontBounds")
            }
            Picker("Alignment", selection: field("alignment")) {
                Text("Left").tag("left")
                Text("Center").tag("center")
                Text("Right").tag("right")
            }
            Picker("Vertical anchor", selection: field("anchor")) {
                Text("Top").tag("top")
                Text("Center").tag("center")
                Text("Bottom").tag("bottom")
            }
            number("X", key: "x")
            number("Y", key: "y")
            number("Text width", key: "width")
            Button("Apply style") { draft.apply("style") }
            DisclosureGroup("Fill, outline, shadow & gradient JSON") {
                Text("RGBA channels use 0 through 1. Omit optional effects to remove them.")
                    .font(.caption).foregroundStyle(.secondary)
                TextEditor(text: field("json")).font(.system(.caption, design: .monospaced)).frame(
                    height: UIScale.pt(240))
                Button("Apply JSON") { draft.apply("json") }
            }
            Button("Discard caption drafts") { draft.refresh(discard: true) }
            if let failure = draft.failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }
        .onAppear { draft.refresh() }
        .onChange(of: caption.captionStyle) { _, _ in draft.refresh() }
    }

    private func field(_ key: String) -> Binding<String> {
        Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0 })
    }

    private func number(_ title: String, key: String) -> some View {
        HStack {
            Text(title)
            TextField(title, text: field(key)).accessibilityLabel(title)
        }
    }
}
