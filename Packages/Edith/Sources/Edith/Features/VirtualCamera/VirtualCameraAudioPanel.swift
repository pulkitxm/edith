import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct VirtualCameraAudioPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var devices: [MeetingAudioDevice] = []
    @State private var snippetName = ""
    @State private var importSound = false
    @State private var editing: MeetingAudioClip?

    private var audio: MeetingAudioState { model.state.audio }
    private var status: MeetingAudioStatus? { model.snapshot?.audioStatus }

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            VirtualCameraPanelSection(
                title: "Meeting microphone",
                detail:
                    "Choose the same virtual microphone in Meet. Device selections stay saved when you switch sources.",
                dark: dark
            ) {
                HStack {
                    Button(status?.running == true ? "Disable audio" : "Enable audio") {
                        model.performAudio(.enable(status?.running != true))
                    }
                    .buttonStyle(.edith(.primary))
                    Button(audio.muted ? "Unmute mic" : "Mute mic") {
                        model.performAudio(.mute(!audio.muted))
                    }
                    .buttonStyle(.edith(.secondary))
                }
                .disabled(model.audioPending)
                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { audio.inputID ?? "" }, set: { model.performAudio(.input($0)) })
                ) {
                    Text("System microphone").tag("")
                    ForEach(devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag($0.id) }
                }
                Picker(
                    "Meeting output",
                    selection: Binding(
                        get: { audio.outputID ?? "" }, set: { model.performAudio(.output($0)) })
                ) {
                    Text("Select virtual device").tag("")
                    ForEach(devices.filter { $0.virtual && $0.outputChannels > 0 }) {
                        Text($0.name).tag($0.id)
                    }
                }
                Button("Refresh devices") { refreshDevices() }.buttonStyle(.edith(.toolbar))
                if !devices.contains(where: { $0.virtual && $0.outputChannels > 0 }) {
                    Link(
                        "Install BlackHole 2ch",
                        destination: URL(string: "https://existential.audio/blackhole/")!)
                }
                Text(
                    status?.running == true
                        ? "Sending to \(status?.outputName ?? "virtual microphone")"
                        : "Audio is off"
                )
                .font(.edithText(.caption))
                .foregroundStyle(status?.running == true ? Color.green : DashSkin.inkFaint(dark))
                if let failure = status?.failure {
                    Text(failure).font(.edithText(.caption)).foregroundStyle(.red)
                }
                if let failure = status?.sourceFailure {
                    Text(failure).font(.edithText(.caption)).foregroundStyle(.red)
                }
                level("Mic", value: audio.micGain) { value in
                    model.update { $0.audio.micGain = value }
                }
                level("Clips", value: audio.clipsGain) { value in
                    model.update { $0.audio.clipsGain = value }
                }
                level("Source", value: audio.sourceGain) { value in
                    model.update { $0.audio.sourceGain = value }
                }
            }
            VirtualCameraPanelSection(
                title: "Voice",
                detail: "Live speech and saved speech snippets use the same effects.", dark: dark
            ) {
                Picker(
                    "Preset",
                    selection: Binding(
                        get: { audio.preset },
                        set: { value in model.update { $0.audio.preset = value } })
                ) {
                    ForEach(MeetingVoicePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                adjustment("Pitch", value: Double(audio.pitch), range: -1200...1200) { value in
                    model.update { $0.audio.pitch = Float(value) }
                }
                adjustment("Reverb", value: Double(audio.reverb), range: 0...100) { value in
                    model.update { $0.audio.reverb = Float(value) }
                }
                adjustment("Echo", value: Double(audio.delay), range: 0...100) { value in
                    model.update { $0.audio.delay = Float(value) }
                }
            }
            VirtualCameraPanelSection(title: "Snippets and sounds", dark: dark) {
                TextField("Snippet name", text: $snippetName)
                HStack {
                    Button(status?.recordingName == nil ? "Record mic" : "Save snippet") {
                        model.performAudio(
                            status?.recordingName == nil ? .recordClip(snippetName) : .finishClip)
                    }
                    .disabled(
                        model.audioPending || (status?.recordingName == nil && snippetName.isEmpty))
                    Button("Import…") { importClip() }.disabled(
                        snippetName.isEmpty || model.audioPending)
                }
                Toggle("Import as sound effect", isOn: $importSound)
                    .font(.edithText(.caption))
                if let name = status?.recordingName {
                    Text("Recording \(name)").foregroundStyle(.red)
                }
                ForEach(audio.clips) { clip in
                    HStack {
                        Button {
                            model.performAudio(.playClip(clip.id.uuidString))
                        } label: {
                            Image(systemName: "play.fill")
                        }
                        .disabled(status?.running != true || model.audioPending)
                        VStack(alignment: .leading) {
                            Text(clip.name).lineLimit(1)
                            Text(clip.speech ? "Speech" : "Sound effect").font(.edithText(.caption))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            editing = clip
                        } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                        Button {
                            model.performAudio(.removeClip(clip.id.uuidString))
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(.edith(.toolbar))
                }
                Button("Stop all clips") { model.performAudio(.stopClips) }.disabled(
                    model.audioPending)
            }
        }
        .task { refreshDevices() }
        .sheet(item: $editing) { clip in VirtualCameraClipEditor(model: model, clip: clip) }
    }

    private func level(_ name: String, value: Float, change: @escaping (Float) -> Void) -> some View
    {
        adjustment(name, value: Double(value), range: 0...2) { change(Float($0)) }
    }

    private func adjustment(
        _ name: String, value: Double, range: ClosedRange<Double>,
        change: @escaping (Double) -> Void
    ) -> some View {
        HStack {
            Text(name).font(.edithText(.caption)).frame(width: UIScale.pt(48), alignment: .leading)
            Slider(value: Binding(get: { value }, set: change), in: range)
            Text(String(format: "%.0f", range.upperBound == 2 ? value * 100 : value))
                .font(.edithText(.caption)).monospacedDigit().frame(width: UIScale.pt(38))
        }
    }

    private func refreshDevices() {
        Task {
            devices = await Task.detached(priority: .utility) { MeetingAudioDevices.list() }.value
        }
    }

    private func importClip() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.performAudio(.importClip(name: snippetName, path: url.path, speech: !importSound))
    }
}

struct VirtualCameraClipEditor: View {
    @ObservedObject var model: VirtualCameraPageModel
    let clip: MeetingAudioClip
    @Environment(\.dismiss) private var dismiss
    @State private var start = ""
    @State private var end = ""
    @State private var gain: Double = 1

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Text("Edit \(clip.name)").font(.edithText(.headline))
            TextField("Start in seconds", text: $start)
            TextField("End in seconds, blank for full length", text: $end)
            Slider(value: $gain, in: 0...2) { Text("Gain") }
            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Save") {
                    guard let startValue = Double(start), end.isEmpty || Double(end) != nil else {
                        return
                    }
                    model.performAudio(
                        .editClip(
                            name: clip.id.uuidString, start: startValue,
                            end: end.isEmpty ? nil : Double(end), gain: Float(gain))
                    ) { dismiss() }
                }
                .disabled(
                    model.audioPending || Double(start) == nil
                        || (!end.isEmpty && Double(end) == nil)
                )
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(UIScale.pt(24)).frame(width: UIScale.pt(420))
        .onAppear {
            start = String(clip.start)
            end = clip.end.map { String($0) } ?? ""
            gain = Double(clip.gain)
        }
    }
}

extension VirtualCameraPageModel {
    func performAudio(_ request: MeetingAudioRequest, completion: (() -> Void)? = nil) {
        guard !audioPending else { return }
        flushSave()
        audioPending = true
        Task { @MainActor in
            defer { audioPending = false }
            do {
                receive(
                    try await VirtualCameraOperationExecution.request(
                        .audio(request), timeout: .seconds(30)))
                completion?()
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
