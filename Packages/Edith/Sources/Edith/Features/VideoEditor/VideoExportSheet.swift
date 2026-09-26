import SwiftUI

enum VideoExportQuality: String, CaseIterable, Identifiable {
    case source
    case ultraHD
    case quadHD
    case fullHD
    case hd
    case sd

    var id: String { rawValue }

    var maxDimension: Int? {
        switch self {
        case .source: nil
        case .ultraHD: 3840
        case .quadHD: 2560
        case .fullHD: 1920
        case .hd: 1280
        case .sd: 854
        }
    }

    var title: String {
        switch self {
        case .source: "Match source quality"
        case .ultraHD: "4K UHD"
        case .quadHD: "1440p QHD"
        case .fullHD: "1080p Full HD"
        case .hd: "720p HD"
        case .sd: "480p SD"
        }
    }

    static func available(for size: CGSize) -> [VideoExportQuality] {
        let longest = max(size.width, size.height)
        return allCases.filter { quality in
            guard let dimension = quality.maxDimension else { return true }
            return longest >= CGFloat(dimension)
        }
    }
}

struct VideoExportSheet: View {
    let model: VideoEditorModel
    var exporter = VideoExporter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var format = "mp4"
    @State private var quality: VideoExportQuality = .source

    var body: some View {
        Group {
            if let job = exporter.job {
                progress(job)
            } else {
                options
            }
        }
        .padding(24)
        .frame(width: 420)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.title2.weight(.semibold))
            Picker("Format", selection: $format) {
                Text("MP4 video").tag("mp4")
                Text("Animated GIF").tag("gif")
            }
            .pickerStyle(.segmented)
            if format == "mp4" {
                Picker("Quality", selection: $quality) {
                    ForEach(VideoExportQuality.available(for: model.pipeline?.canvas ?? .zero)) {
                        option in
                        Text(option.title).tag(option)
                    }
                }
                if let size = model.pipeline?.canvas {
                    Text(
                        "Source: \(Int(size.width)) × \(Int(size.height)). Exports never upscale the source."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Picker(
                    "Frames per second",
                    selection: Binding(
                        get: { model.gifFPS }, set: { model.gifFPS = $0 }
                    )
                ) {
                    Text("10 fps").tag(10)
                    if sourceFPS >= 15 { Text("15 fps").tag(15) }
                    if sourceFPS >= 24 { Text("24 fps").tag(24) }
                    if sourceFPS >= 30 { Text("30 fps").tag(30) }
                }
                Picker(
                    "Width",
                    selection: Binding(
                        get: { model.gifWidth }, set: { model.gifWidth = $0 }
                    )
                ) {
                    Text("Match source").tag(0)
                    if (model.pipeline?.canvas.width ?? 0) >= 480 {
                        Text("480 px").tag(480)
                    }
                    if (model.pipeline?.canvas.width ?? 0) >= 720 {
                        Text("720 px").tag(720)
                    }
                    if (model.pipeline?.canvas.width ?? 0) >= 960 {
                        Text("960 px").tag(960)
                    }
                }
                Toggle(
                    "Loop",
                    isOn: Binding(
                        get: { model.gifLoop }, set: { model.gifLoop = $0 }
                    ))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    model.export(gif: format == "gif", quality: quality)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.pipeline == nil)
            }
        }
        .onAppear {
            if model.gifFPS > Int(sourceFPS) { model.gifFPS = 10 }
            if model.gifWidth > Int(model.pipeline?.canvas.width ?? 0) {
                model.gifWidth = 0
            }
        }
    }

    private func progress(_ job: VideoExporter.Job) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            switch job.phase {
            case .exporting:
                Label("Exporting", systemImage: "square.and.arrow.up")
                    .font(.title2.weight(.semibold))
                destination(job)
                ProgressView(value: job.progress)
                HStack {
                    Text(job.progress.formatted(.percent.precision(.fractionLength(0))))
                    Spacer()
                    if let remaining = job.secondsRemaining {
                        Text("About \(Self.remaining(remaining)) left")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                Text(
                    "You can close this, or even quit Edith. The export keeps running in the background."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Stop Export", role: .destructive) { exporter.cancel() }
                    Button("Hide") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .finished:
                Label("Export finished", systemImage: "checkmark.circle.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.green, .primary)
                destination(job)
                HStack {
                    Spacer()
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([job.destination])
                    }
                    Button("Done") { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            case .failed(let message):
                Label("Export failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.title2.weight(.semibold))
                destination(job)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                HStack {
                    Spacer()
                    Button("Done") { close() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private func destination(_ job: VideoExporter.Job) -> some View {
        Text(job.destination.lastPathComponent)
            .font(.callout)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    private func close() {
        exporter.clear()
        dismiss()
    }

    static func remaining(_ seconds: Double) -> String {
        Duration.seconds(max(1, seconds.rounded())).formatted(
            .units(
                allowed: [.hours, .minutes, .seconds], width: .wide, maximumUnitCount: 1))
    }

    private var sourceFPS: Double {
        guard let duration = model.pipeline?.videoComposition.frameDuration.seconds,
            duration > 0
        else { return 30 }
        return 1 / duration + 0.01
    }
}
