import AppKit
import EdithKit
import SwiftUI

struct VirtualCameraMeetingControls: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var choosingScreen = false

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
            Text(model.state.mirrorPreview ? "Mirrored self preview" : "Audience preview")
                .font(.system(size: UIScale.pt(11), weight: .medium))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
        .padding(UIScale.pt(12))
        .background(RoundedRectangle(cornerRadius: UIScale.pt(12)).fill(DashSkin.paper2(dark)))
        .sheet(isPresented: $choosingScreen) { VirtualCameraScreenPicker(model: model) }
    }
}

struct VirtualCameraScreenPicker: View {
    @ObservedObject var model: VirtualCameraPageModel
    @Environment(\.dismiss) private var dismiss
    @State private var sources: [VirtualCameraScreenSource] = []
    @State private var selection = ""
    @State private var failure: String?

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Text("Screen or window").font(.headline)
            if let failure { Text(failure).foregroundStyle(.red) }
            if sources.isEmpty && failure == nil { ProgressView("Finding sources…") }
            Picker("Source", selection: $selection) {
                ForEach(sources) { source in Text(source.name).tag(source.id) }
            }
            Text("The selected screen or window replaces your camera in the meeting.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Use source") {
                    model.update {
                        $0.media = VirtualCameraMedia(kind: .screen, screenID: selection)
                        $0.privacy = .live
                        $0.composition.framing = VirtualCameraFraming()
                    }
                    dismiss()
                }
                .disabled(selection.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.pt(24))
        .frame(width: UIScale.pt(480))
        .task {
            do {
                sources = try await VirtualCameraScreenCatalog.sources()
                selection = sources.first?.id ?? ""
            } catch { failure = error.localizedDescription }
        }
    }
}

extension VirtualCameraPageModel {
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
        }
    }
}
