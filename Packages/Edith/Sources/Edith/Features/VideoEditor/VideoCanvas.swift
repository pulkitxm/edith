import AVFoundation
import SwiftUI
import EdithKit

struct VideoCanvas: View {
    let model: VideoEditorModel
    let display: CGRect
    @State private var cameraAspect = 4.0 / 3

    private var cameraPath: String? {
        guard
            let segment = model.pipeline?.segments.first(where: { model.playhead < $0.outputEnd }),
            let track = model.project?.assets.first(where: { $0.id == segment.clip.assetID })?
                .cameraTrack,
            track["visible"] as? Bool != false
        else { return nil }
        return track["sourcePath"] as? String
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if model.safeAreas {
                Rectangle().strokeBorder(
                    .white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [5])
                )
                .frame(width: display.width * 0.8, height: display.height * 0.8)
                .position(x: display.midX, y: display.midY).allowsHitTesting(false)
            }
            if model.canvasEditing, model.player.rate == 0, model.editingZoomID == nil {
                ForEach(
                    model.project?.annotations.filter {
                        $0.visible(
                            at: model.player.currentTime(),
                            rulerMilliseconds: model.rulerPlayhead * 1000)
                    } ?? []
                ) { annotation in
                    VideoCanvasHandle(
                        rect: annotation.captionCanvasRect
                            ?? VideoCanvasGeometry.rect(
                                position: annotation.raw["position"] as? [String: Double] ?? [:],
                                size: annotation.raw["size"] as? [String: Double] ?? [:]),
                        display: display,
                        title: annotation.type == "text"
                            ? annotation.text : annotation.type.capitalized,
                        preserveAspect: annotation.type == "image",
                        selected: model.selection == .annotation(annotation.id),
                        select: { model.selection = .annotation(annotation.id) },
                        commit: { model.placeAnnotation(annotation.id, rect: $0) })
                }
                if cameraPath != nil, let project = model.project {
                    let width = project.webcamSize / 100
                    let height = width * display.width / max(1, display.height) / cameraAspect
                    VideoCanvasHandle(
                        rect: CGRect(
                            x: (project.webcamPosition["cx"] ?? 0.84) - width / 2,
                            y: (project.webcamPosition["cy"] ?? 0.8) - height / 2,
                            width: width, height: height),
                        display: display, title: "Webcam", preserveAspect: true,
                        selected: model.selection == .webcam,
                        select: { model.selection = .webcam }, commit: model.placeCamera)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if model.canvasEditing, model.player.rate == 0, model.editingZoomID == nil,
                case let .annotation(id) = model.selection,
                let annotation = model.project?.annotations.first(where: { $0.id == id })
            {
                VideoCanvasSelectionControls(annotation: annotation, model: model)
                    .id(id)
            }
        }
        .pageTask(id: cameraPath) {
            guard let cameraPath else { return }
            let asset = AVURLAsset(url: URL(fileURLWithPath: cameraPath))
            if let track = try? await asset.loadTracks(withMediaType: .video).first,
                let size = try? await track.load(.naturalSize),
                let transform = try? await track.load(.preferredTransform)
            {
                let displayed = size.applying(transform)
                guard !Task.isCancelled, displayed.height != 0 else { return }
                cameraAspect = abs(displayed.width / displayed.height)
            }
        }
    }
}

private struct VideoCanvasSelectionControls: View {
    let annotation: VideoProject.Annotation
    let model: VideoEditorModel
    @State private var text = ""

    var body: some View {
        HStack(spacing: UIScale.pt(8)) {
            if annotation.type == "text" {
                TextField("Selected text", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: UIScale.pt(300))
                    .onSubmit { apply() }
                    .onChange(of: annotation.text) { text = annotation.text }
                    .onAppear { text = annotation.text }
                    .onDisappear { apply() }
                Button("Apply", action: apply)
                    .disabled(text == annotation.text)
            } else {
                Text(annotation.type.capitalized).font(.edithText(.body))
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                model.removeCaption(annotation.id)
            }
            .labelStyle(.iconOnly)
            .help("Delete selected overlay")
        }
        .buttonStyle(.edith(.secondary))
        .padding(UIScale.pt(10))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .padding(UIScale.pt(12))
    }

    private func apply() {
        guard text != annotation.text,
            model.project?.annotations.contains(where: { $0.id == annotation.id }) == true
        else { return }
        model.updateCaption(annotation.id, text: text)
    }
}

struct VideoCanvasHandle: View {
    let rect: CGRect
    let display: CGRect
    let title: String
    var preserveAspect = false
    let selected: Bool
    let select: () -> Void
    let commit: (CGRect) -> Void
    @State private var draft: CGRect?
    @State private var activeCorner: Int?
    @State private var origin: CGRect?

    var body: some View {
        let area = draft ?? rect
        Button(action: select) {
            Rectangle().fill(.clear)
                .overlay {
                    Rectangle().strokeBorder(
                        selected ? .cyan : .white.opacity(0.25), lineWidth: selected ? 2 : 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.edith(.borderless))
        .overlay {
            if selected {
                GeometryReader { geometry in
                    ForEach(0..<4, id: \.self) { corner in
                        let anchor = CanvasSelectionGeometry.anchor(
                            corner,
                            in: CGRect(origin: .zero, size: geometry.size))
                        RoundedRectangle(cornerRadius: 2).fill(.white)
                            .frame(width: UIScale.pt(10), height: UIScale.pt(10))
                            .overlay { RoundedRectangle(cornerRadius: 2).stroke(.cyan) }
                            .position(anchor)
                    }
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topLeading) {
            if selected {
                Text(title).font(.edithText(.caption2)).lineLimit(1).padding(4)
                    .background(.black.opacity(0.7)).offset(y: -24).allowsHitTesting(false)
            }
        }
        .frame(
            width: max(12, area.width * display.width),
            height: max(12, area.height * display.height)
        )
        .padding(UIScale.pt(12))
        .contentShape(Rectangle())
        .overlay {
            CanvasPointerSurface(onChanged: dragChanged, onEnded: dragEnded)
        }
        .position(
            x: display.minX + area.midX * display.width,
            y: display.minY + area.midY * display.height
        )
        .accessibilityLabel("Move \(title)")
    }

    private func dragChanged(_ value: CanvasPointerDrag) {
        if origin == nil {
            origin = rect
            if selected {
                activeCorner = CanvasSelectionGeometry.corner(
                    at: value.startLocation,
                    frame: CGRect(
                        x: UIScale.pt(12), y: UIScale.pt(12),
                        width: rect.width * display.width, height: rect.height * display.height))
            }
            select()
        }
        draft = adjusted(value.translation)
    }

    private func dragEnded(_ value: CanvasPointerDrag) {
        let result = adjusted(value.translation)
        if result != rect { commit(result) }
        draft = nil
        origin = nil
        activeCorner = nil
    }

    private func adjusted(_ translation: CGSize) -> CGRect {
        let normalized = CGSize(
            width: translation.width / max(1, display.width),
            height: translation.height / max(1, display.height))
        if let activeCorner {
            return CanvasSelectionGeometry.resize(
                origin ?? rect, corner: activeCorner,
                delta: CGPoint(x: normalized.width, y: normalized.height), minimum: 0.03,
                preserveAspect: preserveAspect)
        }
        return VideoCanvasGeometry.adjust(origin ?? rect, translation: normalized, handle: "move")
    }
}
