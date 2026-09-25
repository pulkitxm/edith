import AppKit
import EdithKit
import EdithStudio
import PDFKit
import SwiftUI

struct StudioPDFOrganizeGrid: View {
    let editor: StudioPDFEditorModel
    @State private var targeted: Int?

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: UIScale.pt(150)), spacing: UIScale.pt(16))],
                spacing: UIScale.pt(18)
            ) {
                ForEach(0..<editor.pageCount, id: \.self) { index in
                    StudioPDFPageTile(editor: editor, index: index, targeted: targeted == index)
                        .draggable(String(index))
                        .dropDestination(for: String.self) { items, _ in
                            guard let first = items.first, let from = Int(first), from != index
                            else {
                                return false
                            }
                            editor.move(from, to: index)
                            return true
                        } isTargeted: {
                            targeted = $0 ? index : (targeted == index ? nil : targeted)
                        }
                }
            }
            .padding(UIScale.pt(20))
        }
    }
}

struct StudioPDFPageTile: View {
    let editor: StudioPDFEditorModel
    let index: Int
    let targeted: Bool
    @State private var hovering = false
    @State private var image: NSImage?
    @Environment(\.colorScheme) private var scheme

    private var selected: Bool { editor.pageSelection.contains(index) }

    var body: some View {
        VStack(spacing: UIScale.pt(6)) {
            ZStack(alignment: .topLeading) {
                Group {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.white).aspectRatio(0.77, contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: UIScale.pt(180))
                .background(DashSkin.grid(scheme == .dark))
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(6))
                        .strokeBorder(
                            selected || targeted
                                ? DashSkin.accent(scheme == .dark) : DashSkin.line(scheme == .dark),
                            lineWidth: selected || targeted ? 2.5 : 1))
                Button {
                    if selected {
                        editor.pageSelection.remove(index)
                    } else {
                        editor.pageSelection.insert(index)
                    }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: UIScale.pt(16)))
                        .foregroundStyle(
                            selected ? DashSkin.accent(scheme == .dark) : Color.secondary
                        )
                        .background(Circle().fill(Color.white).padding(1))
                }
                .buttonStyle(.edith(.iconOnly))
                .padding(UIScale.pt(6))
                .opacity(selected || hovering ? 1 : 0.001)
                .accessibilityLabel("Select page \(index + 1)")
                if hovering {
                    HStack(spacing: UIScale.pt(2)) {
                        tileButton("rotate.left", "Rotate left") { editor.rotate([index], by: -90) }
                        tileButton("rotate.right", "Rotate right") {
                            editor.rotate([index], by: 90)
                        }
                        tileButton("plus.square.on.square", "Duplicate") { editor.duplicate(index) }
                        tileButton("doc.badge.plus", "Insert blank page after") {
                            editor.insertBlank(after: index)
                        }
                        tileButton("trash", "Delete") { editor.delete([index]) }
                            .disabled(editor.pageCount <= 1)
                    }
                    .padding(UIScale.pt(4))
                    .background(.regularMaterial, in: Capsule())
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, UIScale.pt(8))
                }
            }
            Text("\(index + 1)")
                .font(DashSkin.mono(11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .onHover { hovering = $0 }
        .task(id: "\(index)-\(editor.revision)") {
            guard let page = editor.session?.page(index) else { return }
            image = page.thumbnail(of: CGSize(width: 300, height: 380), for: .cropBox)
        }
    }

    private func tileButton(_ symbol: String, _ help: String, action: @escaping () -> Void)
        -> some View
    {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: UIScale.pt(11.5)))
                .frame(width: UIScale.pt(24), height: UIScale.pt(22))
        }
        .buttonStyle(.edith(.iconOnly))
        .help(help)
        .accessibilityLabel(help)
    }
}

struct StudioSignaturePad: View {
    enum Mode: String, CaseIterable {
        case draw = "Draw"
        case type = "Type"
        case image = "Image"
    }

    let save: (CGImage) -> Void
    let cancel: () -> Void
    @State private var mode: Mode = .draw
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    @State private var typed = ""
    @State private var font = "Snell Roundhand"
    @State private var color = StudioColor(red: 0.07, green: 0.14, blue: 0.47)
    @State private var imported: CGImage?
    @State private var removeBackground = true

    static let fonts = [
        "Snell Roundhand", "Zapfino", "Bradley Hand", "Noteworthy", "Savoye LET", "Apple Chancery",
        "Marker Felt",
    ]
    let canvas = CGSize(width: 460, height: 170)

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Text("New signature").font(.system(size: UIScale.pt(16), weight: .semibold))
            Picker("", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.white)
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.black.opacity(0.15))
                Rectangle().fill(Color.black.opacity(0.15)).frame(height: 1).padding(
                    .horizontal, 30
                ).offset(y: 40)
                content
            }
            .frame(width: canvas.width, height: canvas.height)
            HStack(spacing: UIScale.pt(6)) {
                ForEach(["#12236F", "#000000", "#1E6E3C", "#8E1B1B"], id: \.self) { hex in
                    let swatch = StudioColor(hex: hex) ?? .black
                    Button {
                        color = swatch
                    } label: {
                        Circle().fill(Color(cgColor: swatch.cgColor)).frame(width: 18, height: 18)
                            .overlay(
                                Circle().strokeBorder(
                                    Color.primary.opacity(color == swatch ? 0.9 : 0.15),
                                    lineWidth: 2))
                    }
                    .buttonStyle(.edith(.iconOnly))
                }
                Spacer()
                if mode == .draw {
                    Button("Clear") {
                        strokes = []
                        current = []
                    }
                    .buttonStyle(.edith(.toolbar))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", action: cancel).buttonStyle(.edith(.secondary)).keyboardShortcut(
                    .cancelAction)
                Button("Save signature") {
                    if let image = render() { save(image) }
                }
                .buttonStyle(.edith(.primary))
                .keyboardShortcut(.defaultAction)
                .disabled(render() == nil)
            }
        }
        .padding(UIScale.pt(22))
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .draw:
            Canvas { context, _ in
                for stroke in strokes + [current] where stroke.count > 1 {
                    var path = Path()
                    path.addLines(stroke)
                    context.stroke(
                        path, with: .color(Color(cgColor: color.cgColor)),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in current.append(value.location) }
                    .onEnded { _ in
                        strokes.append(current)
                        current = []
                    }
            )
            .overlay(alignment: .topLeading) {
                if strokes.isEmpty && current.isEmpty {
                    Text("Sign with your mouse or trackpad").foregroundStyle(.gray).padding(12)
                }
            }
        case .type:
            VStack {
                TextField("Your name", text: $typed)
                    .textFieldStyle(.plain)
                    .font(.custom(font, size: 40))
                    .foregroundStyle(Color(cgColor: color.cgColor))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
                Picker("Style", selection: $font) {
                    ForEach(Self.fonts.filter { NSFont(name: $0, size: 12) != nil }, id: \.self) {
                        Text($0).font(.custom($0, size: 14)).tag($0)
                    }
                }
                .frame(width: 220)
            }
        case .image:
            VStack(spacing: 10) {
                if let imported {
                    Image(decorative: imported, scale: 1).resizable().aspectRatio(contentMode: .fit)
                        .padding(12)
                }
                HStack {
                    Button(imported == nil ? "Choose image…" : "Change…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.image]
                        if panel.runModal() == .OK, let url = panel.url {
                            imported = try? StudioImageIO.load(url, maxPixelSize: 1600)
                        }
                    }
                    .buttonStyle(.edith(.secondary))
                    Toggle("Remove white background", isOn: $removeBackground).toggleStyle(
                        .checkbox)
                }
            }
        }
    }

    private func render() -> CGImage? {
        switch mode {
        case .draw:
            let all = strokes + (current.isEmpty ? [] : [current])
            guard all.contains(where: { $0.count > 1 }) else { return nil }
            return StudioSignature.drawn(all, canvas: canvas, color: color)
        case .type:
            let text = typed.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            return StudioSignature.typed(text, font: font, color: color)
        case .image:
            guard let imported else { return nil }
            return removeBackground ? StudioSignature.cleaned(imported) : imported
        }
    }
}
