import AppKit
import CoreImage
import SwiftUI

struct VideoInspector: View {
    enum Tab: String, CaseIterable {
        case clip = "Clip"
        case frame = "Frame"
        case camera = "Camera"
        case audio = "Audio"
        case overlays = "Overlays"
        case captions = "Captions"
    }

    let model: VideoEditorModel
    @State private var tab: Tab = .frame

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3), spacing: 6
            ) {
                ForEach(Tab.allCases, id: \.self) { option in
                    Button {
                        tab = option
                    } label: {
                        Text(option.rawValue).font(.caption).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(tab == option ? .accentColor : .secondary)
                    .accessibilityLabel("\(option.rawValue) inspector")
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch tab {
                    case .clip: clipControls
                    case .frame: frameControls
                    case .camera: cameraControls
                    case .audio: audioControls
                    case .overlays: overlayControls
                    case .captions: VideoCaptionEditor(model: model)
                    }
                }
                .padding(.trailing, 4)
            }
        }
        .font(.callout)
        .padding(14)
        .frame(width: 250)
        .onChange(of: model.selection) { _, selection in
            switch selection {
            case .clip, .speed: tab = .clip
            case .annotation: tab = .overlays
            case .audio: tab = .audio
            case .webcam, .camera: tab = .camera
            default: break
            }
        }
    }

    private var selectedClip: VideoProject.Clip? {
        model.project?.clips.first { $0.id == model.selectedClipID }
    }

    @ViewBuilder private var clipControls: some View {
        if let clip = selectedClip {
            Text("Selected clip").font(.headline)
            VideoVisualInspector(model: model, clip: clip)
            Divider()
            HStack {
                Button("Split", action: model.splitAtPlayhead)
                Button("Duplicate", action: model.duplicateSelected)
            }
            HStack {
                Button("Move earlier") { model.moveSelected(by: -1) }
                Button("Move later") { model.moveSelected(by: 1) }
            }
            number("Trim start", value: clip.start, range: 0...max(0, clip.end - 0.1)) {
                model.trimSelected(start: $0, end: clip.end)
            }
            let asset = model.project?.assets.first { $0.id == clip.assetID }
            number(
                "Trim end", value: clip.end,
                range: (clip.start + 0.1)...max(
                    clip.start + 0.1,
                    asset?.isStill == true ? clip.end : asset?.duration ?? clip.end)
            ) {
                model.trimSelected(start: clip.start, end: $0)
            }
            Button("Skip next second", action: model.skipAtPlayhead)
            ForEach(model.project?.trimRanges ?? [], id: \.regionID) { region in
                Button("Remove skip at \(seconds(region["startSec"]))s") {
                    model.removeTrim(region.regionID)
                }
            }
            Divider()
            Text("Speed region").font(.headline)
            Picker(
                "Speed",
                selection: Binding(get: { model.regionSpeed }, set: { model.regionSpeed = $0 })
            ) {
                ForEach([0.25, 0.5, 1, 1.5, 2, 3, 4, 5], id: \.self) {
                    Text("\($0.formatted())×").tag($0)
                }
            }
            Button("Add at playhead", action: model.addSpeedAtPlayhead)
            ForEach(model.project?.speedRegions ?? [], id: \.regionID) { region in
                Button("Remove \(seconds(region["speed"]))× region") {
                    model.removeSpeed(region.regionID)
                }
            }
            Divider()
            Text("Crop").font(.headline)
            let crop = clip.crop ?? ["x": 0, "y": 0, "width": 1, "height": 1]
            ForEach(["x", "y", "width", "height"], id: \.self) { axis in
                number(
                    axis.capitalized, value: crop[axis] ?? 0,
                    range: axis == "x" || axis == "y" ? 0...0.9 : 0.1...1, step: 0.01
                ) { value in
                    var next = crop
                    next[axis] = value
                    model.setCrop(
                        x: next["x"] ?? 0, y: next["y"] ?? 0,
                        width: next["width"] ?? 1, height: next["height"] ?? 1)
                }
            }
            Button("Reset crop", action: model.resetCrop)
            Button("Remove clip", role: .destructive, action: model.removeSelected)
            Divider()
            Text("Incoming transition").font(.headline)
            let transition = model.project?.transitions.first { $0.clipID == clip.id }
            Picker(
                "Transition",
                selection: Binding(
                    get: { transition?.kind ?? "none" },
                    set: {
                        model.setTransition(
                            before: clip.id, kind: $0, duration: transition?.duration ?? 0.5)
                    })
            ) {
                Text("Cut").tag("none")
                Text("Fade through black").tag("fade")
                Text("Flash").tag("flash")
            }
            if let transition {
                number("Transition length", value: transition.duration, range: 0.2...2) {
                    model.setTransition(before: clip.id, kind: transition.kind, duration: $0)
                }
            }
        } else {
            Text("Select a source clip to trim, crop, or change its speed.").foregroundStyle(
                .secondary)
        }
    }

    private var frameControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            VideoSettingsInspector(model: model)
            Divider()
            Text("Canvas & background").font(.headline)
            ColorPicker(
                "Color",
                selection: Binding(
                    get: { color(model.project?.backgroundColor ?? "#171B25") },
                    set: { model.setBackground(hex($0)) }), supportsOpacity: false)
            Toggle("Gradient", isOn: presentation(\.gradient, fallback: false))
            if model.project?.presentation.gradient == true {
                ColorPicker(
                    "End color",
                    selection: Binding(
                        get: { color(model.project?.presentation.gradientEnd ?? "#7654C4") },
                        set: { model.setPresentation(\.gradientEnd, hex($0)) }),
                    supportsOpacity: false)
            }
            HStack {
                Button("Ocean") { preset("#123B6D", "#27C5B8") }
                Button("Sunset") { preset("#C44569", "#F8B65A") }
                Button("Dusk") { preset("#23234D", "#9C76DB") }
            }
            Button("Choose background image…", action: model.chooseBackgroundImage)
            number(
                "Padding", value: model.project?.padding ?? 0, range: 0...25, step: 1,
                set: model.setPadding)
            presentationSlider("Corners", \.cornerRadius, range: 0...20)
            presentationSlider("Shadow", \.shadow, range: 0...100)
            presentationSlider("Background blur", \.backgroundBlur, range: 0...50)
        }
    }

    @ViewBuilder private var cameraControls: some View {
        Text("Webcam overlay").font(.headline)
        Button("Upload / replace video…", action: model.attachCameraToSelectedClip)
            .disabled(selectedClip == nil)
        if let clip = selectedClip,
            let camera = model.project?.assets.first(where: { $0.id == clip.assetID })?.cameraTrack
        {
            Toggle(
                "Show webcam",
                isOn: Binding(
                    get: { camera["visible"] as? Bool ?? true }, set: model.setCameraVisible))
            Toggle(
                "Mirror",
                isOn: Binding(
                    get: { model.project?.webcamMirrored ?? false }, set: model.setWebcamMirrored))
            Toggle("Shrink during zoom", isOn: presentation(\.cameraZoomReactive, fallback: false))
            Picker(
                "Shape",
                selection: Binding(
                    get: { model.project?.webcamMaskShape ?? "rectangle" },
                    set: model.setWebcamMaskShape)
            ) {
                ForEach(["rectangle", "rounded", "circle", "square"], id: \.self) {
                    Text($0.capitalized).tag($0)
                }
            }
            number(
                "Size", value: model.project?.webcamSize ?? 25, range: 10...50, step: 1,
                set: model.setWebcamSize)
            HStack {
                ForEach(["Top left", "Top right", "Bottom left", "Bottom right"], id: \.self) {
                    position in
                    Button {
                        model.setWebcamPosition("cx", value: position.hasSuffix("left") ? 0 : 1)
                        model.setWebcamPosition("cy", value: position.hasPrefix("Top") ? 0 : 1)
                    } label: {
                        Image(
                            systemName:
                                "\(position.hasPrefix("Top") ? "arrow.up" : "arrow.down").\(position.hasSuffix("left") ? "left" : "right")"
                        )
                    }.help(position).accessibilityLabel(position)
                }
            }
            ForEach([("cx", "Horizontal"), ("cy", "Vertical")], id: \.0) { axis, title in
                number(
                    title, value: model.project?.webcamPosition[axis] ?? 0.5, range: 0...1,
                    step: 0.01
                ) {
                    model.setWebcamPosition(axis, value: $0)
                }
            }
            presentationSlider("Margin", \.cameraMargin, range: 0...20)
            presentationSlider("Roundness", \.cameraRoundness, range: 0...50)
            presentationSlider("Shadow", \.cameraShadow, range: 0...100)
            Button("Fullscreen at playhead", action: model.addFullCamera)
            ForEach(model.project?.cameraFullscreenRegions ?? [], id: \.regionID) { region in
                Button("Remove fullscreen region") { model.removeFullCamera(region.regionID) }
            }
            Button("Remove webcam", role: .destructive, action: model.removeCameraFromSelectedClip)
        } else {
            Text(
                "Attach webcam footage to the selected clip. Recording session sidecars are imported automatically."
            )
            .foregroundStyle(.secondary)
        }
    }

    private var audioControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Audio tracks").font(.headline)
            if let status = model.audioStatus {
                ProgressView(status).font(.caption)
                Button("Cancel audio processing") { model.audioTask?.cancel() }
            }
            if let clip = audioSourceClip {
                Toggle(
                    "Mute source",
                    isOn: Binding(
                        get: { clip.raw["audioMuted"] as? Bool ?? false },
                        set: { model.setClipAudio(muted: $0) }))
                number(
                    "Source gain (dB)",
                    value: (clip.raw["audioGainDb"] as? NSNumber)?.doubleValue ?? 0,
                    range: -40...12, step: 1
                ) {
                    model.setClipAudio(gain: $0)
                }
                audioCleanup(clip.assetID)
                Button("Detach source audio") { model.detachAudio(clipID: clip.id) }
                    .disabled(model.audioTask != nil || clip.raw["audioDetached"] as? Bool == true)
                Button("Detect silence", action: model.detectSilence).disabled(
                    model.audioTask != nil)
                if model.silenceClipID == clip.id {
                    Text("\(model.silentRanges.count) quiet sections").font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Remove detected silence", action: model.removeSilence).disabled(
                        model.silentRanges.isEmpty)
                }
                Divider()
            }
            Button("Add audio…", action: model.importMedia)
            number("Preview volume", value: Double(model.player.volume), range: 0...1, step: 0.05) {
                model.player.volume = Float($0)
            }
            ForEach(audioInspectorTracks) { track in
                VStack(alignment: .leading, spacing: 10) {
                    Text(track.label)
                        .lineLimit(1)
                    Text("Output time · \(track.rate.formatted())× source rate")
                        .font(.caption).foregroundStyle(.secondary)
                    number(
                        "Start (s)", value: track.startMs / 1000, range: 0...max(1, model.duration),
                        step: 0.1
                    ) {
                        model.moveAudio(track.id, to: $0)
                    }
                    number(
                        "Trim in (s)", value: track.startMs / 1000,
                        range: 0...max(1, track.endMs / 1000), step: 0.1
                    ) {
                        model.trimAudio(track.id, start: $0, end: track.endMs / 1000)
                    }
                    number(
                        "Trim out (s)", value: track.endMs / 1000,
                        range: 0...max(1, model.duration), step: 0.1
                    ) {
                        model.trimAudio(track.id, start: track.startMs / 1000, end: $0)
                    }
                    Button("Split at playhead") { model.splitAudio(track.id, at: model.playhead) }
                        .disabled(
                            model.playhead <= track.startMs / 1000 + 0.05
                                || model.playhead >= track.endMs / 1000 - 0.05)
                    audioCleanup(track.assetID)
                    Toggle(
                        "Muted",
                        isOn: Binding(
                            get: { track.muted }, set: { model.setAudioMuted(track.id, muted: $0) })
                    )
                    Toggle(
                        "Loop",
                        isOn: Binding(
                            get: { track.loop }, set: { model.setAudioLoop(track.id, loop: $0) }))
                    number("Gain (dB)", value: track.gainDb, range: -40...12, step: 1) {
                        model.setAudioGain(track.id, decibels: $0)
                    }
                    ForEach([true, false], id: \.self) { fadeIn in
                        number(
                            fadeIn ? "Fade in (ms)" : "Fade out (ms)",
                            value: (track.raw[fadeIn ? "fadeInMs" : "fadeOutMs"] as? NSNumber)?
                                .doubleValue ?? 0,
                            range: 0...3000, step: 100
                        ) { model.setAudioFade(track.id, milliseconds: Int($0), fadeIn: fadeIn) }
                    }
                    Button("Remove audio", role: .destructive) { model.removeAudio(track.id) }
                }
                Divider()
            }
        }
    }

    private var audioInspectorTracks: [VideoProject.AudioTrack] {
        let tracks = model.project?.audioTracks ?? []
        guard case .audio(let selected) = model.selection else { return tracks }
        return tracks.sorted { $0.id == selected && $1.id != selected }
    }

    private var audioSourceClip: VideoProject.Clip? {
        if case .audio = model.selection { return nil }
        return selectedClip
    }

    private var overlayControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Annotations & cursor").font(.headline)
            Toggle("Render cursor", isOn: presentation(\.cursorVisible, fallback: false))
            Toggle("Smooth cursor", isOn: presentation(\.cursorSmoothing, fallback: false))
            number(
                "Cursor size", value: model.project?.presentation.cursorSize ?? 1, range: 0.5...4
            ) {
                model.setPresentation(\.cursorSize, $0)
            }
            Text(
                "For a replaceable cursor, record with Include cursor off. Imported videos may already contain a cursor."
            )
            .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Image") { model.addOverlay("image") }
                Button("Arrow") { model.addOverlay("figure") }
                Button("Blur") { model.addOverlay("blur") }
            }
            Button(
                model.isTranscribing ? "Transcribing…" : "Generate captions",
                action: model.generateCaptions
            )
            .disabled(model.isTranscribing || selectedClip == nil)
            Toggle(
                "Highlight cursor clicks",
                isOn: Binding(
                    get: { model.project?.cursorHighlight ?? false }, set: model.setCursorHighlight)
            )
            Button("Suggest zooms from clicks", action: model.addAutomaticZooms)
            Text("Click effects and suggested zooms use the recording's cursor sidecar.").font(
                .caption
            ).foregroundStyle(.secondary)
            ForEach(model.project?.annotations ?? []) { annotation in
                EditorAnnotationRow(annotation: annotation, model: model)
                Divider()
            }
        }
    }

    private func audioCleanup(_ assetID: String) -> some View {
        VStack(alignment: .leading) {
            Button("Normalize loudness") { model.processAudio(assetID: assetID, denoise: false) }
            Button("Reduce noise + normalize") {
                model.processAudio(assetID: assetID, denoise: true)
            }
        }.disabled(model.audioTask != nil)
    }

    private func presentation<Value>(
        _ key: WritableKeyPath<VideoPresentation, Value>, fallback: Value
    ) -> Binding<Value> {
        Binding(
            get: { model.project?.presentation[keyPath: key] ?? fallback },
            set: { model.setPresentation(key, $0) })
    }

    private func presentationSlider(
        _ title: String, _ key: WritableKeyPath<VideoPresentation, Double>,
        range: ClosedRange<Double>
    ) -> some View {
        number(title, value: model.project?.presentation[keyPath: key] ?? 0, range: range, step: 1)
        {
            model.setPresentation(key, $0)
        }
    }

    private func number(
        _ title: String, value: Double, range: ClosedRange<Double>, step: Double = 0.1,
        set: @escaping (Double) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { min(range.upperBound, max(range.lowerBound, value)) }, set: set),
                in: range, step: step
            )
            .accessibilityLabel(title)
        }
    }

    private func preset(_ start: String, _ end: String) {
        model.setBackground(start)
        model.setPresentation(\.gradientEnd, end)
        model.setPresentation(\.gradient, true)
    }

    private func color(_ value: String) -> Color {
        let ci = CIColor(hex: value)
        return Color(red: ci.red, green: ci.green, blue: ci.blue)
    }

    private func hex(_ value: Color) -> String {
        let rgb = NSColor(value).usingColorSpace(.deviceRGB) ?? .black
        return String(
            format: "#%02X%02X%02X", Int(rgb.redComponent * 255), Int(rgb.greenComponent * 255),
            Int(rgb.blueComponent * 255))
    }

    private func seconds(_ raw: Any?) -> String {
        ((raw as? NSNumber)?.doubleValue ?? 0).formatted(.number.precision(.fractionLength(0...2)))
    }
}

private extension Dictionary where Key == String, Value == Any {
    var regionID: String { self["id"] as? String ?? "" }
}
