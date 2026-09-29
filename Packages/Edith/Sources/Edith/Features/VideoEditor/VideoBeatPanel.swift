import AVFoundation
import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@MainActor @Observable
final class VideoBeatPanelState {
    private(set) var result: VideoBeatAnalysis.Result?
    private(set) var isAnalyzing = false
    var error: String?
    private var generation = UUID()
    private var worker: Task<VideoBeatAnalysis.Result, Error>?
    private var observer: Task<Void, Never>?

    func analyze(_ url: URL, settings: VideoBeatAnalysis.Settings) {
        clear()
        isAnalyzing = true
        let version = generation
        worker = Task.detached(priority: .userInitiated) {
            try await VideoBeatAnalysis.analyze(url, settings: settings)
        }
        guard let task = worker else { return }
        observer = Task { [weak self] in
            do {
                let result = try await task.value
                guard let self, self.generation == version, !Task.isCancelled else { return }
                self.result = result
                self.isAnalyzing = false
                self.worker = nil
                self.observer = nil
            } catch {
                guard let self, self.generation == version, !Task.isCancelled else { return }
                self.error = error is CancellationError ? nil : error.localizedDescription
                self.isAnalyzing = false
                self.worker = nil
                self.observer = nil
            }
        }
    }

    func cancel() {
        generation = UUID()
        worker?.cancel()
        observer?.cancel()
        worker = nil
        observer = nil
        isAnalyzing = false
    }

    func clear() {
        cancel()
        result = nil
        error = nil
    }

    static func frameRate(_ duration: CMTime) throws -> VideoMarkerFrameRate {
        guard duration.isNumeric, duration.value > 0, duration.timescale > 0 else {
            throw VideoMarkerError.invalidFrameRate
        }
        return try VideoMarkerFrameRate(
            numerator: Int(duration.timescale), denominator: Int(duration.value))
    }

    static func edit(
        _ model: VideoEditorModel, change: (inout VideoProject) throws -> Void
    ) throws {
        guard var project = model.project else { return }
        try change(&project)
        model.mutate { $0 = project }
    }
}

struct VideoBeatMapping {
    var sourceStart: Double = 0
    var sourceEnd: Double = 0
    var outputStart: Double = 0
    var rate: Double = 1

    func outputTime(for source: Double) -> Double {
        outputStart + (source - sourceStart) / rate
    }

    func markers(
        from result: VideoBeatAnalysis.Result, frameRate: VideoMarkerFrameRate
    ) throws -> [VideoMarker] {
        guard sourceStart.isFinite, sourceEnd.isFinite, sourceStart >= 0,
            sourceEnd > sourceStart, sourceEnd <= result.duration,
            outputStart.isFinite, outputStart >= 0, rate.isFinite, (0.05...20).contains(rate)
        else { throw VideoBeatAnalysis.AnalysisError.invalidSettings }
        return try result.markers(
            frameRate: frameRate, sourceRange: sourceStart..<sourceEnd,
            outputStart: outputStart, playbackRate: rate)
    }
}

struct VideoBeatPanel: View {
    let model: VideoEditorModel
    @State private var analysis = VideoBeatPanelState()
    @State private var selectedAssetID = ""
    @State private var sensitivity = 0.5
    @State private var spacing = 0.15
    @State private var mapping = VideoBeatMapping()
    @State private var markerLabel = "Marker"
    @State private var snapThreshold = 3
    @Environment(\.dismiss) private var dismiss

    private var assets: [VideoProject.Asset] {
        model.project?.assets.filter {
            $0.raw["edithSourceImagePath"] == nil && $0.raw["kind"] as? String != "image"
        } ?? []
    }

    private var sourceURL: URL? {
        guard let asset = assets.first(where: { $0.id == selectedAssetID }) else { return nil }
        return (asset.raw["edithAudioPath"] as? String).map(URL.init(fileURLWithPath:)) ?? asset.url
    }

    private var frameRate: VideoMarkerFrameRate {
        guard let duration = model.pipeline?.videoComposition.frameDuration else { return .fps30 }
        return (try? VideoBeatPanelState.frameRate(duration)) ?? .fps30
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Waveform & markers", systemImage: "waveform").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            analysisControls
            if let result = analysis.result {
                waveform(result)
                mappingControls(result)
            } else {
                ContentUnavailableView(
                    analysis.isAnalyzing ? "Reading audio samples" : "Analyze an audio source",
                    systemImage: "waveform",
                    description: Text("Measured peaks and detected transients appear here.")
                )
                .frame(height: 130)
            }
            if let error = analysis.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            markerControls
            markerList
        }
        .padding(24)
        .frame(width: 820, height: 720)
        .onAppear {
            selectedAssetID = assets.first?.id ?? ""
            mapping.outputStart = model.playhead
        }
        .onChange(of: sourceURL) { _, _ in analysis.clear() }
        .onChange(of: model.project?.id) { _, _ in
            analysis.clear()
            selectedAssetID = assets.first?.id ?? ""
        }
        .onChange(of: analysis.result?.duration) { _, duration in
            guard let duration else { return }
            mapping.sourceStart = 0
            mapping.sourceEnd = duration
        }
        .onDisappear { analysis.cancel() }
    }

    private var analysisControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Audio source", selection: $selectedAssetID) {
                    Text("Select media").tag("")
                    ForEach(assets) { Text($0.label).tag($0.id) }
                }
                Button(analysis.result == nil ? "Analyze" : "Reanalyze") {
                    guard let sourceURL else { return }
                    var settings = VideoBeatAnalysis.Settings()
                    settings.sensitivity = sensitivity
                    settings.minimumSpacingSeconds = spacing
                    analysis.analyze(sourceURL, settings: settings)
                }
                .disabled(sourceURL == nil || analysis.isAnalyzing)
                .buttonStyle(.borderedProminent)
                if analysis.isAnalyzing {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { analysis.cancel() }
                }
            }
            HStack {
                Text("Sensitivity")
                Slider(value: $sensitivity, in: 0...1).frame(width: 140)
                Text(sensitivity.formatted(.percent.precision(.fractionLength(0))))
                    .monospacedDigit().frame(width: 40)
                Spacer()
                Text("Minimum spacing (s)")
                TextField("Minimum spacing", value: $spacing, format: .number)
                    .frame(width: 65).textFieldStyle(.roundedBorder)
            }
            .font(.caption)
        }
    }

    private func waveform(_ result: VideoBeatAnalysis.Result) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            VideoMeasuredWaveform(result: result, mapping: mapping, playhead: model.playhead) {
                sourceTime in
                guard sourceTime >= mapping.sourceStart, sourceTime <= mapping.sourceEnd,
                    mapping.rate.isFinite, mapping.rate > 0
                else { return }
                let output = mapping.outputTime(for: sourceTime)
                guard output.isFinite else { return }
                model.seek(to: output)
            }
            .frame(height: 100)
            HStack {
                Text("Source 0.000s")
                Spacer()
                Text("\(result.transients.count) detected transients")
                    .foregroundStyle(.orange)
                Spacer()
                Text("\(result.duration.formatted(.number.precision(.fractionLength(3))))s")
            }
            .font(.caption.monospacedDigit())
            if result.transientsTruncated {
                Text("Detection limit reached. Only the first transients are listed.")
                    .font(.caption).foregroundStyle(.orange)
            } else if let estimate = result.tempoEstimate {
                Text(
                    "Interval estimate: \(estimate.beatsPerMinute.formatted(.number.precision(.fractionLength(1)))) BPM. Transients are not confirmed musical beats."
                )
                .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Transients mark amplitude onsets. No consistent tempo inferred.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func mappingControls(_ result: VideoBeatAnalysis.Result) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                numberField("Source in (s)", value: $mapping.sourceStart)
                numberField("Source out (s)", value: $mapping.sourceEnd)
                numberField("Output start (s)", value: $mapping.outputStart)
                numberField("Playback rate", value: $mapping.rate)
            }
            HStack {
                Button("Use playhead offset") { mapping.outputStart = model.playhead }
                Button("Use selected clip") { useSelectedClip() }
                    .disabled(!canUseSelectedClip)
                Spacer()
                Button("Add transient markers") {
                    edit { project in
                        let additions = try mapping.markers(from: result, frameRate: frameRate)
                        let existing = Set(
                            project.markers.compactMap { try? frameRate.frame(at: $0.seconds) })
                        try project.setMarkers(
                            project.markers + additions.filter { !existing.contains($0.frame) })
                    }
                }
                .disabled(model.pipeline == nil)
                .buttonStyle(.borderedProminent)
            }
            Text(
                "Output = offset + (source − in) / rate. Audio-track offsets and loops are entered explicitly; markers stay at output positions after video edits."
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func numberField(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(title, value: value, format: .number)
                .textFieldStyle(.roundedBorder).monospacedDigit()
        }
    }

    private var canUseSelectedClip: Bool {
        model.pipeline?.segments.contains {
            $0.clip.id == model.selectedClipID && $0.clip.assetID == selectedAssetID
        } == true
    }

    private func useSelectedClip() {
        let segments =
            model.pipeline?.segments.filter {
                $0.clip.id == model.selectedClipID && $0.clip.assetID == selectedAssetID
            } ?? []
        guard
            let segment = segments.first(where: {
                model.playhead >= $0.outputStart && model.playhead < $0.outputEnd
            }) ?? segments.first
        else { return }
        mapping = VideoBeatMapping(
            sourceStart: segment.sourceStart, sourceEnd: segment.sourceEnd,
            outputStart: segment.outputStart, rate: segment.rate)
    }

    private var markerControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Output markers").font(.headline)
                Text(frameRate.label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Import…") { importMarkers() }
                Button("Export…") { exportMarkers() }
                Button("Undo", action: model.undo).disabled(!model.canUndo)
                Button("Redo", action: model.redo).disabled(!model.canRedo)
            }
            HStack {
                TextField("Marker label", text: $markerLabel).textFieldStyle(.roundedBorder)
                    .frame(width: 140)
                Button("Add at playhead") {
                    edit { project in
                        try project.addMarker(
                            atFrame: frameRate.frame(at: model.playhead), frameRate: frameRate,
                            label: markerLabel)
                    }
                }
                Spacer()
                Stepper("Within \(snapThreshold) frames", value: $snapThreshold, in: 0...120)
                    .fixedSize()
                Button("Snap playhead") {
                    guard let frame = try? frameRate.frame(at: model.playhead),
                        let snapped = model.project?.snapToMarker(
                            frame: frame, thresholdFrames: Int64(snapThreshold),
                            frameRate: frameRate)
                    else { return }
                    model.seek(to: frameRate.seconds(at: snapped))
                }
            }
            .disabled(model.pipeline == nil)
            Text(
                "Playhead: \(frameRate.timecode(at: (try? frameRate.frame(at: model.playhead)) ?? 0))  ·  \(model.playhead.formatted(.number.precision(.fractionLength(3)))) output seconds"
            )
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private var markerList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.project?.markers ?? []) { marker in
                    VideoBeatMarkerRow(marker: marker, duration: model.duration) {
                        model.seek(to: marker.seconds)
                    } save: { frame, label in
                        edit { try $0.updateMarker(marker.id, frame: frame, label: label) }
                    } remove: {
                        edit { try $0.removeMarker(marker.id) }
                    }
                }
                if model.project?.markers.isEmpty != false {
                    Text("Add a marker at the playhead or turn detected transients into markers.")
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func edit(_ change: (inout VideoProject) throws -> Void) {
        do {
            try VideoBeatPanelState.edit(model, change: change)
            analysis.error = nil
        } catch { analysis.error = error.localizedDescription }
    }

    private func importMarkers() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        edit { try $0.importMarkers(Data(contentsOf: url)) }
    }

    private func exportMarkers() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "markers.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try model.project?.exportMarkers().write(to: url, options: .atomic) } catch {
            analysis.error = error.localizedDescription
        }
    }
}

private struct VideoBeatMarkerRow: View {
    let marker: VideoMarker
    let duration: Double
    let seek: () -> Void
    let save: (Int64, String) -> Void
    let remove: () -> Void
    @State private var frame: Int64 = 0
    @State private var label = ""

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: marker.kind == .transient ? "waveform" : "bookmark")
                .foregroundStyle(marker.kind == .transient ? .orange : .secondary)
            TextField("Label", text: $label).textFieldStyle(.roundedBorder)
            TextField("Output frame", value: $frame, format: .number.grouping(.never))
                .frame(width: 80).textFieldStyle(.roundedBorder)
                .help("Output frame at the marker's saved frame rate")
            Button(marker.timecode, action: seek)
                .font(.caption.monospacedDigit()).buttonStyle(.link)
                .disabled(marker.seconds > duration)
                .help("Seek to marker output time")
            Button("Save") { save(frame, label) }
                .disabled(frame == marker.frame && label == marker.label)
            Button(action: remove) { Image(systemName: "trash") }
                .accessibilityLabel("Remove \(marker.label)")
        }
        .onAppear { resetDraft() }
        .onChange(of: marker) { _, _ in resetDraft() }
    }

    private func resetDraft() {
        frame = marker.frame
        label = marker.label
    }
}

private struct VideoMeasuredWaveform: View {
    let result: VideoBeatAnalysis.Result
    let mapping: VideoBeatMapping
    let playhead: Double
    let seek: (Double) -> Void

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                guard result.duration > 0 else { return }
                let scale = size.width / result.duration
                if mapping.sourceStart.isFinite, mapping.sourceEnd.isFinite,
                    mapping.sourceEnd > mapping.sourceStart
                {
                    let start = max(0, min(result.duration, mapping.sourceStart))
                    let end = max(start, min(result.duration, mapping.sourceEnd))
                    context.fill(
                        Path(
                            CGRect(
                                x: start * scale, y: 0, width: (end - start) * scale,
                                height: size.height)), with: .color(.accentColor.opacity(0.08)))
                }
                for bin in result.waveform {
                    let x = Double(bin.startSample) / result.sampleRate * scale
                    let width = max(1, Double(bin.sampleCount) / result.sampleRate * scale)
                    let height = max(1, Double(bin.peak) * size.height * 0.9)
                    context.fill(
                        Path(
                            CGRect(
                                x: x, y: (size.height - height) / 2, width: width, height: height)),
                        with: .color(.accentColor.opacity(0.7)))
                }
                for transient in result.transients {
                    let x = Double(transient.sample) / result.sampleRate * scale
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                        with: .color(.orange.opacity(0.8)))
                }
                let sourcePlayhead =
                    mapping.sourceStart + (playhead - mapping.outputStart) * mapping.rate
                if sourcePlayhead.isFinite, sourcePlayhead >= 0, sourcePlayhead <= result.duration {
                    context.fill(
                        Path(
                            CGRect(x: sourcePlayhead * scale, y: 0, width: 2, height: size.height)),
                        with: .color(.red))
                }
            }
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { event in
                    guard geometry.size.width > 0 else { return }
                    seek(max(0, min(1, event.location.x / geometry.size.width)) * result.duration)
                })
        }
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
        .accessibilityLabel(
            "Measured audio waveform with \(result.transients.count) detected transients"
        )
        .help("Click within the selected source range to seek to its mapped output time")
    }
}
