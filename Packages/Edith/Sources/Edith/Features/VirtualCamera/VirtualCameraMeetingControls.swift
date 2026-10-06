import AppKit
import EdithKit
import SwiftUI

struct VirtualCameraMeetingControls: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var choosingScreen = false
    @Environment(\.compactLayout) private var compact

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(8)) {
                Button {
                    model.resume()
                } label: {
                    Label("Live", systemImage: "video.fill")
                }
                .buttonStyle(.edith(model.state.privacy == .live ? .primary : .secondary))
                Button {
                    model.pause(.card)
                } label: {
                    Label("Away", systemImage: "pause.fill")
                }
                .buttonStyle(.edith(.secondary))
                Button {
                    model.pause(.freeze)
                } label: {
                    Label("Freeze", systemImage: "snowflake")
                }
                .buttonStyle(.edith(.secondary))
                Button {
                    model.pause(.stopped)
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.edith(.secondary))
                Spacer()
                Button {
                    model.toggleRecording()
                } label: {
                    Label(
                        model.snapshot?.recordingPath == nil ? "Record" : "Stop recording",
                        systemImage: "record.circle")
                }
                .buttonStyle(.edith(.secondary))
            }
            HStack(spacing: UIScale.pt(8)) {
                Menu {
                    ForEach(model.sources) { source in
                        Button(source.name) { model.selectSource(source) }
                    }
                } label: {
                    Label("Camera", systemImage: "camera")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Button("Choose video…") { model.chooseVideo() }
                    .buttonStyle(.edith(.secondary))
                Button("Screen or window…") { choosingScreen = true }
                    .buttonStyle(.edith(.secondary))
                if model.state.media.kind == .video {
                    Button {
                        model.update {
                            $0.media.playback = $0.media.playback == .playing ? .paused : .playing
                            $0.privacy = .live
                        }
                    } label: {
                        Label(
                            model.state.media.playback == .playing ? "Pause video" : "Play video",
                            systemImage: model.state.media.playback == .playing
                                ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.edith(.secondary))
                    Toggle(
                        "Loop",
                        isOn: Binding(
                            get: { model.state.media.loop },
                            set: { value in model.update { $0.media.loop = value } })
                    )
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                Spacer()
            }
            if let path = model.state.media.path, model.state.media.kind == .video {
                Text(URL(fileURLWithPath: path).lastPathComponent)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                    .lineLimit(1)
            }
            if model.state.media.kind != .camera {
                Toggle(
                    "Include source audio",
                    isOn: Binding(
                        get: { model.state.media.audioEnabled },
                        set: { value in model.update { $0.media.audioEnabled = value } })
                )
                .font(.edithText(.caption))
                Text(
                    "Enable meeting audio and choose its virtual microphone in your meeting to hear this source."
                )
                .font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
            }
            EdithSegmentedPicker(
                "Preview", selection: model.stateBinding(\.mirrorPreview),
                options: [false, true], label: { $0 ? "Mirrored self view" : "Audience view" })
            Text("Audience view shows the output orientation. Meet mirrors its local self view.")
                .font(.edithText(.caption)).foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(UIScale.pt(12))
        .background(RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(DashSkin.paper2(dark)))
        .edithSheet(isPresented: $choosingScreen, dismissible: false) {
            VirtualCameraScreenPicker(model: model, compact: compact)
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
