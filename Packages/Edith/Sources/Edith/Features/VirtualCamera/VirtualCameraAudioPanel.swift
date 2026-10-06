import AppKit
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct VirtualCameraAudioPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var devices: [MeetingAudioDevice] = []
    @State private var snippetName = ""
    @State private var editing: MeetingAudioClip?
    var section = Section.sounds

    enum Section: String, CaseIterable {
        case sounds = "Sounds"
        case voice = "Voice"
        case devices = "Devices"
    }

    private var audio: MeetingAudioState { model.state.audio }
    private var status: MeetingAudioStatus? { model.snapshot?.audioStatus }

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            switch section {
            case .sounds:
                soundboard
                sounds
            case .voice: voice
            case .devices: deviceSettings
            }
        }
        .pageTask { if section == .devices { refreshDevices() } }
        .edithSheet(item: $editing, dismissible: !model.audioPending) { clip in
            VirtualCameraClipEditor(model: model, clip: clip) { editing = nil }
        }
    }

    private var soundboard: some View {
        VirtualCameraPanelSection(title: "Soundboard", dark: dark) {
            LazyVGrid(
                columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: UIScale.pt(8)
            ) {
                ForEach(MeetingSound.allCases, id: \.self) { sound in
                    let playing = status?.playing.contains(sound.id.uuidString) == true
                    Button {
                        model.performAudio(playing ? .stopClips : .playClip(sound.identifier))
                    } label: {
                        HStack(spacing: UIScale.pt(8)) {
                            Image(systemName: playing ? "stop.fill" : sound.symbol)
                                .frame(width: UIScale.pt(20))
                            Text(sound.name).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, minHeight: UIScale.pt(24))
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(status?.running != true || model.audioPending)
                    .accessibilityLabel("\(playing ? "Stop" : "Play") \(sound.name)")
                }
            }
            if status?.running != true {
                Text("Enable meeting audio to send sounds through your meeting microphone.")
                    .font(.edithText(.caption)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var sounds: some View {
        VirtualCameraPanelSection(title: "Snippets & sound effects", dark: dark) {
            HStack {
                TextField("Snippet name (optional)", text: $snippetName)
                    .textFieldStyle(.roundedBorder)
                Button(status?.recordingName == nil ? "Record mic" : "Save") {
                    model.performAudio(
                        status?.recordingName == nil
                            ? .recordClip(
                                snippetName.isEmpty
                                    ? "Snippet \(audio.clips.count + 1)" : snippetName)
                            : .finishClip)
                }
                .buttonStyle(.edith(.secondary)).disabled(model.audioPending)
            }
            HStack {
                Menu("Upload audio") {
                    Button("Speech snippet…") { importClip(speech: true) }
                    Button("Sound effect…") { importClip(speech: false) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if status?.playing.isEmpty == false {
                    Button("Stop all") { model.performAudio(.stopClips) }
                        .buttonStyle(.edith(.secondary)).disabled(model.audioPending)
                }
            }
            if let name = status?.recordingName {
                Label("Recording \(name)", systemImage: "record.circle")
                    .foregroundStyle(.red).font(.edithText(.body))
            }
            if audio.clips.isEmpty {
                Text("Record a greeting or import a sound to play during your meeting.")
                    .font(.edithText(.body)).foregroundStyle(DashSkin.inkSoft(dark))
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(audio.clips) { clip in
                let playing = status?.playing.contains(clip.id.uuidString) == true
                HStack(spacing: UIScale.pt(12)) {
                    Button {
                        model.performAudio(playing ? .stopClips : .playClip(clip.id.uuidString))
                    } label: {
                        Image(systemName: playing ? "stop.fill" : "play.fill")
                            .frame(width: UIScale.pt(24), height: UIScale.pt(28))
                    }
                    .buttonStyle(.edith(.secondary))
                    .disabled(status?.running != true || model.audioPending)
                    .accessibilityLabel("\(playing ? "Stop" : "Play") \(clip.name)")
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Text(clip.name).font(.edithText(.body)).lineLimit(1)
                        Text(clip.speech ? "Speech" : "Sound effect")
                            .font(.edithText(.caption)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Edit…") { editing = clip }
                        Button("Remove") { model.performAudio(.removeClip(clip.id.uuidString)) }
                    } label: {
                        Image(systemName: "ellipsis").frame(
                            width: UIScale.pt(24), height: UIScale.pt(28))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Options for \(clip.name)")
                }
                .padding(.vertical, UIScale.pt(4))
            }
        }
    }

    private var voice: some View {
        VirtualCameraPanelSection(title: "Your voice", dark: dark) {
            Grid(
                alignment: .leading, horizontalSpacing: UIScale.pt(12),
                verticalSpacing: UIScale.pt(12)
            ) {
                GridRow {
                    Text("Voice model").font(.edithText(.body))
                    Picker(
                        "Voice model",
                        selection: Binding(
                            get: { audio.voiceModelID?.uuidString ?? "" },
                            set: { model.performAudio(.selectVoice($0)) })
                    ) {
                        Text("Original voice").tag("")
                        ForEach(audio.voiceModels) { Text($0.name).tag($0.id.uuidString) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                GridRow {
                    Text("Effect").font(.edithText(.body))
                    Picker(
                        "Effect",
                        selection: Binding(
                            get: { audio.preset },
                            set: { value in model.update { $0.audio.preset = value } })
                    ) {
                        ForEach(MeetingVoicePreset.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .font(.edithText(.body))
            DisclosureGroup("Fine tune") {
                VStack(spacing: UIScale.pt(12)) {
                    if audio.voiceModelID != nil {
                        adjustment(
                            "Model pitch", value: Double(audio.voiceTranspose), range: -24...24
                        ) {
                            value in
                            model.update { $0.audio.voiceTranspose = Float(value.rounded()) }
                        }
                    }
                    adjustment("Pitch", value: Double(audio.pitch), range: -1200...1200) {
                        value in model.update { $0.audio.pitch = Float(value) }
                    }
                    adjustment("Reverb", value: Double(audio.reverb), range: 0...100) {
                        value in model.update { $0.audio.reverb = Float(value) }
                    }
                    adjustment("Echo", value: Double(audio.delay), range: 0...100) {
                        value in model.update { $0.audio.delay = Float(value) }
                    }
                }
                .padding(.top, UIScale.pt(12))
            }
            .font(.edithText(.body))
            HStack {
                Button("Import voice…") { model.importVoiceModel() }
                    .buttonStyle(.edith(.secondary)).disabled(model.audioPending)
                    .help("Choose a ContentVec encoder and an RVC ONNX voice model")
                Spacer()
                if let id = audio.voiceModelID {
                    Button("Remove") { model.performAudio(.removeVoice(id.uuidString)) }
                        .buttonStyle(.edith(.borderless)).disabled(model.audioPending)
                }
            }
            if audio.voiceModelID != nil {
                Text("Voice conversion adds about half a second of buffering.")
                    .font(.edithText(.caption)).foregroundStyle(DashSkin.inkSoft(dark))
            }
        }
    }

    private var deviceSettings: some View {
        VirtualCameraPanelSection(title: "Audio devices", dark: dark) {
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text("Microphone input").font(.edithText(.body))
                Picker(
                    "Microphone input",
                    selection: Binding(
                        get: { audio.inputID ?? "" }, set: { model.performAudio(.input($0)) })
                ) {
                    Text("System microphone").tag("")
                    ForEach(devices.filter { $0.inputChannels > 0 }) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
                Text("Meeting microphone").font(.edithText(.body)).padding(.top, UIScale.pt(8))
                Picker(
                    "Meeting microphone",
                    selection: Binding(
                        get: { audio.outputID ?? "" }, set: { model.performAudio(.output($0)) })
                ) {
                    Text(MeetingMicrophone.name).tag("")
                    ForEach(devices.filter { $0.virtual && $0.outputChannels > 0 }) {
                        Text($0.name).tag($0.id)
                    }
                }
                .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Choose this virtual microphone in Meet. Your device choices stay saved.")
                .font(.edithText(.caption)).foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            if status?.running != true
                && !devices.contains(where: { $0.id == MeetingMicrophone.id })
            {
                Text(MeetingMicrophone.setupMessage).font(.edithText(.caption))
            }
            Button("Refresh devices") { refreshDevices() }.buttonStyle(.edith(.secondary))
            DisclosureGroup("Mix levels") {
                VStack(spacing: UIScale.pt(12)) {
                    adjustment("Mic", value: Double(audio.micGain), range: 0...2) {
                        value in model.update { $0.audio.micGain = Float(value) }
                    }
                    adjustment("Clips", value: Double(audio.clipsGain), range: 0...2) {
                        value in model.update { $0.audio.clipsGain = Float(value) }
                    }
                    adjustment("Source", value: Double(audio.sourceGain), range: 0...2) {
                        value in model.update { $0.audio.sourceGain = Float(value) }
                    }
                }.padding(.top, UIScale.pt(12))
            }
            .font(.edithText(.body))
        }
    }

    private func adjustment(
        _ name: String, value: Double, range: ClosedRange<Double>,
        change: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            HStack {
                Text(name).font(.edithText(.body))
                Spacer()
                Text(String(format: "%.0f", range.upperBound == 2 ? value * 100 : value))
                    .font(.edithText(.caption)).monospacedDigit()
            }
            Slider(value: Binding(get: { value }, set: change), in: range)
                .accessibilityLabel(name)
        }
    }

    private func refreshDevices() {
        Task {
            devices = await Task.detached(priority: .utility) { MeetingAudioDevices.list() }.value
        }
    }

    private func importClip(speech: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.performAudio(
            .importClip(
                name: snippetName.isEmpty
                    ? url.deletingPathExtension().lastPathComponent : snippetName,
                path: url.path, speech: speech))
    }
}

struct VirtualCameraClipEditor: View {
    @ObservedObject var model: VirtualCameraPageModel
    let clip: MeetingAudioClip
    let dismiss: () -> Void
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
    func importVoiceModel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "onnx") ?? .data]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the ContentVec ONNX encoder"
        guard panel.runModal() == .OK, let encoder = panel.url else { return }
        panel.message = "Choose an RVC ONNX voice model"
        guard panel.runModal() == .OK, let voice = panel.url else { return }
        performAudio(
            .importVoice(
                name: voice.deletingPathExtension().lastPathComponent,
                encoder: encoder.path, voice: voice.path))
    }

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
