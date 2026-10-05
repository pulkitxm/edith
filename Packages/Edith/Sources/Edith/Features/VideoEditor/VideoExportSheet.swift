import SwiftUI
import EdithKit

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
        case .source: "Project resolution"
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
    @State private var delivery = VideoDeliverySettings()
    @State private var audioDelivery = VideoAudioDeliverySettings()

    var body: some View {
        Group {
            if let job = exporter.job {
                progress(job)
            } else {
                options
            }
        }
        .padding(24)
        .frame(width: UIScale.pt(480))
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Export", systemImage: "square.and.arrow.up")
                .font(.title2.weight(.semibold))
            EdithSegmentedPicker(
                "Format", selection: $format, options: ["mp4", "audio", "gif"],
                label: {
                    switch $0 {
                    case "mp4": "Video / master"
                    case "audio": "Audio mix"
                    default: "Animated GIF"
                    }
                })
            if format == "mp4" {
                Picker("Resolution", selection: $quality) {
                    ForEach(VideoExportQuality.available(for: model.pipeline?.canvas ?? .zero)) {
                        option in
                        Text(option.title).tag(option)
                    }
                }
                if let size = model.pipeline?.canvas {
                    Text(
                        "Project: \(Int(size.width)) × \(Int(size.height)) at \(sourceFPS.formatted(.number.precision(.fractionLength(2)))) fps."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                encodingOptions
            } else if format == "audio" {
                audioOptions
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
                    if format == "audio" {
                        model.exportAudio(settings: audioDelivery)
                    } else {
                        model.export(gif: format == "gif", quality: quality, delivery: delivery)
                    }
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

    private var encodingOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Video codec", selection: $delivery.codec) {
                ForEach(VideoDeliverySettings.Codec.allCases) { codec in
                    Text(codec.title).tag(codec)
                }
            }
            .onChange(of: delivery.codec) { _, codec in
                delivery.audioCodec = codec.isMaster ? .pcm : .aac
                if codec.isMaster { delivery.requireHardware = false }
                if !codec.isMaster && delivery.audioSampleRate == 96_000 {
                    delivery.audioSampleRate = 48_000
                }
            }
            if !delivery.codec.isMaster {
                HStack {
                    Text("Video bitrate (Mbps)")
                    TextField(
                        "Mbps",
                        value: Binding(
                            get: { delivery.bitRate / 1_000_000 },
                            set: { delivery.bitRate = min(1000, max(1, $0)) * 1_000_000 }
                        ), format: .number
                    )
                    .frame(width: UIScale.pt(80))
                }
                Stepper(
                    "Keyframe interval: \(delivery.keyFrameInterval) frames",
                    value: $delivery.keyFrameInterval, in: 1...600)
                Toggle("Require hardware encoding", isOn: $delivery.requireHardware)
            }
            Picker("Audio", selection: $delivery.audioCodec) {
                Text("AAC").tag(VideoDeliverySettings.AudioCodec.aac)
                if delivery.codec.isMaster {
                    Text("24-bit PCM").tag(VideoDeliverySettings.AudioCodec.pcm)
                }
            }
            .onChange(of: delivery.audioCodec) { _, codec in
                if codec == .aac && delivery.audioSampleRate == 96_000 {
                    delivery.audioSampleRate = 48_000
                }
            }
            HStack {
                Picker("Sample rate", selection: $delivery.audioSampleRate) {
                    Text("44.1 kHz").tag(44_100)
                    Text("48 kHz").tag(48_000)
                    if delivery.audioCodec == .pcm { Text("96 kHz").tag(96_000) }
                }
                Picker("Channels", selection: $delivery.audioChannels) {
                    Text("Mono").tag(1)
                    Text("Stereo").tag(2)
                }
                .onChange(of: delivery.audioChannels) { _, channels in
                    if channels == 1 { delivery.audioBitRate = min(256_000, delivery.audioBitRate) }
                }
            }
            if delivery.audioCodec == .aac {
                Picker("Audio bitrate", selection: $delivery.audioBitRate) {
                    Text("128 kbps").tag(128_000)
                    Text("192 kbps").tag(192_000)
                    Text("256 kbps").tag(256_000)
                    if delivery.audioChannels == 2 { Text("320 kbps").tag(320_000) }
                }
            }
            Text(
                delivery.codec.isMaster
                    ? "High-precision QuickTime master with Rec. 709 color. ProRes is an intermediate codec, not a lossless copy."
                    : "Rec. 709 delivery. Hardware acceleration is preferred; requiring it fails if this Mac cannot encode these settings."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var audioOptions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Container", selection: $audioDelivery.container) {
                Text("WAV, 24-bit PCM").tag(VideoAudioDeliverySettings.Container.wav)
                Text("AIFF, 24-bit PCM").tag(VideoAudioDeliverySettings.Container.aiff)
                Text("M4A, AAC").tag(VideoAudioDeliverySettings.Container.m4a)
            }
            .onChange(of: audioDelivery.container) { _, container in
                if container == .m4a && audioDelivery.sampleRate == 96_000 {
                    audioDelivery.sampleRate = 48_000
                }
            }
            Picker("Sample rate", selection: $audioDelivery.sampleRate) {
                Text("44.1 kHz").tag(44_100)
                Text("48 kHz").tag(48_000)
                if audioDelivery.container != .m4a { Text("96 kHz").tag(96_000) }
            }
            Picker("Channels", selection: $audioDelivery.channels) {
                Text("Mono").tag(1)
                Text("Stereo").tag(2)
            }
            .onChange(of: audioDelivery.channels) { _, channels in
                if channels == 1 { audioDelivery.bitRate = min(256_000, audioDelivery.bitRate) }
            }
            if audioDelivery.container == .m4a {
                Picker("Bitrate", selection: $audioDelivery.bitRate) {
                    Text("128 kbps").tag(128_000)
                    Text("192 kbps").tag(192_000)
                    Text("256 kbps").tag(256_000)
                    if audioDelivery.channels == 2 { Text("320 kbps").tag(320_000) }
                }
            }
            Text(
                "Exports the complete timeline mix, including music, detached audio, gains and fades."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
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
                if let report = job.report {
                    Text(
                        "\(report.width) × \(report.height) · \(report.frameCount) frames · \(report.videoCodec)"
                    )
                    .font(.callout)
                    Text("SHA-256: \(report.sha256)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                if let report = job.audioReport {
                    Text(
                        "\(Int(report.sampleRate)) Hz · \(report.channels) channels · \(report.frames) samples"
                    )
                    .font(.callout)
                    Text("SHA-256: \(report.sha256)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
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
        return 1 / duration
    }
}
