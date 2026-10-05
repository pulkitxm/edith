import AVFoundation
import AppKit
import EdithCore
import EdithKit
import SwiftUI
import UniformTypeIdentifiers

struct TimeLapsePage: View {
    var body: some View {
        if #available(macOS 15.0, *) {
            TimeLapseControls()
        } else {
            ContentUnavailableView(
                "Screen Recorder needs macOS 15", systemImage: "record.circle",
                description: Text("Update macOS to record displays, windows and optional audio."))
        }
    }
}

@available(macOS 15.0, *)
struct TimeLapseControls: View {
    @State private var recorder = TimeLapseRecorder.shared
    @State private var recordings: [TimeLapseRecording] = []
    @State private var selected: UUID?
    @State private var quality = TimeLapseExportQuality.high
    @State private var exporting = false
    @State private var message: String?
    @State private var choosingSources = false
    @State private var optionsExpanded = false
    @State private var libraryExpanded = false
    @State private var viewportWidth: CGFloat = 0
    @AppStorage(AppStorageKeys.Tabs.timeLapseEnabled, store: SharedDefaults.store) private
        var enabled = false
    @Environment(\.compactLayout) private var compact
    private let loadsSources: Bool

    init(
        recorder: TimeLapseRecorder? = nil, recordings: [TimeLapseRecording] = [],
        loadsSources: Bool = true
    ) {
        _recorder = State(initialValue: recorder ?? TimeLapseRecorder.shared)
        _recordings = State(initialValue: recordings)
        _selected = State(initialValue: recordings.first?.id)
        _libraryExpanded = State(initialValue: !recordings.isEmpty)
        self.loadsSources = loadsSources
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(20)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Label("Screen Recorder", systemImage: "record.circle").font(
                            .title2.weight(.semibold))
                        Text(
                            recorder.recording
                                ? recordingSummary : "Record your screen, at your pace."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }
                    if recorder.recording {
                        recordingStatus
                    } else {
                        captureControls.disabled(recorder.busy || !enabled)
                    }
                    if recorder.recording || recorder.preview != nil {
                        capturePreview(height: previewHeight(in: geometry.size))
                    }
                    if !enabled {
                        Text("Enable Screen Recorder in Extensions to record.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if let error = recorder.error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.red).textSelection(.enabled)
                    }
                    Divider()
                    library
                    if let message { Text(message).font(.callout).textSelection(.enabled) }
                }
                .padding(UIScale.pt(narrow ? 16 : 24))
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            viewportWidth = $0
        }
        .navigationTitle("Screen Recorder")
        .sheet(isPresented: $choosingSources) {
            TimeLapseSourcePicker(recorder: recorder, compact: narrow)
        }
        .onAppear { recorder.showPreview(true) }
        .onDisappear { recorder.showPreview(false) }
        .task {
            if loadsSources {
                await recorder.loadSources()
                await refreshLibrary()
            }
        }
        .onChange(of: recorder.recording) { _, recording in
            if !recording {
                libraryExpanded = true
                if loadsSources {
                    Task {
                        await refreshLibrary()
                        selected = recordings.first?.id
                    }
                }
            }
        }
    }

    private var narrow: Bool {
        viewportWidth > 0 ? viewportWidth < UIScale.pt(800) : compact
    }

    private var captureSettingsLayout: AnyLayout {
        viewportWidth > 0 && viewportWidth < UIScale.pt(480)
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: UIScale.pt(16)))
    }

    private func previewHeight(in size: CGSize) -> CGFloat {
        let padding = UIScale.pt(narrow ? 16 : 24)
        let width = max(UIScale.pt(120), size.width - padding * 2)
        let ratio = recorder.preview.map { CGFloat($0.height) / CGFloat($0.width) } ?? 9 / 16
        let controls =
            recorder.recording
            ? UIScale.pt(narrow ? 120 : 60)
            : UIScale.pt(narrow ? 290 : 200)
        let library =
            libraryExpanded
            ? UIScale.pt(120 + Double(min(recordings.count, 3)) * 68) : UIScale.pt(32)
        let options = optionsExpanded && !recorder.recording ? UIScale.pt(narrow ? 240 : 150) : 0
        let reserved = padding * 2 + UIScale.pt(160) + controls + library + options
        return max(UIScale.pt(120), min(width * ratio, size.height - reserved))
    }

    private func capturePreview(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(8)) {
            Color.black.frame(height: height)
                .overlay {
                    if let image = recorder.preview {
                        Image(image, scale: 1, label: Text("Last captured recording frame"))
                            .resizable().scaledToFit()
                    } else {
                        VStack(spacing: UIScale.pt(10)) {
                            ProgressView().tint(.white)
                            Text("Waiting for the first frame").font(.callout)
                        }.foregroundStyle(.white.opacity(0.7))
                    }
                }
                .overlay(alignment: .topLeading) {
                    HStack(spacing: UIScale.pt(6)) {
                        if recorder.recording {
                            Circle().fill(.red).frame(width: UIScale.pt(7), height: UIScale.pt(7))
                        }
                        Text(recorder.recording ? "Recording" : "Last recording")
                    }
                    .font(.caption.weight(.medium)).foregroundStyle(.white)
                    .padding(.horizontal, UIScale.pt(10)).padding(.vertical, UIScale.pt(6))
                    .background(.black.opacity(0.65), in: Capsule()).padding(UIScale.pt(12))
                }
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(12)))
            HStack {
                Text("\(recorder.frames) saved frames")
                Spacer()
                Text(
                    recorder.recording
                        ? "\(Int(recorder.settings.speed))× speed"
                        : "Last captured frame")
            }.font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            Picker("Recording mode", selection: $recorder.settings.mode) {
                ForEach(ScreenRecordingMode.allCases) { mode in Text(mode.rawValue).tag(mode) }
            }.pickerStyle(.segmented).labelsHidden()
            captureLayout {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Text("Source").font(.caption).foregroundStyle(.secondary)
                    Button {
                        choosingSources = true
                    } label: {
                        HStack {
                            Label(
                                sourceSummary,
                                systemImage: recorder.sourceMode == "displays"
                                    ? "display" : "macwindow")
                            Spacer()
                            Image(systemName: "chevron.down").font(.caption)
                        }.frame(maxWidth: .infinity)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                captureSettingsLayout {
                    if recorder.settings.mode == .timeLapse {
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            Text("Time-lapse speed").font(.caption).foregroundStyle(.secondary)
                            Picker("Time-lapse speed", selection: $recorder.settings.speed) {
                                ForEach(TimeLapseSettings.speeds, id: \.self) { speed in
                                    Text("\(Int(speed))×").tag(speed)
                                }
                            }.labelsHidden()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            Text("Frame rate").font(.caption).foregroundStyle(.secondary)
                            Picker("Frame rate", selection: $recorder.settings.frameRate) {
                                Text("30 fps").tag(Int32(30))
                                Text("60 fps").tag(Int32(60))
                            }.labelsHidden()
                        }
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Text("Capture quality").font(.caption).foregroundStyle(.secondary)
                        Picker("Capture resolution", selection: $recorder.settings.maximumDimension)
                        {
                            Text("1080p").tag(1920)
                            Text("4K").tag(3840)
                            Text("Source, up to 8K").tag(7680)
                        }.labelsHidden().help(
                            "Export quality is chosen after recording. Capture resolution limits the final detail."
                        )
                    }
                }
                Button {
                    Task { await recorder.start() }
                } label: {
                    Label(recorder.busy ? "Starting…" : "Record", systemImage: "record.circle")
                        .frame(maxWidth: narrow ? .infinity : nil)
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!recorder.canStart)
            }
            DisclosureGroup(isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    captureLayout {
                        Toggle(sourceAudioLabel, isOn: $recorder.settings.systemAudio)
                        Picker("Microphone", selection: $recorder.microphone) {
                            Text("None").tag("")
                            Text("System default").tag("default")
                            ForEach(recorder.microphones, id: \.id) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                    }
                    captureLayout {
                        Toggle("Include cursor", isOn: $recorder.settings.showCursor)
                        Toggle("Keep Mac and screen awake", isOn: $recorder.settings.keepAwake)
                            .help("Prevents idle sleep while recording and uses more power.")
                    }
                    Text(
                        recorder.settings.mode == .standard
                            ? "Audio stays synchronized and is included in your video. \(audioScopeDescription)"
                            : "Audio is sped up with your time-lapse and included in the video. \(audioScopeDescription)"
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, UIScale.pt(10))
            } label: {
                HStack {
                    Text("Audio & options")
                    Spacer()
                    Text(audioSummary).font(.caption).foregroundStyle(.secondary)
                }.font(.callout)
            }
            Text(
                recorder.settings.mode == .standard
                    ? "Normal speed · About \(estimatedStorage) per hour"
                    : "1 hour becomes \(playbackEstimate) · About \(estimatedStorage) per hour"
            )
            .font(.caption).foregroundStyle(.secondary)
        }
        .padding(UIScale.pt(20))
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    private var captureLayout: AnyLayout {
        narrow
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: UIScale.pt(16)))
    }

    private var sourceSummary: String {
        let displays = recorder.sourceMode == "displays"
        let count = displays ? recorder.selectedDisplays.count : recorder.selectedWindows.count
        let noun = displays ? "display" : "window"
        return count == 0 ? "Choose \(noun)s" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private var sourceAudioLabel: String {
        recorder.sourceMode == "windows" ? "Selected app audio" : "System audio"
    }

    private var audioScopeDescription: String {
        recorder.sourceMode == "windows"
            ? "Audio follows the selected apps, including their other windows."
            : "System audio includes apps across the desktop."
    }

    private var audioSummary: String {
        if recorder.settings.systemAudio && !recorder.microphone.isEmpty {
            return recorder.sourceMode == "windows" ? "App audio + mic" : "System + mic"
        }
        if recorder.settings.systemAudio { return sourceAudioLabel }
        return recorder.microphone.isEmpty ? "No audio" : "Microphone"
    }

    private var recordingSummary: String {
        "\(sourceSummary) · \(recorder.settings.mode.rawValue) · \(Int(recorder.settings.speed))× · \(audioSummary)"
    }

    private var estimatedStorage: String {
        var settings = recorder.settings
        settings.microphoneID = recorder.microphone.isEmpty ? nil : recorder.microphone
        return ByteCountFormatter.string(
            fromByteCount: Int64(settings.estimatedBytes(hours: 1)), countStyle: .file)
    }

    private var playbackEstimate: String {
        let seconds = Int((3600 / recorder.settings.speed).rounded())
        if seconds >= 60 {
            let minutes = seconds / 60
            return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        }
        return "\(seconds) seconds"
    }

    private var recordingStatus: some View {
        captureLayout {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: UIScale.pt(24)) {
                    metric(
                        "Elapsed",
                        duration(context.date.timeIntervalSince(recorder.startedAt ?? context.date))
                    )
                    metric("Playback", duration(recorder.playbackSeconds))
                    metric(
                        "Saved",
                        ByteCountFormatter.string(fromByteCount: recorder.bytes, countStyle: .file))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await recorder.stop() }
            } label: {
                Label(recorder.busy ? "Finishing…" : "Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: narrow ? .infinity : nil)
            }.buttonStyle(.borderedProminent).tint(.red).disabled(recorder.busy)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.weight(.medium)).monospacedDigit()
        }
    }

    private var library: some View {
        DisclosureGroup(isExpanded: $libraryExpanded) {
            VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                if recordings.isEmpty {
                    Text("Your recordings will appear here.").foregroundStyle(.secondary)
                } else {
                    LazyVStack(spacing: UIScale.pt(8)) {
                        ForEach(recordings) { recording in
                            recordingRow(recording)
                        }
                    }
                    if let recording = recordings.first(where: { $0.id == selected }) {
                        captureLayout {
                            Picker("Export quality", selection: $quality) {
                                ForEach(TimeLapseExportQuality.allCases) { quality in
                                    Text(quality.rawValue).tag(quality)
                                }
                            }
                            Button(exporting ? "Exporting…" : "Export video…") { export(recording) }
                                .disabled(exporting || recording.session.frames == 0)
                        }
                        if let failure = recording.session.failure {
                            Text(failure).font(.callout).foregroundStyle(.orange)
                        }
                    }
                }
            }.padding(.top, UIScale.pt(12)).disabled(exporting)
        } label: {
            HStack {
                Text("Recordings").font(.callout.weight(.medium))
                Text("\(recordings.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await refreshLibrary() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.borderless).help("Refresh recordings")
                    .accessibilityLabel("Refresh recordings")
            }
        }
    }

    private func recordingRow(_ recording: TimeLapseRecording) -> some View {
        let isSelected = selected == recording.id
        return Button {
            selected = recording.id
        } label: {
            HStack(spacing: UIScale.pt(12)) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                    Text(recording.session.settings.mode.rawValue).font(.callout.weight(.medium))
                    Text(
                        recording.session.startedAt.formatted(date: .abbreviated, time: .shortened)
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: UIScale.pt(8))
                VStack(alignment: .trailing, spacing: UIScale.pt(4)) {
                    Text(duration(recording.session.playbackSeconds))
                        .font(.callout).monospacedDigit()
                    if recording.session.endedAt == nil {
                        Text("Interrupted").font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            .padding(UIScale.pt(12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(
            isSelected ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: UIScale.pt(8))
        )
        .overlay {
            RoundedRectangle(cornerRadius: UIScale.pt(8))
                .stroke(
                    isSelected ? Color.accentColor.opacity(0.5) : .clear, lineWidth: UIScale.pt(1))
        }
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func duration(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    private func refreshLibrary() async {
        do {
            let root = TimeLapseRecorder.libraryURL
            let active = recorder.recording ? recorder.lastDirectory : nil
            recordings = try await Task.detached(priority: .utility) {
                try TimeLapseRecording.load(in: root).filter { $0.directory != active }
            }.value
            if !recordings.contains(where: { $0.id == selected }) {
                selected = recordings.first?.id
                libraryExpanded = !recordings.isEmpty
            }
        } catch { message = error.localizedDescription }
    }

    private func export(_ recording: TimeLapseRecording) {
        let panel = NSSavePanel()
        let quality = quality
        let extensionName = quality.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName)!]
        panel.nameFieldStringValue =
            "\(recording.session.settings.mode == .standard ? "Recording" : "Time-lapse").\(extensionName)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        message = "Exporting..."
        Task {
            defer { exporting = false }
            do {
                try await TimeLapseExporter.export(
                    recording, quality: quality, to: destination)
                message = "Saved \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { message = error.localizedDescription }
        }
    }
}
