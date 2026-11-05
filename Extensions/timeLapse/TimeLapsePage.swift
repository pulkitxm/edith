import AVFoundation
import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI
import UniformTypeIdentifiers

struct TimeLapseSettingsPage: View {
    var body: some View {
        Form {
            Section("Recorder") {
                Button("Open Screen Recorder") { ExtensionPresentation.showWindow() }
                Text(
                    "Record displays or selected windows at normal speed, or choose Time-lapse. Choose export quality after stopping."
                )
                .settingsCaption()
            }
        }
        .edithForm()
    }
}

enum TimeLapseGuidance {
    static func pollInterval(recording: Bool) -> Duration {
        recording ? .milliseconds(250) : .seconds(2)
    }

    static func startHint(
        canStart: Bool, busy: Bool, sourceMode: String, selectedCount: Int, loadingSources: Bool
    ) -> String? {
        if canStart || busy { return nil }
        if loadingSources { return "Looking for displays and windows…" }
        if selectedCount == 0 {
            return sourceMode == "displays"
                ? "Choose at least one display to enable Record."
                : "Choose at least one window to enable Record."
        }
        return "Recording is unavailable right now."
    }

    static func modeSummary(_ mode: ScreenRecordingMode) -> String {
        switch mode {
        case .standard: "Records at normal speed with sound, like any screen recording."
        case .timeLapse:
            "Captures one frame every few seconds and plays them back fast. Ideal for long work sessions."
        }
    }
}

@available(macOS 15.0, *)
struct TimeLapseControls: View {
    @State private var recorder: TimeLapseRecorder
    @State private var libraryModel: TimeLapseLibraryModel
    @State private var selected: UUID?
    @State private var quality = TimeLapseExportQuality.high
    @State private var choosingSources = false
    @State private var optionsExpanded = false
    @State private var libraryExpanded = false
    @State private var previewConsumer = UUID()
    @State private var libraryRefresh = 0
    @State private var sourcesRefresh = 0
    @State private var elapsedDate = Date()
    @Environment(\.compactLayout) private var compact
    @Environment(\.windowVisible) private var visible
    private let loadsSources: Bool
    private let extensionEnabled: Bool

    init(
        recorder: TimeLapseRecorder, recordings: [TimeLapseRecording] = [],
        loadsSources: Bool = true, enabled: Bool? = nil
    ) {
        let library =
            loadsSources ? recorder.library : TimeLapseLibraryModel(recordings: recordings)
        _recorder = State(initialValue: recorder)
        _libraryModel = State(initialValue: library)
        _selected = State(initialValue: library.recordings.first?.id)
        _libraryExpanded = State(initialValue: !library.recordings.isEmpty)
        self.loadsSources = loadsSources
        extensionEnabled = enabled ?? true
    }

    var body: some View {
        GeometryReader { geometry in
            PageScaffold {
                PageHeader(
                    "Screen Recorder",
                    accessory: {
                        Text(
                            recorder.recording
                                ? recordingSummary : "Record your screen, at your pace."
                        )
                        .font(.edithText(.callout)).foregroundStyle(.secondary)
                    })
            } content: {
                if recorder.recording {
                    recordingStatus
                } else if extensionEnabled, loadsSources, recorder.screenRecordingDenied,
                    !recorder.sourceLoad.hasContent
                {
                    PageEmptyState(
                        symbolName: "lock.display",
                        title: "Allow Screen Recording to get started",
                        message:
                            "macOS asks you to approve screen capture once. Without it Edith cannot see your displays or windows, so there is nothing to record yet.",
                        steps: [
                            PageGuideStep(
                                symbolName: "gearshape", title: "Open System Settings",
                                detail: "Go to Privacy & Security, then Screen Recording."),
                            PageGuideStep(
                                symbolName: "switch.2", title: "Turn Edith on",
                                detail: "You may need to reopen Edith after changing it."),
                            PageGuideStep(
                                symbolName: "arrow.clockwise", title: "Come back and try again",
                                detail: "Your displays and windows will appear here."),
                        ],
                        primary: PageAction(
                            "Open System Settings", symbolName: "gearshape",
                            identifier: "timelapse.open-settings"
                        ) { TimeLapseScreenRecordingAccess.request() },
                        secondary: PageAction("Try Again", symbolName: "arrow.clockwise") {
                            sourcesRefresh += 1
                        },
                        footnote: "Recordings stay on this Mac. Edith never uploads them."
                    )
                    .frame(minHeight: UIScale.pt(420))
                } else {
                    PageLoading(
                        state: !extensionEnabled || !loadsSources
                            ? .content : recorder.sourceLoad.state,
                        message: recorder.sourceLoad.errorMessage
                            ?? "Choose sources for your recording.",
                        layout: .cards, refreshing: recorder.sourceLoad.isRefreshing,
                        retry: { sourcesRefresh += 1 }
                    ) {
                        captureControls.disabled(recorder.busy || !extensionEnabled)
                    }
                    if recorder.sourceLoad.hasContent, let error = recorder.sourceLoad.errorMessage
                    {
                        PageNotice(
                            error, tone: .error,
                            actions: {
                                Button("Retry") { sourcesRefresh += 1 }
                            })
                    }
                }
                if recorder.recording || recorder.preview != nil {
                    capturePreview(height: previewHeight(in: geometry.size))
                }
                if !extensionEnabled {
                    PageNotice(
                        "Turn on Screen Recorder in the Extensions list to start recording. Your saved recordings stay available.",
                        title: "Screen Recorder is turned off", tone: .warning)
                }
                if let error = recorder.error {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.edithText(.callout)).foregroundStyle(.red).textSelection(.enabled)
                }
                Divider()
                library
                if let message = libraryModel.message {
                    Text(message).font(.edithText(.callout)).textSelection(.enabled)
                }
            }
        }
        .pageTask {
            while !Task.isCancelled {
                await recorder.refreshRemote()
                guard !Task.isCancelled else { return }
                let delay = TimeLapseGuidance.pollInterval(recording: recorder.recording)
                do { try await Task.sleep(for: delay) } catch { return }
            }
        }
        .onChange(of: recorder.configuration) { _, _ in recorder.pushConfiguration() }
        .navigationTitle("Screen Recorder")
        .edithSheet(isPresented: $choosingSources, dismissible: false) {
            TimeLapseSourcePicker(recorder: recorder, compact: narrow)
        }
        .onAppear { recorder.showPreview(visible, consumer: previewConsumer) }
        .onDisappear { recorder.showPreview(false, consumer: previewConsumer) }
        .onChange(of: visible) { _, visible in
            recorder.showPreview(visible, consumer: previewConsumer)
        }
        .pageTask(id: sourcesRefresh, active: loadsSources && extensionEnabled) {
            if !recorder.sourceLoad.hasContent || sourcesRefresh > 0 {
                await recorder.loadSources()
            }
        }
        .pageTask(id: "\(recorder.recording)-\(libraryRefresh)", active: loadsSources) {
            await libraryModel.refresh(excluding: recorder.recording ? recorder.lastDirectory : nil)
            guard !Task.isCancelled else { return }
            if selected == nil || !recordings.contains(where: { $0.id == selected }) {
                selected = recordings.first?.id
                libraryExpanded = !recordings.isEmpty
            }
        }
        .pageRefresh(active: recorder.recording, interval: { .seconds(1) }) {
            elapsedDate = .now
        }
        .onChange(of: recorder.recording) { _, recording in
            if !recording {
                libraryExpanded = true
                selected = nil
            }
        }
    }

    private var narrow: Bool { compact }
    private var recordings: [TimeLapseRecording] { libraryModel.recordings }
    private var exporting: Bool { libraryModel.exporting }

    private var captureSettingsLayout: AnyLayout {
        compact
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
                            LoadingIndicator("Waiting for the first frame")
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
                    .font(.edithText(.caption)).fontWeight(.medium).foregroundStyle(.white)
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
            }.font(.edithText(.caption)).foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var captureControls: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            EdithSegmentedPicker(
                "Recording mode", selection: $recorder.settings.mode,
                options: ScreenRecordingMode.allCases, label: { $0.rawValue })
            Text(TimeLapseGuidance.modeSummary(recorder.settings.mode))
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            captureLayout {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Text("Source").font(.edithText(.caption)).foregroundStyle(.secondary)
                    Button {
                        choosingSources = true
                    } label: {
                        HStack {
                            Label(
                                sourceSummary,
                                systemImage: recorder.sourceMode == "displays"
                                    ? "display" : "macwindow")
                            Spacer()
                            Image(systemName: "chevron.down").font(.edithText(.caption))
                        }.frame(maxWidth: .infinity)
                    }
                    .help(
                        "Choose which \(recorder.sourceMode == "displays" ? "displays" : "windows") to record"
                    )
                }.frame(maxWidth: .infinity, alignment: .leading)
                captureSettingsLayout {
                    if recorder.settings.mode == .timeLapse {
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            Text("Time-lapse speed").font(.edithText(.caption)).foregroundStyle(
                                .secondary)
                            Picker("Time-lapse speed", selection: $recorder.settings.speed) {
                                ForEach(TimeLapseSettings.speeds, id: \.self) { speed in
                                    Text("\(Int(speed))×").tag(speed)
                                }
                            }.labelsHidden()
                        }
                    } else {
                        VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                            Text("Frame rate").font(.edithText(.caption)).foregroundStyle(
                                .secondary)
                            Picker("Frame rate", selection: $recorder.settings.frameRate) {
                                Text("30 fps").tag(Int32(30))
                                Text("60 fps").tag(Int32(60))
                            }.labelsHidden()
                        }
                    }
                    VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                        Text("Capture quality").font(.edithText(.caption)).foregroundStyle(
                            .secondary)
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
                }.buttonStyle(.edith(.primary)).tint(.red)
                    .disabled(!recorder.canStart)
                    .help(startHint ?? "Start recording")
            }
            if let startHint {
                Label(startHint, systemImage: "info.circle")
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
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
                    .font(.edithText(.caption)).foregroundStyle(.secondary)
                }.padding(.top, UIScale.pt(10))
            } label: {
                HStack {
                    Text("Audio & options")
                    Spacer()
                    Text(audioSummary).font(.edithText(.caption)).foregroundStyle(.secondary)
                }.font(.edithText(.callout))
            }
            Text(
                recorder.settings.mode == .standard
                    ? "Normal speed · About \(estimatedStorage) per hour"
                    : "1 hour becomes \(playbackEstimate) · About \(estimatedStorage) per hour"
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
        }
        .padding(UIScale.pt(20))
        .edithSurface(cornerRadius: 12)
    }

    private var startHint: String? {
        TimeLapseGuidance.startHint(
            canStart: recorder.canStart, busy: recorder.busy, sourceMode: recorder.sourceMode,
            selectedCount: recorder.sourceMode == "displays"
                ? recorder.selectedDisplays.count : recorder.selectedWindows.count,
            loadingSources: recorder.sourceLoad.isRunning)
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

    private var audioSummary: String {
        if recorder.settings.systemAudio && !recorder.microphone.isEmpty {
            return recorder.sourceMode == "windows" ? "App audio + mic" : "System + mic"
        }
        if recorder.settings.systemAudio { return sourceAudioLabel }
        return recorder.microphone.isEmpty ? "No audio" : "Microphone"
    }

    private var sourceAudioLabel: String {
        recorder.sourceMode == "windows" ? "Selected app audio" : "System audio"
    }

    private var audioScopeDescription: String {
        recorder.sourceMode == "windows"
            ? "Audio follows the selected apps, including their other windows."
            : "System audio includes apps across the desktop."
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
            HStack(spacing: UIScale.pt(24)) {
                metric(
                    "Elapsed",
                    duration(elapsedDate.timeIntervalSince(recorder.startedAt ?? elapsedDate))
                )
                metric("Playback", duration(recorder.playbackSeconds))
                metric(
                    "Saved",
                    ByteCountFormatter.string(fromByteCount: recorder.bytes, countStyle: .file))
            }.frame(maxWidth: .infinity, alignment: .leading)
            Button {
                Task { await recorder.stop() }
            } label: {
                Label(recorder.busy ? "Finishing…" : "Stop recording", systemImage: "stop.fill")
                    .frame(maxWidth: narrow ? .infinity : nil)
            }.buttonStyle(.edith(.primary)).tint(.red).disabled(recorder.busy)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: UIScale.pt(4)) {
            Text(title).font(.edithText(.caption)).foregroundStyle(.secondary)
            Text(value).font(.edithText(.title3)).fontWeight(.medium).monospacedDigit()
        }
    }

    private var library: some View {
        DisclosureGroup(isExpanded: $libraryExpanded) {
            PageLoading(
                state: !loadsSources ? .content : libraryModel.loading.state,
                message: libraryModel.loading.errorMessage ?? "Your recordings will appear here.",
                layout: .list, refreshing: libraryModel.loading.isRefreshing,
                retry: { libraryRefresh += 1 }
            ) {
                VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                    if recordings.isEmpty {
                        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
                            Text(
                                "No recordings yet. Press Record above, then stop when you are done. The recording shows up here, ready to export."
                            )
                            .font(.edithText(.callout)).foregroundStyle(.secondary)
                            PageGuideSteps(
                                steps: [
                                    PageGuideStep(
                                        symbolName: "display", title: "Pick a source",
                                        detail: "A whole display, or only the windows you choose."),
                                    PageGuideStep(
                                        symbolName: "record.circle", title: "Record",
                                        detail: "Recording keeps going if you leave this page."),
                                    PageGuideStep(
                                        symbolName: "square.and.arrow.up", title: "Export",
                                        detail: "Choose a quality and save a video file."),
                                ], columns: compact ? 1 : 3)
                        }
                    } else {
                        LazyVStack(spacing: UIScale.pt(8)) {
                            ForEach(recordings) { recording in
                                TimeLapseRecordingRow(
                                    recording: recording,
                                    duration: duration(recording.session.playbackSeconds),
                                    selected: selected == recording.id,
                                    action: { selected = recording.id })
                            }
                        }
                        if let recording = recordings.first(where: { $0.id == selected }) {
                            captureLayout {
                                Picker("Export quality", selection: $quality) {
                                    ForEach(TimeLapseExportQuality.allCases) { quality in
                                        Text(quality.rawValue).tag(quality)
                                    }
                                }
                                Button(exporting ? "Exporting…" : "Export video…") {
                                    export(recording)
                                }
                                .buttonStyle(.edith(.primary))
                                .disabled(exporting || recording.session.frames == 0)
                                .help(
                                    recording.session.frames == 0
                                        ? "This recording has no frames to export"
                                        : "Save the selected recording as a video file")
                            }
                            if let failure = recording.session.failure {
                                Text(failure).font(.edithText(.callout)).foregroundStyle(.orange)
                            }
                        }
                    }
                }.padding(.top, UIScale.pt(12)).disabled(exporting)
            }
            if libraryModel.loading.hasContent, let error = libraryModel.loading.errorMessage {
                PageNotice(
                    error, tone: .error,
                    actions: {
                        Button("Retry") { libraryRefresh += 1 }
                    })
            }
            if exporting {
                HStack {
                    LoadingIndicator("Exporting video")
                    Spacer()
                    Button("Cancel export") { recorder.cancelExport() }
                }
            }
        } label: {
            HStack {
                Text("Recordings").font(.edithText(.callout)).fontWeight(.medium)
                Text("\(recordings.count)").font(.edithText(.caption)).foregroundStyle(.secondary)
                Spacer()
                Button {
                    libraryRefresh += 1
                } label: {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.edith(.borderless)).help("Refresh recordings")
                    .accessibilityLabel("Refresh recordings")
            }
        }
    }

    private func duration(_ seconds: Double) -> String {
        let seconds = max(0, Int(seconds))
        let clock = String(
            format: "%02d:%02d:%02d", seconds % 86_400 / 3600, seconds / 60 % 60, seconds % 60)
        return seconds >= 86_400 ? "\(seconds / 86_400)d \(clock)" : clock
    }

    private func export(_ recording: TimeLapseRecording) {
        let panel = NSSavePanel()
        let quality = quality
        let extensionName = quality.fileExtension
        panel.allowedContentTypes = [UTType(filenameExtension: extensionName)!]
        panel.nameFieldStringValue =
            "\(recording.session.settings.mode == .standard ? "Recording" : "Time-lapse").\(extensionName)"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        libraryModel.export(recording, quality: quality, to: destination)
    }
}
