import AVKit
import AppKit
import Combine
import EdithKit
import SwiftUI

private struct EditorPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

struct VideoEditorPage: View {
    private enum EditorTool: String, CaseIterable {
        case zoom = "Zoom"
        case text = "Text"
        case transition = "Transition"
    }

    @State private var model = VideoEditorModel()
    @State private var editorTool: EditorTool = .zoom
    @State private var transitionDuration = 0.8
    @State private var editingTextID: String?
    @State private var trimIn = "0"
    @State private var trimOut = "0"
    @State private var titleDraft = ""
    @State private var timelineZoom = 80.0
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if model.project == nil {
                emptyState
            } else {
                HStack(spacing: 0) {
                    mediaRail
                    Divider()
                    VStack(spacing: 0) {
                        preview
                        transport
                        Divider()
                        toolStrip
                        Divider()
                        timeline
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(DashSkin.paper(scheme == .dark))
        .navigationTitle("Video editor")
        .onDisappear {
            model.player.pause()
            model.focusPlayer.pause()
        }
        .onChange(of: model.selectedClipID) { _, id in
            if let clip = model.project?.clips.first(where: { $0.id == id }) {
                trimIn = String(format: "%.2f", clip.start)
                trimOut = String(format: "%.2f", clip.end)
            }
        }
        .onChange(of: model.project?.title) { _, _ in
            titleDraft = model.project?.title ?? ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) {
            notification in
            guard model.loopPlayback,
                let item = notification.object as? AVPlayerItem,
                item === model.player.currentItem
            else { return }
            model.seek(to: 0)
            model.player.play()
        }
        .alert(
            "Video editor",
            isPresented: Binding(
                get: { model.errorMessage != nil },
                set: { if !$0 { model.errorMessage = nil } }
            )
        ) {
            Button("OK") {
                model.errorMessage = nil
                model.permissionSettingsURL = nil
            }
            if let url = model.permissionSettingsURL {
                Button("Open System Settings") {
                    NSWorkspace.shared.open(url)
                    model.permissionSettingsURL = nil
                    model.errorMessage = nil
                }
            }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var toolbar: some View {
        HStack(spacing: UIScale.pt(10)) {
            Image(systemName: "film.stack")
                .foregroundStyle(.tint)
            TextField("Video editor", text: $titleDraft)
                .font(.system(size: UIScale.pt(15), weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: UIScale.pt(260))
                .disabled(model.project == nil)
                .onSubmit { model.renameProject(titleDraft) }
                .help("Rename project")
            Spacer()
            Menu {
                Button("New project", action: model.newProject)
                Button("Open project…", action: model.openProject)
                Button("Save project", action: model.save)
                    .disabled(model.project == nil)
                    .keyboardShortcut("s", modifiers: .command)
            } label: {
                Label("Projects", systemImage: "folder")
            }
            Button(
                model.project?.clips.isEmpty == false ? "Add clips" : "Import video",
                systemImage: "square.and.arrow.down", action: model.importMedia
            )
            .buttonStyle(.borderedProminent)
            .help("Add video, audio, or images")
            Menu {
                Button("MP4 video", action: { model.export(gif: false) })
                Button("Animated GIF", action: { model.export(gif: true) })
            } label: {
                Label(
                    model.isRendering ? "Exporting…" : "Export", systemImage: "square.and.arrow.up")
            }
            .disabled(model.pipeline == nil || model.isRendering)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, UIScale.pt(18))
        .frame(height: UIScale.pt(52))
    }

    private var emptyState: some View {
        VStack(spacing: UIScale.pt(16)) {
            Image(systemName: "film")
                .font(.system(size: UIScale.pt(52), weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Make a video your own")
                .font(.title2.weight(.semibold))
            Text("Import a video, highlight moments with zoom, add text, and export.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Import video", action: model.importMedia)
                    .buttonStyle(.borderedProminent)
                Button("Open project", action: model.openProject)
                    .buttonStyle(.bordered)
            }
            if !model.recentProjects.isEmpty {
                Text("PROJECTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, UIScale.pt(22))
                ForEach(Array(model.recentProjects.prefix(6))) { item in
                    Button {
                        model.openProject(at: item.url)
                    } label: {
                        HStack {
                            Image(systemName: "film.stack")
                            Text(item.title).lineLimit(1)
                            if item.isOpenScreenLibrary {
                                Text("OpenScreen")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: UIScale.pt(360), alignment: .leading)
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UIScale.pt(30))
    }

    private var preview: some View {
        GeometryReader { geometry in
            let display = videoRect(in: geometry.size)
            let source = zoomSourceRect(in: display)
            ZStack {
                Color.black
                if model.pipeline != nil {
                    let placing =
                        editorTool == .zoom && model.editingZoomID != nil
                        && model.player.rate == 0
                    if placing && !model.focusPreviewReady {
                        ProgressView("Preparing zoom frame")
                            .foregroundStyle(.white)
                    } else {
                        EditorPlayerView(player: placing ? model.focusPlayer : model.player)
                        if placing {
                            ZoomFocusRegion(
                                display: source,
                                magnification: ZoomFocusGeometry.magnification(
                                    for: model.zoomDepth),
                                focus: CGPoint(x: model.focusX, y: model.focusY)
                            ) { focus in
                                model.setZoomFocus(x: focus.x, y: focus.y)
                            }
                        }
                    }
                } else {
                    Text("Import a video to begin")
                        .foregroundStyle(.secondary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(10)))
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(UIScale.pt(22))
    }

    private func videoRect(in viewport: CGSize) -> CGRect {
        guard let canvas = model.pipeline?.canvas,
            canvas.width > 0, canvas.height > 0
        else { return CGRect(origin: .zero, size: viewport) }
        let scale = min(viewport.width / canvas.width, viewport.height / canvas.height)
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        return CGRect(
            x: (viewport.width - size.width) / 2,
            y: (viewport.height - size.height) / 2,
            width: size.width, height: size.height)
    }

    private func zoomSourceRect(in display: CGRect) -> CGRect {
        guard let project = model.project, let zoomID = model.editingZoomID,
            let zoom = project.zooms.first(where: { $0.id == zoomID }),
            let clipID = zoom.raw["clipId"] as? String
                ?? project.clips.first(where: {
                    zoom.startMs >= $0.timelineStart * 1000
                        && zoom.startMs < ($0.timelineStart + $0.duration) * 1000
                })?.id,
            let clip = project.clips.first(where: { $0.id == clipID }),
            let asset = project.assets.first(where: { $0.id == clip.assetID }),
            let video = asset.raw["video"] as? [String: Any],
            let width = (video["width"] as? NSNumber)?.doubleValue,
            let height = (video["height"] as? NSNumber)?.doubleValue
        else { return display }
        return ZoomFocusGeometry.sourceFrame(
            in: display,
            sourceSize: CGSize(
                width: width * (clip.crop?["width"] ?? 1),
                height: height * (clip.crop?["height"] ?? 1)),
            padding: project.padding)
    }

    private var transport: some View {
        HStack(spacing: UIScale.pt(14)) {
            Button {
                model.seek(to: model.playhead - 1.0 / 30)
            } label: {
                Image(systemName: "backward.frame")
            }
            Button(action: model.togglePlayback) {
                Image(systemName: model.player.rate == 0 ? "play.fill" : "pause.fill")
                    .frame(width: UIScale.pt(30))
            }
            .keyboardShortcut(.space, modifiers: [])
            Button {
                model.seek(to: model.playhead + 1.0 / 30)
            } label: {
                Image(systemName: "forward.frame")
            }
            Button {
                model.loopPlayback.toggle()
            } label: {
                Image(systemName: model.loopPlayback ? "repeat.circle.fill" : "repeat")
            }
            .disabled(model.pipeline == nil)
            .help("Loop playback")
            Text(timestamp(model.playhead))
                .font(.system(.caption, design: .monospaced))
                .frame(width: UIScale.pt(65), alignment: .trailing)
            Slider(
                value: Binding(
                    get: { min(model.playhead, model.duration) },
                    set: { model.seek(to: $0) }
                ), in: 0...max(0.001, model.duration)
            )
            .disabled(model.duration <= 0)
            Text(timestamp(model.duration))
                .font(.system(.caption, design: .monospaced))
                .frame(width: UIScale.pt(65), alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, UIScale.pt(22))
        .frame(height: UIScale.pt(42))
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack {
                Text("Timeline")
                    .font(.subheadline.weight(.semibold))
                Text("Drag a zoom to move it; drag an edge to change its length")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: UIScale.pt(10))
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $timelineZoom, in: 40...180)
                    .frame(width: UIScale.pt(110))
                    .help("Timeline zoom")
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                let scale = UIScale.pt(timelineZoom)
                let width = max(scale, ceil(model.duration) * scale)
                ZStack(alignment: .topLeading) {
                    VStack(alignment: .leading, spacing: UIScale.pt(8)) {
                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(0..<max(1, Int(ceil(model.duration))), id: \.self) {
                                    second in
                                    Text(timestamp(Double(second)))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: scale, alignment: .leading)
                                }
                            }
                            Color.clear.contentShape(Rectangle())
                                .onTapGesture { location in
                                    model.seek(to: Double(location.x) / scale)
                                }
                        }
                        .frame(width: width, height: UIScale.pt(18))
                        ZStack(alignment: .topLeading) {
                            HStack(spacing: 0) {
                                ForEach(
                                    Array((model.project?.clips ?? []).enumerated()),
                                    id: \.element.id
                                ) {
                                    index, clip in
                                    let clipWidth = max(1, scale * timelineDuration(for: clip))
                                    Button {
                                        model.selectedClipID = clip.id
                                        if let segment = model.pipeline?.segments.first(where: {
                                            $0.clip.id == clip.id
                                        }) {
                                            model.seek(to: segment.outputStart)
                                        }
                                    } label: {
                                        HStack {
                                            Image(systemName: "film")
                                            Text("Clip \(index + 1)").lineLimit(1)
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, UIScale.pt(10))
                                        .frame(
                                            width: clipWidth, height: UIScale.pt(52),
                                            alignment: .leading
                                        )
                                        .background(
                                            model.selectedClipID == clip.id
                                                ? Color.accentColor.opacity(0.34)
                                                : Color.accentColor.opacity(0.17),
                                            in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                            if let clips = model.project?.clips {
                                ForEach(clips.dropFirst()) { clip in
                                    if let start = model.pipeline?.segments.first(where: {
                                        $0.clip.id == clip.id
                                    })?.outputStart {
                                        Button {
                                            model.selectedClipID = clip.id
                                            editorTool = .transition
                                        } label: {
                                            Image(systemName: "square.on.square")
                                                .font(.system(size: UIScale.pt(11), weight: .bold))
                                                .frame(
                                                    width: UIScale.pt(28), height: UIScale.pt(28)
                                                )
                                                .background(.regularMaterial, in: Circle())
                                        }
                                        .help("Transition between clips")
                                        .offset(
                                            x: start * scale - UIScale.pt(14), y: UIScale.pt(12))
                                    }
                                }
                            }
                        }
                        .frame(width: width, height: UIScale.pt(52), alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.accentColor.opacity(0.08))
                                .frame(width: width, height: UIScale.pt(38))
                            Text("ZOOM")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, UIScale.pt(8))
                            ForEach(model.project?.zooms ?? []) { zoom in
                                let start = model.outputTime(forRulerTime: zoom.startMs / 1000)
                                let end = model.outputTime(forRulerTime: zoom.endMs / 1000)
                                ZoomTimelineRegion(
                                    zoom: zoom,
                                    width: max(UIScale.pt(25), (end - start) * scale),
                                    selected: model.editingZoomID == zoom.id,
                                    select: {
                                        editorTool = .zoom
                                        model.selectZoom(zoom)
                                    },
                                    adjust: { seconds, edge in
                                        model.adjustZoom(zoom.id, by: seconds, edge: edge)
                                    },
                                    secondsPerPoint: 1 / scale
                                )
                                .offset(x: start * scale)
                            }
                        }
                        .frame(width: width, height: UIScale.pt(38), alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 7)
                                .fill(Color.orange.opacity(0.08))
                                .frame(width: width, height: UIScale.pt(28))
                            Text("TEXT")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.secondary)
                                .padding(.leading, UIScale.pt(8))
                            ForEach(
                                (model.project?.annotations ?? []).filter {
                                    $0.type == "text"
                                }
                            ) { annotation in
                                let start = model.outputTime(
                                    forRulerTime: annotation.startMs / 1000)
                                let end = model.outputTime(forRulerTime: annotation.endMs / 1000)
                                Button {
                                    model.seek(to: start)
                                    editorTool = .text
                                    editingTextID = annotation.id
                                } label: {
                                    Text(annotation.text)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .padding(.horizontal, UIScale.pt(6))
                                        .frame(
                                            width: max(UIScale.pt(30), (end - start) * scale),
                                            height: UIScale.pt(24), alignment: .leading
                                        )
                                        .background(Color.orange.opacity(0.35), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                                .offset(x: start * scale)
                                .popover(
                                    isPresented: Binding(
                                        get: { editingTextID == annotation.id },
                                        set: { if !$0 { editingTextID = nil } }
                                    )
                                ) {
                                    EditorAnnotationRow(annotation: annotation, model: model)
                                        .padding(UIScale.pt(16))
                                        .frame(width: UIScale.pt(280))
                                }
                            }
                        }
                        .frame(width: width, height: UIScale.pt(28), alignment: .leading)
                    }
                    Rectangle()
                        .fill(Color.accentColor)
                        .frame(width: UIScale.pt(2), height: UIScale.pt(168))
                        .offset(x: min(model.playhead, model.duration) * scale)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: UIScale.pt(168), alignment: .topLeading)
            }
            .frame(height: UIScale.pt(172))
        }
        .padding(UIScale.pt(18))
        .frame(height: UIScale.pt(230), alignment: .top)
    }

    private var mediaRail: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(14)) {
            Label("Media", systemImage: "film.stack")
                .font(.headline)
            Button("Add video or image", systemImage: "plus", action: model.importMedia)
                .buttonStyle(.borderedProminent)
            Text("CLIPS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, UIScale.pt(8))
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    if let clips = model.project?.clips {
                        ForEach(Array(clips.enumerated()), id: \.element.id) { index, clip in
                            Button {
                                model.selectedClipID = clip.id
                                if let segment = model.pipeline?.segments.first(where: {
                                    $0.clip.id == clip.id
                                }) {
                                    model.seek(to: segment.outputStart)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: "film")
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("Clip \(index + 1)")
                                            .font(.subheadline.weight(.medium))
                                        Text(timestamp(clip.duration))
                                            .font(.caption.monospacedDigit())
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(UIScale.pt(9))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    model.selectedClipID == clip.id
                                        ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.1),
                                    in: RoundedRectangle(cornerRadius: 9))
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .frame(width: UIScale.pt(180))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(UIScale.pt(14))
    }

    private var toolStrip: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(8)) {
                ForEach(EditorTool.allCases, id: \.self) { tool in
                    Button {
                        editorTool = tool
                    } label: {
                        Label(
                            tool.rawValue,
                            systemImage: tool == .zoom
                                ? "plus.magnifyingglass"
                                : tool == .text ? "textformat" : "square.on.square")
                    }
                    .buttonStyle(.bordered)
                    .tint(editorTool == tool ? .accentColor : .secondary)
                }
                Button("Split", systemImage: "scissors", action: model.splitAtPlayhead)
                    .buttonStyle(.bordered)
                    .disabled(model.pipeline == nil)
                Menu {
                    Button("Move earlier") { model.moveSelected(by: -1) }
                    Button("Move later") { model.moveSelected(by: 1) }
                    Button("Duplicate clip", action: model.duplicateSelected)
                    Button("Delete clip", role: .destructive, action: model.removeSelected)
                } label: {
                    Label("Clip", systemImage: "ellipsis.circle")
                }
                .disabled(model.selectedClipID == nil)
                Spacer(minLength: 0)
                Button("Undo", systemImage: "arrow.uturn.backward", action: model.undo)
                    .disabled(!model.canUndo)
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo", systemImage: "arrow.uturn.forward", action: model.redo)
                    .disabled(!model.canRedo)
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
            switch editorTool {
            case .zoom: zoomControls
            case .text: textControls
            case .transition: transitionControls
            }
        }
        .padding(.horizontal, UIScale.pt(18))
        .padding(.vertical, UIScale.pt(12))
    }

    private var zoomControls: some View {
        HStack(spacing: UIScale.pt(12)) {
            Text(
                model.editingZoomID == nil
                    ? "Add zoom at playhead"
                    : "Drag frame to focus"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: UIScale.pt(140), alignment: .leading)
            Picker(
                "Zoom",
                selection: Binding(
                    get: { model.zoomDepth },
                    set: { model.setZoomDepth($0) }
                )
            ) {
                Text("1.25×").tag(1)
                Text("1.5×").tag(2)
                Text("1.8×").tag(3)
                Text("2.2×").tag(4)
                Text("3.5×").tag(5)
                Text("5×").tag(6)
            }
            .frame(width: UIScale.pt(105))
            HStack(spacing: UIScale.pt(5)) {
                Text("Length")
                Slider(
                    value: Binding(
                        get: { model.zoomDuration },
                        set: { model.setZoomDuration($0) }
                    ), in: 0.5...6, step: 0.5
                )
                .frame(width: UIScale.pt(90))
                Text(String(format: "%.1fs", model.zoomDuration))
                    .monospacedDigit()
            }
            .font(.caption)
            Button(
                "Add zoom",
                systemImage: "plus.magnifyingglass", action: model.addZoom
            )
            .buttonStyle(.borderedProminent)
            .disabled(model.pipeline == nil)
            if let id = model.editingZoomID {
                Button {
                    model.removeZoom(id)
                } label: {
                    Image(systemName: "trash")
                }
                .accessibilityLabel("Remove zoom")
                .help("Remove selected zoom")
            }
        }
    }

    private var textControls: some View {
        HStack(spacing: UIScale.pt(12)) {
            TextField("Type a title or callout", text: $model.captionText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: UIScale.pt(320))
                .onSubmit(model.addCaption)
            HStack(spacing: UIScale.pt(5)) {
                Text("Show for")
                Slider(value: $model.captionDuration, in: 1...8, step: 0.5)
                    .frame(width: UIScale.pt(95))
                Text(String(format: "%.1fs", model.captionDuration))
                    .monospacedDigit()
            }
            .font(.caption)
            Button("Add text", systemImage: "plus", action: model.addCaption)
                .buttonStyle(.borderedProminent)
                .disabled(model.pipeline == nil || model.captionText.isEmpty)
        }
    }

    private var transitionControls: some View {
        HStack(spacing: UIScale.pt(12)) {
            if let clips = model.project?.clips, clips.count > 1 {
                let incomingID =
                    clips.dropFirst().contains(where: {
                        $0.id == model.selectedClipID
                    }) ? model.selectedClipID ?? clips[1].id : clips[1].id
                let current = model.project?.transitions.first(where: {
                    $0.clipID == incomingID
                })
                Text("Between clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker(
                    "Into",
                    selection: Binding(
                        get: { incomingID },
                        set: { model.selectedClipID = $0 }
                    )
                ) {
                    ForEach(Array(clips.dropFirst().enumerated()), id: \.element.id) {
                        index, clip in
                        Text("Clip \(index + 1) → \(index + 2)").tag(clip.id)
                    }
                }
                .frame(width: UIScale.pt(170))
                Picker(
                    "Effect",
                    selection: Binding(
                        get: { current?.kind ?? "cut" },
                        set: {
                            model.setTransition(
                                before: incomingID, kind: $0, duration: transitionDuration)
                        }
                    )
                ) {
                    Text("Cut").tag("cut")
                    Text("Fade").tag("fade")
                    Text("Flash").tag("flash")
                }
                .frame(width: UIScale.pt(125))
                if let current {
                    Slider(
                        value: Binding(
                            get: { current.duration },
                            set: {
                                transitionDuration = $0
                                model.setTransition(
                                    before: incomingID, kind: current.kind, duration: $0)
                            }
                        ), in: 0.2...2, step: 0.1
                    )
                    .frame(width: UIScale.pt(115))
                    Text(String(format: "%.1fs", current.duration))
                        .font(.caption.monospacedDigit())
                }
            } else {
                Text("Add a second clip to create a transition.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Add clip", action: model.importMedia)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func timestamp(_ seconds: Double) -> String {
        let value = max(0, seconds.isFinite ? seconds : 0)
        return String(format: "%02d:%02d", Int(value) / 60, Int(value) % 60)
    }

    private func timelineDuration(for clip: VideoProject.Clip) -> Double {
        model.pipeline?.segments.filter { $0.clip.id == clip.id }
            .reduce(0) { $0 + $1.outputDuration } ?? clip.duration / clip.rate
    }
}

private struct EditorAnnotationRow: View {
    let annotation: VideoProject.Annotation
    let model: VideoEditorModel
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(7)) {
            HStack {
                if annotation.type == "text" {
                    TextField("Caption", text: $draft)
                        .onSubmit { model.updateCaption(annotation.id, text: draft) }
                        .onAppear { draft = annotation.text }
                } else {
                    Text(annotation.type.capitalized).lineLimit(1)
                }
                Button(role: .destructive) {
                    model.removeCaption(annotation.id)
                } label: {
                    Image(systemName: "xmark")
                }
            }
            if annotation.type == "text" {
                let style = annotation.raw["style"] as? [String: Any] ?? [:]
                Picker(
                    "Color",
                    selection: Binding(
                        get: { style["color"] as? String ?? "#FFFFFF" },
                        set: { model.setAnnotationStyle(annotation.id, key: "color", value: $0) }
                    )
                ) {
                    Text("White").tag("#FFFFFF")
                    Text("Yellow").tag("#FFD54F")
                    Text("Green").tag("#34B27B")
                    Text("Black").tag("#000000")
                }
                Picker(
                    "Plate",
                    selection: Binding(
                        get: { style["backgroundColor"] as? String ?? "transparent" },
                        set: {
                            model.setAnnotationStyle(
                                annotation.id, key: "backgroundColor", value: $0)
                        }
                    )
                ) {
                    Text("None").tag("transparent")
                    Text("Black").tag("#000000")
                    Text("White").tag("#FFFFFF")
                }
                HStack {
                    Text("Size")
                    Slider(
                        value: Binding(
                            get: { (style["fontSize"] as? NSNumber)?.doubleValue ?? 32 },
                            set: {
                                model.setAnnotationStyle(annotation.id, key: "fontSize", value: $0)
                            }
                        ), in: 16...96, step: 4)
                }
                let position = annotation.raw["position"] as? [String: Double] ?? [:]
                ForEach([("x", "Horizontal"), ("y", "Vertical")], id: \.0) { axis, title in
                    HStack {
                        Text(title)
                        Slider(
                            value: Binding(
                                get: { position[axis] ?? (axis == "x" ? 50 : 80) },
                                set: {
                                    model.setAnnotationPosition(
                                        annotation.id, axis: axis, value: $0)
                                }
                            ), in: 0...100, step: 5)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
    }
}

private struct ZoomTimelineRegion: View {
    let zoom: VideoProject.Zoom
    let width: CGFloat
    let selected: Bool
    let select: () -> Void
    let adjust: (Double, String) -> Void
    let secondsPerPoint: Double
    @State private var dragOffset: CGFloat = 0
    @State private var draggingEdge: String?

    var body: some View {
        HStack(spacing: 0) {
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(width: UIScale.pt(7), height: UIScale.pt(22))
                .padding(.leading, UIScale.pt(3))
                .gesture(drag("start"))
                .accessibilityLabel("Drag zoom start")
            Button(action: select) {
                Text(String(format: "%.1f×", magnification))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .simultaneousGesture(drag("move"))
            Capsule()
                .fill(.white.opacity(0.8))
                .frame(width: UIScale.pt(7), height: UIScale.pt(22))
                .padding(.trailing, UIScale.pt(3))
                .gesture(drag("end"))
                .accessibilityLabel("Drag zoom end")
        }
        .frame(width: width, height: UIScale.pt(32))
        .background(
            selected ? Color.accentColor : Color.blue.opacity(0.75),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(.white.opacity(selected ? 0.8 : 0), lineWidth: 1)
        }
        .offset(x: draggingEdge == "move" ? dragOffset : 0)
        .accessibilityLabel("Zoom at \(String(format: "%.1f", zoom.startMs / 1000)) seconds")
    }

    private var magnification: Double {
        [1.25, 1.5, 1.8, 2.2, 3.5, 5.0][max(0, min(5, zoom.depth - 1))]
    }

    private func drag(_ edge: String) -> some Gesture {
        DragGesture(minimumDistance: UIScale.pt(3))
            .onChanged { value in
                draggingEdge = edge
                dragOffset = value.translation.width
            }
            .onEnded { value in
                draggingEdge = nil
                dragOffset = 0
                adjust(Double(value.translation.width) * secondsPerPoint, edge)
            }
    }
}

enum ZoomFocusGeometry {
    static func sourceFrame(in display: CGRect, sourceSize: CGSize, padding: Double) -> CGRect {
        guard sourceSize.width > 0, sourceSize.height > 0,
            display.width > 0, display.height > 0
        else { return display }
        let scale =
            min(
                display.width / sourceSize.width,
                display.height / sourceSize.height) * (1 - 2 * min(0.25, max(0, padding / 100)))
        let size = CGSize(width: sourceSize.width * scale, height: sourceSize.height * scale)
        return CGRect(
            x: display.midX - size.width / 2, y: display.midY - size.height / 2,
            width: size.width, height: size.height)
    }

    static func magnification(for depth: Int) -> Double {
        [1.25, 1.5, 1.8, 2.2, 3.5, 5.0][max(0, min(5, depth - 1))]
    }

    static func frame(in display: CGRect, magnification: Double, focus: CGPoint) -> CGRect {
        let scale = magnification.isFinite ? max(1, magnification) : 1
        let width = display.width / scale
        let height = display.height / scale
        let center = CGPoint(
            x: min(
                display.maxX - width / 2,
                max(
                    display.minX + width / 2,
                    display.minX + focus.x * display.width)),
            y: min(
                display.maxY - height / 2,
                max(
                    display.minY + height / 2,
                    display.minY + focus.y * display.height)))
        return CGRect(
            x: center.x - width / 2, y: center.y - height / 2,
            width: width, height: height)
    }

    static func focus(at point: CGPoint, in display: CGRect, magnification: Double) -> CGPoint {
        guard display.width > 0, display.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        let frame = frame(
            in: display, magnification: magnification,
            focus: CGPoint(
                x: (point.x - display.minX) / display.width,
                y: (point.y - display.minY) / display.height))
        return CGPoint(
            x: (frame.midX - display.minX) / display.width,
            y: (frame.midY - display.minY) / display.height)
    }
}

private struct ZoomFocusRegion: View {
    let display: CGRect
    let magnification: Double
    let focus: CGPoint
    let commit: (CGPoint) -> Void
    @State private var translation = CGSize.zero

    private var frame: CGRect {
        ZoomFocusGeometry.frame(
            in: display, magnification: magnification,
            focus: CGPoint(
                x: focus.x + translation.width / max(1, display.width),
                y: focus.y + translation.height / max(1, display.height)))
    }

    var body: some View {
        let frame = frame
        RoundedRectangle(cornerRadius: UIScale.pt(6))
            .fill(Color.green.opacity(0.2))
            .overlay {
                RoundedRectangle(cornerRadius: UIScale.pt(6))
                    .strokeBorder(Color.green, lineWidth: UIScale.pt(2))
            }
            .frame(width: frame.width, height: frame.height)
            .position(x: frame.midX, y: frame.midY)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: UIScale.pt(2))
                    .onChanged { translation = $0.translation }
                    .onEnded { value in
                        let center = CGPoint(
                            x: display.minX + focus.x * display.width + value.translation.width,
                            y: display.minY + focus.y * display.height + value.translation.height)
                        commit(
                            ZoomFocusGeometry.focus(
                                at: center, in: display, magnification: magnification))
                        translation = .zero
                    }
            )
            .accessibilityLabel("Drag zoom frame")
            .help("Drag to frame the part of the video that will fill the screen")
    }
}
