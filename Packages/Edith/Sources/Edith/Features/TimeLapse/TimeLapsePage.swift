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
        self.loadsSources = loadsSources
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Screen time-lapse", systemImage: "timelapse").font(.largeTitle.bold())
                    Spacer()
                    if let directory = recorder.lastDirectory {
                        Button("Show recording") { NSWorkspace.shared.open(directory) }
                    }
                }
                Text(
                    "Capture hours or days in a small video. Completed segments stay saved as you record."
                )
                .foregroundStyle(.secondary)
                if recorder.recording {
                    recordingStatus
                } else {
                    captureControls.disabled(recorder.busy || !enabled)
                    HStack {
                        Button("Refresh sources") { Task { await recorder.loadSources() } }
                            .disabled(recorder.busy)
                        Spacer()
                        Button(recorder.busy ? "Starting..." : "Start time-lapse") {
                            Task { await recorder.start() }
                        }.buttonStyle(.borderedProminent).disabled(!recorder.canStart || !enabled)
                    }
                }
                if !enabled {
                    Text("Enable Time-lapse in Extensions to start a recording.").foregroundStyle(
                        .secondary)
                }
                if let error = recorder.error {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                Divider()
                library
                if let message { Text(message).textSelection(.enabled) }
            }.padding(24).frame(maxWidth: UIScale.pt(960))
        }
        .navigationTitle("Time-lapse")
        .task {
            if loadsSources {
                await recorder.loadSources()
                await refreshLibrary()
            }
        }
        .onChange(of: recorder.recording) { _, recording in
            if !recording { Task { await refreshLibrary() } }
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox("Capture source") {
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Record", selection: $recorder.sourceMode) {
                        Text("Displays").tag("displays")
                        Text("Windows").tag("windows")
                    }.pickerStyle(.segmented)
                    ScrollView {
                        VStack(alignment: .leading) {
                            if recorder.sourceMode == "displays" {
                                ForEach(
                                    Array(recorder.displays.enumerated()), id: \.element.id
                                ) { index, display in
                                    Toggle(
                                        "Display \(index + 1), \(display.width) × \(display.height)",
                                        isOn: membership(
                                            display.id, in: $recorder.selectedDisplays))
                                }
                            } else {
                                ForEach(recorder.windows, id: \.id) { window in
                                    Toggle(
                                        "\(window.application): \(window.title)",
                                        isOn: membership(
                                            window.id, in: $recorder.selectedWindows))
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: UIScale.pt(180))
                    Text(
                        "Select up to 16 sources. Multiple displays or windows appear in a grid; each selected window is captured independently."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }.padding(8)
            }
            captureLayout {
                GroupBox("Time and quality") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Capture one frame every", selection: $recorder.settings.interval) {
                            ForEach(TimeLapseSettings.intervals, id: \.self) { interval in
                                Text("\(Int(interval)) seconds").tag(interval)
                            }
                        }
                        Picker("Capture resolution", selection: $recorder.settings.maximumDimension)
                        {
                            Text("Up to 1080p").tag(1920)
                            Text("Up to 4K").tag(3840)
                            Text("Source, up to 8K").tag(7680)
                        }
                        Toggle("Include cursor", isOn: $recorder.settings.showCursor)
                        Toggle("Keep Mac and screen awake", isOn: $recorder.settings.keepAwake)
                        Text(
                            "\(Int(recorder.settings.speed))× playback at 30 fps. Export quality is chosen after recording; capture resolution limits the final detail."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "Sleeping, blank or unavailable sources are skipped. Keeping the screen awake uses more power."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
                GroupBox("Audio sources") {
                    VStack(alignment: .leading, spacing: 10) {
                        Toggle("System audio", isOn: $recorder.settings.systemAudio)
                        Picker("Microphone", selection: $recorder.microphone) {
                            Text("None").tag("")
                            Text("System default").tag("default")
                            ForEach(recorder.microphones, id: \.id) { device in
                                Text(device.name).tag(device.id)
                            }
                        }
                        Text(
                            "Audio is saved at normal speed in separate tracks. Export system audio and microphone recordings separately after stopping. System audio captures apps across the desktop."
                        )
                        .font(.caption).foregroundStyle(.secondary)
                        Text(
                            "Approximate storage per hour: \(estimatedStorage). Video is sampled; continuous audio grows with elapsed time."
                        )
                        .font(.callout).foregroundStyle(.secondary)
                    }.padding(8)
                }
            }
        }
    }

    private var captureLayout: AnyLayout {
        compact
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: UIScale.pt(16)))
            : AnyLayout(HStackLayout(alignment: .top, spacing: UIScale.pt(16)))
    }

    private var estimatedStorage: String {
        var settings = recorder.settings
        settings.microphoneID = recorder.microphone.isEmpty ? nil : recorder.microphone
        return ByteCountFormatter.string(
            fromByteCount: Int64(settings.estimatedBytes(hours: 1)), countStyle: .file)
    }

    private var recordingStatus: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(
                        "Recording for \(duration(context.date.timeIntervalSince(recorder.startedAt ?? context.date)))"
                    )
                    .font(.title2.monospacedDigit()).foregroundStyle(.red)
                }
                Text(
                    "\(recorder.frames) frames · \(duration(Double(recorder.frames) / 30)) playback · \(ByteCountFormatter.string(fromByteCount: recorder.bytes, countStyle: .file))"
                )
                .monospacedDigit()
                Text(
                    "You can leave this page while recording. Quitting Edith finalizes the current segment before exit."
                )
                .foregroundStyle(.secondary)
                Button(recorder.busy ? "Finishing..." : "Stop recording") {
                    Task { await recorder.stop() }
                }.buttonStyle(.borderedProminent).disabled(recorder.busy)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
        }
    }

    private var library: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recordings").font(.title2.bold())
                Spacer()
                Button("Refresh library") { Task { await refreshLibrary() } }
            }
            if recordings.isEmpty {
                Text(
                    "Finished and interrupted sessions appear here. Completed segments from an interrupted recording can still be exported."
                )
                .foregroundStyle(.secondary)
            } else {
                Picker("Session", selection: $selected) {
                    Text("Choose a recording").tag(UUID?.none)
                    ForEach(recordings) { recording in
                        Text(
                            "\(recording.session.startedAt.formatted()) · \(duration(recording.session.playbackSeconds))\(recording.session.endedAt == nil ? " · interrupted" : "")"
                        )
                        .tag(Optional(recording.id))
                    }
                }
                if let recording = recordings.first(where: { $0.id == selected }) {
                    Text(
                        "\(recording.session.width) × \(recording.session.height) · \(recording.session.frames) saved frames"
                    )
                    .foregroundStyle(.secondary)
                    if let failure = recording.session.failure {
                        Text(failure).foregroundStyle(.orange)
                    }
                    Picker("Export quality", selection: $quality) {
                        ForEach(TimeLapseExportQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    HStack {
                        Button(exporting ? "Exporting..." : "Export video...") { export(recording) }
                            .disabled(exporting || recording.session.frames == 0)
                        ForEach(["system", "microphone"], id: \.self) { kind in
                            if recording.session.segments.contains(where: { $0.kind == kind }) {
                                Button("Export \(kind) audio...") { export(recording, kind: kind) }
                                    .disabled(exporting)
                            }
                        }
                        Spacer()
                        Button("Show files") { NSWorkspace.shared.open(recording.directory) }
                    }
                    Text(
                        "Original capture preserves quality and exports fastest. ProRes produces larger files for editing. Capture segments are kept after export."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.disabled(exporting)
    }

    private func membership<Value: Hashable>(_ value: Value, in selection: Binding<Set<Value>>)
        -> Binding<Bool>
    {
        Binding(
            get: { selection.wrappedValue.contains(value) },
            set: { selected in
                if selected {
                    selection.wrappedValue.insert(value)
                } else {
                    selection.wrappedValue.remove(value)
                }
            })
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
