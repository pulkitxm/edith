import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class CaptureEditorController: NSObject, NSWindowDelegate {
    private let panel: NSPanel
    private let model: CaptureEditorModel
    private let item: CaptureLibraryItem
    private let updated: () -> Void

    init?(
        item: CaptureLibraryItem, image: NSImage, updated: @escaping () -> Void,
        pin: @escaping (Data) -> Void
    ) {
        guard let model = CaptureEditorModel(image: image) else { return nil }
        self.model = model
        self.item = item
        self.updated = updated
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 700),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false)
        super.init()
        panel.title = "Capture Studio"
        panel.minSize = NSSize(width: 760, height: 540)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(
            rootView: CaptureEditorView(
                model: model,
                copy: { [weak self] in self?.copy() },
                save: { [weak self] in self?.save() },
                pin: { [weak self] in
                    guard let data = try? self?.model.exportData() else { return }
                    pin(data)
                },
                done: { [weak self] in self?.commit() }))
    }

    func show() {
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        panel.close()
        panel.contentView = nil
    }

    private func copy() {
        guard let data = try? model.exportData() else {
            NSSound.beep()
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        IPC.post(IPC.Name.clipboardChanged)
    }

    private func save() {
        guard let data = try? model.exportData(),
            let url = try? CaptureSaveLocation.save(data, mode: item.mode)
        else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func commit() {
        guard let data = try? model.exportData(),
            (try? CaptureLibraryStore.replace(item, with: data)) != nil
        else {
            NSSound.beep()
            return
        }
        updated()
        close()
    }
}

private struct CaptureEditorView: View {
    @Bindable var model: CaptureEditorModel
    let copy: () -> Void
    let save: () -> Void
    let pin: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            CaptureEditorCanvas(model: model)
                .padding(18)
            Divider()
            footer
        }
        .frame(minWidth: 760, minHeight: 540)
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            ForEach(CaptureEditTool.allCases, id: \.self) { tool in
                Button {
                    model.tool = tool
                } label: {
                    Label(tool.displayName, systemImage: tool.systemImage)
                        .labelStyle(.iconOnly)
                        .frame(width: 26, height: 24)
                }
                .help(tool.displayName)
                .buttonStyle(.bordered)
                .tint(model.tool == tool ? .accentColor : nil)
            }
            Divider().frame(height: 24)
            ColorPicker("Color", selection: $model.color, supportsOpacity: false)
                .labelsHidden()
                .frame(width: 32)
            Slider(value: $model.strokeWidth, in: 2...14)
                .frame(width: 100)
            if model.tool == .text {
                TextField("Text", text: $model.text)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 180)
            }
            Spacer()
            Button(action: model.undo) {
                Label("Undo", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.document.annotations.isEmpty && model.document.cropRect == nil)
            if model.document.cropRect != nil {
                Button("Reset crop", action: model.resetCrop)
            }
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            Picker("Frame", selection: $model.document.backdrop) {
                ForEach(CaptureBackdrop.allCases, id: \.self) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 300)
            Spacer()
            Button("Copy PNG", action: copy)
            Button("Save", action: save)
            Button("Pin", action: pin)
            Button("Done", action: done)
                .keyboardShortcut(.defaultAction)
        }
        .padding(12)
    }
}

private struct CaptureEditorCanvas: View {
    @Bindable var model: CaptureEditorModel

    var body: some View {
        GeometryReader { geometry in
            let frame = fittedRect(in: geometry.size)
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.black.opacity(0.08))
                Image(nsImage: model.sourceImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
                Canvas { context, _ in
                    for annotation in model.document.annotations {
                        draw(annotation, in: &context, frame: frame)
                    }
                    if let draft = model.draft {
                        draw(draft, in: &context, frame: frame)
                    }
                    if let crop = model.document.cropRect {
                        let mapped = map(crop, to: frame)
                        context.stroke(
                            Path(mapped), with: .color(.white),
                            style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                    }
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = sourcePoint(value.location, frame: frame)
                            if model.draft == nil {
                                model.begin(at: point)
                            } else {
                                model.move(to: point)
                            }
                        }
                        .onEnded { value in
                            model.end(at: sourcePoint(value.location, frame: frame))
                        })
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    private func fittedRect(in size: CGSize) -> CGRect {
        let scale = min(size.width / model.sourceSize.width, size.height / model.sourceSize.height)
        let fitted = CGSize(width: model.sourceSize.width * scale, height: model.sourceSize.height * scale)
        return CGRect(
            x: (size.width - fitted.width) / 2, y: (size.height - fitted.height) / 2,
            width: fitted.width, height: fitted.height)
    }

    private func sourcePoint(_ point: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(
            x: (point.x - frame.minX) / frame.width * model.sourceSize.width,
            y: (point.y - frame.minY) / frame.height * model.sourceSize.height)
    }

    private func map(_ point: CGPoint, to frame: CGRect) -> CGPoint {
        CGPoint(
            x: frame.minX + point.x / model.sourceSize.width * frame.width,
            y: frame.minY + point.y / model.sourceSize.height * frame.height)
    }

    private func map(_ rect: CGRect, to frame: CGRect) -> CGRect {
        let origin = map(rect.origin, to: frame)
        return CGRect(
            x: origin.x, y: origin.y,
            width: rect.width / model.sourceSize.width * frame.width,
            height: rect.height / model.sourceSize.height * frame.height)
    }

    private func draw(
        _ annotation: CaptureAnnotation, in context: inout GraphicsContext, frame: CGRect
    ) {
        let points = annotation.points.map { map($0, to: frame) }
        guard let first = points.first else { return }
        let color = Color(hex: annotation.colorHex)
        let width = max(1, annotation.strokeWidth * frame.width / model.sourceSize.width)
        let rect = map(annotation.rect, to: frame)
        switch annotation.tool {
        case .crop:
            context.stroke(
                Path(rect), with: .color(.white),
                style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
        case .pen:
            var path = Path()
            path.move(to: first)
            points.dropFirst().forEach { path.addLine(to: $0) }
            context.stroke(
                path, with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        case .arrow:
            guard let end = points.last else { return }
            var path = Path()
            path.move(to: first)
            path.addLine(to: end)
            let angle = atan2(end.y - first.y, end.x - first.x)
            let head = max(10, width * 4)
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - head * cos(angle - .pi / 6),
                y: end.y - head * sin(angle - .pi / 6)))
            path.move(to: end)
            path.addLine(to: CGPoint(
                x: end.x - head * cos(angle + .pi / 6),
                y: end.y - head * sin(angle + .pi / 6)))
            context.stroke(
                path, with: .color(color),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
        case .rectangle:
            context.stroke(
                Path(roundedRect: rect, cornerRadius: 5), with: .color(color),
                lineWidth: width)
        case .ellipse:
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: width)
        case .text:
            context.draw(
                Text(annotation.text).font(.system(size: max(12, width * 5), weight: .semibold)).foregroundStyle(color),
                at: first, anchor: .topLeading)
        case .redact:
            context.fill(Path(rect), with: .color(.black))
        }
    }
}

private extension Color {
    init(hex value: String) {
        let hex = value.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        let number = UInt64(hex, radix: 16) ?? 0xFF453A
        self.init(
            red: Double((number >> 16) & 0xff) / 255,
            green: Double((number >> 8) & 0xff) / 255,
            blue: Double(number & 0xff) / 255)
    }
}
