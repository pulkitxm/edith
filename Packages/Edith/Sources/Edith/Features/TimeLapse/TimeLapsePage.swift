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
                "Time-lapse needs macOS 15", systemImage: "timelapse",
                description: Text("Update macOS to record displays, windows and optional audio."))
        }
    }
}

@available(macOS 15.0, *)
struct TimeLapseControls: View {
    @State private var recorder = TimeLapseRecorder.shared
    @State private var recordings: [TimeLapseRecording] = []
    @State private var selected: UUID?
    @State private var quality = TimeLapseExportQuality.original
    @State private var exporting = false
    @State private var message: String?
    @State private var choosingSources = false
    @State private var optionsExpanded = false
    @State private var libraryExpanded = false
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
        _libraryExpanded = State(
            initialValue: !recordings.isEmpty && recorder?.preview != nil
                && recorder?.recording == false)
        self.loadsSources = loadsSources
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: UIScale.pt(20)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                        Label("Time-lapse", systemImage: "timelapse").font(
                            .title2.weight(.semibold))
                        Text(recorder.recording ? recordingSummary : "Capture hours in minutes.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if recorder.recording || recorder.preview != nil {
                        capturePreview(
                            height: min(
                                UIScale.pt(compact ? 260 : 400),
                                max(UIScale.pt(180), geometry.size.height - UIScale.pt(280))))
                    }
                    if recorder.recording {
                        recordingStatus
                    } else {
                        captureControls.disabled(recorder.busy || !enabled)
                    }
                    if !enabled {
                        Text("Enable Time-lapse in Extensions to record.")
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
                .padding(UIScale.pt(24)).frame(maxWidth: UIScale.pt(960))
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("Time-lapse")
        .sheet(isPresented: $choosingSources) {
            TimeLapseSourcePicker(recorder: recorder, compact: compact)
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
                if loadsSources { Task { await refreshLibrary() } }
            }
        }
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
                HStack(spacing: UIScale.pt(16)) {
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Text("Time-lapse speed").font(.caption).foregroundStyle(.secondary)
                        Picker("Time-lapse speed", selection: $recorder.settings.speed) {
                            ForEach(TimeLapseSettings.speeds, id: \.self) { speed in
                                Text("\(Int(speed))×").tag(speed)
                            }
                        }.labelsHidden()
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
                        .frame(maxWidth: compact ? .infinity : nil)
                }.buttonStyle(.borderedProminent).tint(.red)
                    .disabled(!recorder.canStart)
            }
            DisclosureGroup(isExpanded: $optionsExpanded) {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    captureLayout {
                        Toggle("System audio", isOn: $recorder.settings.systemAudio)
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
                        "Audio is recorded at normal speed and exported separately. System audio includes apps across the desktop."
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
            Text("1 hour becomes \(playbackEstimate) · About \(estimatedStorage) per hour")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(UIScale.pt(20))
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
    }

    private var captureLayout: AnyLayout {
        compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(12)))
            : AnyLayout(HStackLayout(alignment: .bottom, spacing: UIScale.pt(16)))
    }

    private var sourceSummary: String {
        let displays = recorder.sourceMode == "displays"
        let count = displays ? recorder.selectedDisplays.count : recorder.selectedWindows.count
        let noun = displays ? "display" : "window"
        return count == 0 ? "Choose \(noun)s" : "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private var audioSummary: String {
        if recorder.settings.systemAudio && !recorder.microphone.isEmpty { return "System + mic" }
        if recorder.settings.systemAudio { return "System audio" }
        return recorder.microphone.isEmpty ? "No audio" : "Microphone"
    }

    private var recordingSummary: String {
        "\(sourceSummary) · \(Int(recorder.settings.speed))× · \(audioSummary)"
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
                    metric("Playback", duration(Double(recorder.frames) / 30))
                    metric(
                        "Saved",
                        ByteCountFormatter.string(fromByteCount: recorder.bytes, countStyle: .file))
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Button {
                Task { await recorder.stop() }
            } label: {
                Label(recorder.busy ? "Finishing…" : "Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: compact ? .infinity : nil)
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
                    Picker("Recording", selection: $selected) {
                        Text("Choose a recording").tag(UUID?.none)
                        ForEach(recordings) { recording in
                            Text(
                                "\(recording.session.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(duration(recording.session.playbackSeconds))\(recording.session.endedAt == nil ? " · interrupted" : "")"
                            )
                            .tag(Optional(recording.id))
                        }
                    }
                    if let recording = recordings.first(where: { $0.id == selected }) {
                        Picker("Export quality", selection: $quality) {
                            ForEach(TimeLapseExportQuality.allCases) { quality in
                                Text(quality.rawValue).tag(quality)
                            }
                        }
                        if let failure = recording.session.failure {
                            Text(failure).font(.callout).foregroundStyle(.orange)
                        }
                        HStack {
                            Button(exporting ? "Exporting…" : "Export video…") { export(recording) }
                                .disabled(exporting || recording.session.frames == 0)
                            if recording.session.segments.contains(where: { $0.kind != "video" }) {
                                Menu("Export audio") {
                                    ForEach(["system", "microphone"], id: \.self) { kind in
                                        if recording.session.segments.contains(where: {
                                            $0.kind == kind
                                        }) {
                                            Button(
                                                kind == "system" ? "System audio…" : "Microphone…"
                                            ) {
                                                export(recording, kind: kind)
                                            }
                                        }
                                    }
                                }
                            }
                            Spacer()
                            Button {
                                NSWorkspace.shared.open(recording.directory)
                            } label: {
                                Image(systemName: "folder")
                            }.help("Show recording files").accessibilityLabel(
                                "Show recording files")
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
            if selected == nil { selected = recordings.first?.id }
        } catch { message = error.localizedDescription }
    }

    private func export(_ recording: TimeLapseRecording, kind: String = "video") {
        let panel = NSSavePanel()
        let video = kind == "video"
        let quality = quality
        let extensionName = video ? quality.fileExtension : "m4a"
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName)!]
        panel.nameFieldStringValue = "Time-lapse-\(kind).\(extensionName)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exporting = true
        message = "Exporting..."
        Task {
            defer { exporting = false }
            do {
                try await TimeLapseExporter.export(
                    recording, quality: quality, to: destination, kind: kind)
                message = "Saved \(destination.lastPathComponent)."
                NSWorkspace.shared.activateFileViewerSelecting([destination])
            } catch { message = error.localizedDescription }
        }
    }
}
