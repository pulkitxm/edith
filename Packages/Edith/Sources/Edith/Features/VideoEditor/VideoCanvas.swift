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
                        display: display, title: "Webcam", selected: model.selection == .webcam,
                        select: { model.selection = .webcam }, commit: model.placeCamera)
                }
            }
        }
        .task(id: cameraPath) {
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

private struct VideoCanvasHandle: View {
    let rect: CGRect
    let display: CGRect
    let title: String
    let selected: Bool
    let select: () -> Void
    let commit: (CGRect) -> Void
    @State private var draft: CGRect?

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
        .highPriorityGesture(drag("move"))
        .overlay(alignment: .bottomTrailing) {
            if selected {
                Rectangle().fill(.white).frame(width: UIScale.pt(12), height: UIScale.pt(12))
                    .overlay { Rectangle().stroke(.cyan) }
                    .gesture(drag("resize"))
                    .accessibilityLabel("Resize \(title)")
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
        .position(
            x: display.minX + area.midX * display.width,
            y: display.minY + area.midY * display.height
        )
        .accessibilityLabel("Move \(title)")
    }

    private func drag(_ handle: String) -> some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named("videoCanvas"))
            .onChanged { value in
                select()
                draft = adjusted(value.translation, handle: handle)
            }
            .onEnded { value in
                commit(adjusted(value.translation, handle: handle))
                draft = nil
            }
    }

    private func adjusted(_ translation: CGSize, handle: String) -> CGRect {
        VideoCanvasGeometry.adjust(
            rect,
            translation: CGSize(
                width: translation.width / max(1, display.width),
                height: translation.height / max(1, display.height)),
            handle: handle)
    }
}
