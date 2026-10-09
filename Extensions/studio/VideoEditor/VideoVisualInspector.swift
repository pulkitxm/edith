import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct VideoSettingsInspector: View {
    let model: VideoEditorModel
    private var settings: VideoSettings { model.project?.videoSettings ?? VideoSettings() }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Project video").font(.edithText(.headline))
            integer("Width", \.width)
            integer("Height", \.height)
            Menu("Canvas presets") {
                Button("1920 × 1080") { canvasPreset(1920, 1080) }
                Button("1080 × 1920") { canvasPreset(1080, 1920) }
                Button("1080 × 1080") { canvasPreset(1080, 1080) }
                Button("3840 × 2160") { canvasPreset(3840, 2160) }
            }
            integer("FPS numerator", \.frameRateNumerator)
            integer("FPS denominator", \.frameRateDenominator)
            Text("\(settings.frameRate.formatted(.number.precision(.fractionLength(0...3)))) fps")
                .foregroundStyle(.secondary)
            Menu("Frame rate presets") {
                ForEach([24, 25, 30, 50, 60, 120], id: \.self) { rate in
                    Button("\(rate) fps") { ratePreset(rate, 1) }
                }
                Button("23.976 fps") { ratePreset(24000, 1001) }
                Button("29.970 fps") { ratePreset(30000, 1001) }
                Button("59.940 fps") { ratePreset(60000, 1001) }
            }
            Picker(
                "Color space",
                selection: Binding(
                    get: { settings.colorSpace },
                    set: { value in
                        var next = settings
                        next.colorSpace = value
                        model.setVideoSettings(next)
                    })
            ) {
                Text("Rec. 709").tag(VideoSettings.ColorSpace.rec709)
                Text("Display P3").tag(VideoSettings.ColorSpace.displayP3)
            }
        }
    }

    private func integer(_ label: String, _ key: WritableKeyPath<VideoSettings, Int>) -> some View {
        HStack {
            Text(label)
            TextField(
                label,
                value: Binding(
                    get: { settings[keyPath: key] },
                    set: { value in
                        var next = settings
                        next[keyPath: key] = value
                        model.setVideoSettings(next)
                    }), format: .number.grouping(.never)
            )
            .multilineTextAlignment(.trailing).textFieldStyle(.roundedBorder)
        }
    }

    private func ratePreset(_ numerator: Int, _ denominator: Int) {
        var next = settings
        next.frameRateNumerator = numerator
        next.frameRateDenominator = denominator
        model.setVideoSettings(next)
    }

    private func canvasPreset(_ width: Int, _ height: Int) {
        var next = settings
        next.width = width
        next.height = height
        model.setVideoSettings(next)
    }
}

struct VideoVisualInspector: View {
    let model: VideoEditorModel
    let clip: VideoProject.Clip
    private let effects: VideoVisualEffects

    init(model: VideoEditorModel, clip: VideoProject.Clip) {
        self.model = model
        self.clip = clip
        effects = clip.visualEffects
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let asset = model.project?.assets.first(where: { $0.id == clip.assetID }) {
                let metadata = asset.raw["video"] as? [String: Any] ?? [:]
                Text(
                    "Source: \(metadata["width"] as? Int ?? 0) × \(metadata["height"] as? Int ?? 0)"
                )
                .foregroundStyle(.secondary)
                if let fps = metadata["fps"] as? Double {
                    Text("\(fps.formatted()) fps · \(metadata["codec"] as? String ?? "unknown")")
                        .foregroundStyle(.secondary)
                }
                if asset.isStill {
                    HStack {
                        Text("Still duration")
                        TextField(
                            "Seconds",
                            value: Binding(
                                get: { clip.duration },
                                set: {
                                    model.setStillDuration($0, clipID: clip.id)
                                }), format: .number
                        ).textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text("Framing & color").font(.edithText(.headline))
            Picker(
                "Framing",
                selection: Binding(
                    get: { effects.framing },
                    set: { value in
                        update { $0.framing = value }
                    })
            ) {
                Text("Fit").tag(VideoVisualEffects.Framing.fit)
                Text("Fill").tag(VideoVisualEffects.Framing.fill)
                Text("Full width").tag(VideoVisualEffects.Framing.fullWidth)
            }
            value("Focal X", \.focalX)
            value("Focal Y", \.focalY)
            Text("Grading mode").font(.edithText(.caption)).foregroundStyle(.secondary)
            Picker(
                "Grading mode",
                selection: Binding(
                    get: { effects.gradingMode },
                    set: { value in
                        update {
                            $0.gradingMode = value
                            if value == .native { $0.gradingDomain = .srgb }
                        }
                    })
            ) {
                Text("Native linear RGB").tag(VideoVisualEffects.GradingMode.native)
                Text("FFmpeg EQ, sRGB / 709").tag(VideoVisualEffects.GradingMode.ffmpeg709)
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
            if effects.gradingMode == .ffmpeg709 {
                Text("Grading domain").font(.edithText(.caption)).foregroundStyle(.secondary)
                Picker(
                    "Grading domain",
                    selection: Binding(
                        get: { effects.gradingDomain },
                        set: { value in update { $0.gradingDomain = value } })
                ) {
                    Text("sRGB photos").tag(VideoVisualEffects.GradingDomain.srgb)
                    Text("BT.709 video").tag(VideoVisualEffects.GradingDomain.bt709)
                    Text("BT.709 codes to sRGB").tag(VideoVisualEffects.GradingDomain.bt709ToSRGB)
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Text(
                    "Grades the composed image before overlays in limited-range BT.709 YUV. The domain selects the encoded input and output interpretation. Saturation is 0 through 3."
                )
                .font(.edithText(.caption)).foregroundStyle(.secondary)
            }
            value("Exposure", \.exposure)
            value("Brightness", \.brightness)
            value("Contrast", \.contrast)
            value("Saturation", \.saturation)
            VideoBackgroundInspector(
                background: effects.background,
                update: { background in update { $0.background = background } })
            Divider()
            Text("Transform keyframes").font(.edithText(.headline))
            Text(
                "Times use source seconds. Position is a fraction of the canvas; rotation uses degrees."
            )
            .font(.edithText(.caption)).foregroundStyle(.secondary)
            ForEach(Array(effects.keyframes.indices), id: \.self) { index in
                VStack(alignment: .leading, spacing: 6) {
                    keyframe("Time", index, \.time)
                    keyframe("Scale", index, \.scale)
                    keyframe("Position X", index, \.positionX)
                    keyframe("Position Y", index, \.positionY)
                    keyframe("Rotation", index, \.rotation)
                    Picker(
                        "Interpolation",
                        selection: Binding(
                            get: { effects.keyframes[index].interpolation },
                            set: { value in
                                update { $0.keyframes[index].interpolation = value }
                            })
                    ) {
                        Text("Linear").tag(VideoVisualEffects.Interpolation.linear)
                        Text("Smooth").tag(VideoVisualEffects.Interpolation.smooth)
                    }
                    Button("Remove keyframe") { update { $0.keyframes.remove(at: index) } }
                }
                Divider()
            }
            Button("Add keyframe") {
                update {
                    let time = $0.keyframes.last.map { $0.time + 1 } ?? clip.start
                    $0.keyframes.append(.init(time: time))
                }
            }
            Button("Gentle push in") {
                update {
                    $0.keyframes = [
                        .init(time: clip.start, interpolation: .smooth),
                        .init(time: clip.end, scale: 1.045),
                    ]
                }
            }
        }
    }

    private func update(_ change: (inout VideoVisualEffects) -> Void) {
        var next = effects
        change(&next)
        model.setVisualEffects(next, clipID: clip.id)
    }

    private func value(_ title: String, _ key: WritableKeyPath<VideoVisualEffects, Double>)
        -> some View
    {
        HStack {
            Text(title)
            TextField(
                title,
                value: Binding(
                    get: { effects[keyPath: key] },
                    set: { value in
                        update { $0[keyPath: key] = value }
                    }), format: .number
            ).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }

    private func keyframe(
        _ title: String, _ index: Int,
        _ key: WritableKeyPath<VideoVisualEffects.Keyframe, Double>
    ) -> some View {
        HStack {
            Text(title)
            TextField(
                title,
                value: Binding(
                    get: { effects.keyframes[index][keyPath: key] },
                    set: { value in
                        update {
                            $0.keyframes[index][keyPath: key] = value
                            $0.keyframes.sort { $0.time < $1.time }
                        }
                    }), format: .number
            ).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
        }
    }
}

extension VideoEditorModel {
    func setVideoSettings(_ settings: VideoSettings) {
        guard settings.isValid else {
            errorMessage = VideoSettings.ValidationError.invalidSettings.localizedDescription
            return
        }
        mutate { $0.videoSettings = settings }
        rebuild()
    }

    func setVisualEffects(_ effects: VideoVisualEffects, clipID: String) {
        guard effects.isValid else {
            errorMessage = VideoVisualEffects.VisualError.invalidEffects.localizedDescription
            return
        }
        mutate { try? $0.setVisualEffects(effects, clipID: clipID) }
        rebuild()
    }

    func setStillDuration(_ duration: Double, clipID: String) {
        guard duration.isFinite, duration > 0, duration < Double(Int64.max) / 600 else {
            errorMessage = VideoVisualEffects.VisualError.invalidDuration.localizedDescription
            return
        }
        mutate { try? $0.setStillDuration(duration, clipID: clipID) }
        rebuild()
    }
}
