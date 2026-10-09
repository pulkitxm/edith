import AppKit
import EdithExtensionUI
import EdithExtensionSupport
import SwiftUI

struct VirtualCameraMeetingControls: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var choosingScreen = false
    @State private var audioDevices: [MeetingAudioDevice] = []
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(spacing: UIScale.pt(10)) {
            HStack(spacing: UIScale.pt(12)) {
                sourceMenu.frame(maxWidth: UIScale.pt(280), alignment: .leading)
                microphoneMenu.frame(maxWidth: UIScale.pt(280), alignment: .leading)
                Spacer(minLength: 0)
                Menu {
                    if model.state.media.kind != .camera {
                        Toggle("Source audio", isOn: model.stateBinding(\.media.audioEnabled))
                    }
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: UIScale.pt(12)) {
                    playbackButton.fixedSize()
                    microphoneButton.fixedSize()
                    Spacer(minLength: UIScale.pt(12))
                    zoomSlider.frame(width: UIScale.pt(220))
                    recordingButton.fixedSize()
                }
                VStack(spacing: UIScale.pt(10)) {
                    HStack(spacing: UIScale.pt(12)) {
                        playbackButton
                        microphoneButton
                        Spacer(minLength: UIScale.pt(4))
                        recordingButton
                    }
                    zoomSlider
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.edithText(.body))
        .padding(UIScale.pt(12))
        .edithSurface(cornerRadius: 12)
        .edithSheet(isPresented: $choosingScreen, dismissible: false) {
            VirtualCameraScreenPicker(model: model, compact: compact)
        }
        .pageTask {
            audioDevices = await Task.detached(priority: .utility) { MeetingAudioDevices.list() }
                .value
        }
    }

    private var playbackButton: some View {
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
    }

    private var microphoneButton: some View {
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
    }

    private var recordingButton: some View {
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

    private var zoomSlider: some View {
        HStack(spacing: UIScale.pt(8)) {
            Image(systemName: "magnifyingglass")
            Slider(
                value: Binding(get: { model.composition.framing.zoom }, set: { model.setZoom($0) }),
                in: VirtualCameraFraming.zoomRange
            )
            .accessibilityLabel("Video zoom")
            Text(String(format: "%.1fx", model.composition.framing.zoom))
                .font(.edithText(.caption)).monospacedDigit().frame(width: UIScale.pt(36))
        }
    }

    private var microphoneMenu: some View {
        Menu {
            Button("System microphone") { model.performAudio(.input("")) }
            ForEach(audioDevices.filter { $0.inputChannels > 0 && !$0.virtual }) { device in
                Button(device.name) { model.performAudio(.input(device.id)) }
            }
        } label: {
            Label(model.snapshot?.audioStatus?.inputName ?? "Microphone", systemImage: "mic")
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(28), alignment: .leading)
        }
        .menuStyle(.borderlessButton)
        .disabled(model.audioPending)
        .accessibilityLabel("Audio source")
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
