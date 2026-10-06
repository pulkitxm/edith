import AppKit
import EdithKit
import SwiftUI

struct VirtualCameraMeetingControls: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var choosingScreen = false
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(12)) {
                sourceMenu
                Spacer(minLength: UIScale.pt(8))
                if model.state.media.kind != .camera {
                    Toggle("Source audio", isOn: model.stateBinding(\.media.audioEnabled))
                        .toggleStyle(.button)
                        .help("Send this video's or window's audio to your meeting microphone")
                }
                Menu {
                    Toggle("Mirror preview", isOn: model.stateBinding(\.mirrorPreview))
                    Toggle("Thirds grid", isOn: $model.showsGrid)
                    if model.state.media.kind == .video {
                        Toggle("Loop video", isOn: model.stateBinding(\.media.loop))
                    }
                    Divider()
                    Button("Freeze frame") { model.pause(.freeze) }
                    Button("Away screen") { model.pause(.card) }
                    Button("Blank screen") { model.pause(.blank) }
                    Divider()
                    Button("Stop capture") { model.pause(.stopped) }
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: UIScale.pt(24), height: UIScale.pt(24))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Preview, playback and pause options")
                .accessibilityLabel("Meeting options")
            }
            HStack(spacing: UIScale.pt(12)) {
                Button {
                    model.toggleMeetingPlayback()
                } label: {
                    Label(
                        model.meetingPlaying ? "Pause" : "Play",
                        systemImage: model.meetingPlaying ? "pause.fill" : "play.fill"
                    )
                    .frame(minWidth: UIScale.pt(88), minHeight: UIScale.pt(28))
                }
                .buttonStyle(.edith(.primary))
                .help(
                    model.meetingPlaying ? "Pause your meeting video" : "Resume your meeting video")
                Button {
                    if !model.state.audio.enabled {
                        model.performAudio(.enable(true))
                    } else {
                        model.performAudio(.mute(!model.state.audio.muted))
                    }
                } label: {
                    Label(
                        !model.state.audio.enabled
                            ? "Enable audio"
                            : model.state.audio.muted ? "Unmute mic" : "Mute mic",
                        systemImage: model.state.audio.muted || !model.state.audio.enabled
                            ? "mic.slash.fill" : "mic.fill"
                    )
                    .frame(minHeight: UIScale.pt(28))
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.audioPending)
                Spacer(minLength: UIScale.pt(4))
                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.snapshot?.recordingPath == nil ? "Record" : "Stop recording",
                        systemImage: model.snapshot?.recordingPath == nil
                            ? "record.circle" : "stop.circle.fill"
                    )
                    .frame(minHeight: UIScale.pt(28))
                }
                .buttonStyle(.edith(.secondary))
                .disabled(model.state.privacy == .stopped && model.snapshot?.recordingPath == nil)
            }
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(12))
        .edithSurface(cornerRadius: 12)
        .edithSheet(isPresented: $choosingScreen, dismissible: false) {
            VirtualCameraScreenPicker(model: model, compact: compact)
        }
    }

    private var sourceMenu: some View {
        Menu {
            Section("Cameras") {
                ForEach(model.sources) { source in
                    Button(source.name) { model.selectSource(source) }
                }
            }
            Button("Choose video…") { model.chooseVideo() }
            Button("Screen or window…") { choosingScreen = true }
            Divider()
            Button("Refresh cameras") { model.refreshSources() }
        } label: {
            Label(sourceTitle, systemImage: sourceSymbol)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: UIScale.pt(28))
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .help("Choose your video source")
        .accessibilityLabel("Video source: \(sourceTitle)")
    }

    private var sourceTitle: String {
        switch model.state.media.kind {
        case .camera: model.selectedSource?.name ?? "Choose camera"
        case .video:
            model.state.media.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Video"
        case .screen: "Screen or window"
        }
    }

    private var sourceSymbol: String {
        switch model.state.media.kind {
        case .camera: "video"
        case .video: "film"
        case .screen: "display"
        }
    }
}

struct VirtualCameraScreenPicker: View {
    @ObservedObject var model: VirtualCameraPageModel
    var compact = false
    @State private var sources = ScreenCaptureSourceCatalog()

    var body: some View {
        ScreenCaptureSourcePicker(
            sources: sources, compact: compact, selection: model.screenSelection,
            maximumCount: 1, title: "Choose what to share",
            detail: "Select a window or display to use as your meeting video.",
            onSelection: { model.selectScreen($0) })
    }
}

extension VirtualCameraPageModel {
    var meetingPlaying: Bool {
        state.privacy == .live && (state.media.kind != .video || state.media.playback == .playing)
    }

    func toggleMeetingPlayback() {
        if meetingPlaying {
            if state.media.kind == .video {
                update { $0.media.playback = .paused }
            } else {
                pause(.freeze)
            }
        } else {
            update {
                $0.media.playback = .playing
                $0.privacy = .live
            }
        }
        flushSave()
    }

    var screenSelection: TimeLapseSourceSelection {
        let parts = (state.media.screenID ?? "").split(separator: ":")
        let window = parts.first == "window"
        let id = parts.count == 2 ? UInt32(parts[1]) : nil
        return TimeLapseSourceSelection(
            mode: window ? "windows" : "displays",
            displays: !window ? Set(id.map { [$0] } ?? []) : [],
            windows: window ? Set(id.map { [$0] } ?? []) : [],
            systemAudio: state.media.audioEnabled)
    }

    func selectScreen(_ selection: TimeLapseSourceSelection) {
        guard selection.selected.count == 1, let id = selection.selected.first else { return }
        update {
            $0.media = VirtualCameraMedia(
                kind: .screen,
                screenID: "\(selection.mode == "windows" ? "window" : "display"):\(id)",
                audioEnabled: selection.systemAudio)
            $0.privacy = .live
            $0.composition.framing = VirtualCameraFraming()
            $0.mirrorPreview = false
        }
        flushSave()
    }

    func toggleRecording() {
        let request: VirtualCameraRequest
        if snapshot?.recordingPath != nil {
            request = .recordStop
        } else {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.mpeg4Movie]
            panel.nameFieldStringValue = "Meeting recording.mp4"
            guard panel.runModal() == .OK, let url = panel.url else { return }
            request = .recordStart(url.path)
        }
        flushSave()
        Task { @MainActor in
            do {
                let snapshot = try await VirtualCameraOperationExecution.request(
                    request, timeout: .seconds(15))
                receive(snapshot)
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func chooseVideo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        update {
            $0.media = VirtualCameraMedia(kind: .video, path: url.path)
            $0.privacy = .live
            $0.composition.framing = VirtualCameraFraming()
            $0.mirrorPreview = false
        }
    }
}
