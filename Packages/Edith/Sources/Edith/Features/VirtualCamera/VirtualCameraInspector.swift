import AppKit
import EdithCameraSupport
import EdithKit
import SwiftUI

struct VirtualCameraInspector: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    @State private var choosingTab = false

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            Button { choosingTab = true } label: {
                HStack {
                    Label(model.tab.title, systemImage: model.tab.symbolName)
                        .font(.edithText(.headline))
                    Spacer()
                    Image(systemName: "chevron.down")
                }
                .padding(UIScale.pt(12))
                .frame(maxWidth: .infinity, minHeight: UIScale.pt(44), alignment: .leading)
            }
            .buttonStyle(.edith(.secondary))
            .accessibilityLabel("Adjust: \(model.tab.title)")
            .popover(isPresented: $choosingTab) {
                VStack(spacing: UIScale.pt(4)) {
                    ForEach(VirtualCameraInspectorTab.allCases) { tab in
                        Button {
                            model.tab = tab
                            choosingTab = false
                        } label: {
                            Label(tab.title, systemImage: tab.symbolName)
                                .font(.edithText(.body))
                                .frame(maxWidth: .infinity, minHeight: UIScale.pt(28), alignment: .leading)
                        }
                        .buttonStyle(.edith(.toolbar))
                    }
                }
                .padding(UIScale.pt(12))
                .frame(width: UIScale.pt(220))
            }
            ScrollView {
                VStack(spacing: UIScale.pt(12)) {
                    switch model.tab {
                    case .frame:
                        VirtualCameraFramePanel(model: model, dark: dark)
                        VirtualCameraSceneStrip(model: model, dark: dark)
                    case .look: VirtualCameraLookPanel(model: model, dark: dark)
                    case .background: VirtualCameraBackgroundPanel(model: model, dark: dark)
                    case .overlays: VirtualCameraOverlayPanel(model: model, dark: dark)
                    case .output: VirtualCameraOutputPanel(model: model, dark: dark)
                    case .audio: VirtualCameraAudioPanel(model: model, dark: dark)
                    }
                }
                .padding(UIScale.pt(2))
            }

        }
    }
}

struct VirtualCameraPanelSection<Content: View>: View {
    let title: String
    var detail: String?
    let dark: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(10)) {
            VStack(alignment: .leading, spacing: UIScale.pt(2)) {
                Text(title)
                    .font(.system(size: UIScale.pt(13), weight: .semibold))
                    .foregroundStyle(DashSkin.ink(dark))
                if let detail {
                    Text(detail)
                        .font(.system(size: UIScale.pt(11)))
                        .foregroundStyle(DashSkin.inkFaint(dark))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            content()
        }
        .padding(UIScale.pt(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .edithSurface(cornerRadius: 12)
    }
}

struct VirtualCameraToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let dark: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer(minLength: UIScale.pt(8))
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }
}

struct VirtualCameraSliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var neutral: Double? = nil
    var format: (Double) -> String = { String(format: "%.2f", $0) }
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(2)) {
            HStack {
                Text(title)
                    .font(.system(size: UIScale.pt(12)))
                    .foregroundStyle(DashSkin.inkSoft(dark))
                Spacer()
                if let neutral, abs(value - neutral) > 0.0001 {
                    Button {
                        value = neutral
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: UIScale.pt(10)))
                    }
                    .buttonStyle(.edith(.iconOnly))
                    .help("Reset \(title.lowercased())")
                    .accessibilityLabel("Reset \(title.lowercased())")
                }
                Text(format(value))
                    .font(DashSkin.mono(11))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .accessibilityLabel(title)
        }
    }
}

extension VirtualCameraPageModel {
    func binding<Value>(_ keyPath: WritableKeyPath<VirtualCameraComposition, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { self.composition[keyPath: keyPath] },
            set: { value in self.updateComposition { $0[keyPath: keyPath] = value } })
    }

    func stateBinding<Value>(_ keyPath: WritableKeyPath<VirtualCameraState, Value>) -> Binding<
        Value
    > {
        Binding(
            get: { self.state[keyPath: keyPath] },
            set: { value in self.update { $0[keyPath: keyPath] = value } })
    }

    func colorBinding(_ keyPath: WritableKeyPath<VirtualCameraComposition, VirtualCameraColor>)
        -> Binding<Color>
    {
        Binding(
            get: {
                let color = self.composition[keyPath: keyPath]
                return Color(
                    .sRGB, red: color.red, green: color.green, blue: color.blue,
                    opacity: color.alpha)
            },
            set: { value in
                guard let converted = NSColor(value).usingColorSpace(.sRGB) else { return }
                let color = VirtualCameraColor(
                    red: converted.redComponent, green: converted.greenComponent,
                    blue: converted.blueComponent, alpha: converted.alphaComponent)
                self.updateComposition { $0[keyPath: keyPath] = color }
            })
    }
}

private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
private func signed(_ value: Double) -> String {
    value == 0 ? "0" : String(format: "%+.2f", value)
}

struct VirtualCameraFramePanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            VirtualCameraPanelSection(
                title: "Framing", detail: "Drag the preview to move, scroll or pinch to zoom.",
                dark: dark
            ) {
                VirtualCameraSliderRow(
                    title: "Zoom",
                    value: Binding(
                        get: { model.composition.framing.zoom }, set: { model.setZoom($0) }),
                    range: VirtualCameraFraming.zoomRange, neutral: 1,
                    format: { String(format: "%.2fx", $0) }, dark: dark)
                VirtualCameraSliderRow(
                    title: "Left to right", value: model.binding(\.framing.centerX), range: 0...1,
                    neutral: 0.5, format: percent, dark: dark)
                VirtualCameraSliderRow(
                    title: "Top to bottom", value: model.binding(\.framing.centerY), range: 0...1,
                    neutral: 0.5, format: percent, dark: dark)
                VirtualCameraSliderRow(
                    title: "Tilt", value: model.binding(\.framing.tilt),
                    range: VirtualCameraFraming.tiltRange, neutral: 0,
                    format: { String(format: "%.1f°", $0) }, dark: dark)
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Text("Rotate")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    EdithSegmentedPicker(
                        "Rotate", selection: model.binding(\.framing.quarterTurns),
                        options: [0, 1, 2, 3], label: { "\($0 * 90)°" }
                    )
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                }
                VirtualCameraToggleRow(
                    title: "Flip horizontally", isOn: model.binding(\.framing.flipHorizontal),
                    dark: dark)
                VirtualCameraToggleRow(
                    title: "Flip vertically", isOn: model.binding(\.framing.flipVertical),
                    dark: dark)
            }
            VirtualCameraPanelSection(
                title: "Auto framing",
                detail: "Follows faces and keeps everyone in the shot, like Center Stage.",
                dark: dark
            ) {
                EdithSegmentedPicker(
                    "Auto framing", selection: model.binding(\.framing.autoFrame),
                    options: VirtualCameraAutoFrame.allCases, label: { $0.title }
                )
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
            VirtualCameraPanelSection(
                title: "Sharp zoom",
                detail:
                    "Switch the camera to a higher resolution while zoomed in, when it has one.",
                dark: dark
            ) {
                VirtualCameraToggleRow(
                    title: "Use the camera's best resolution",
                    isOn: model.stateBinding(\.sharpZoom), dark: dark)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct VirtualCameraLookPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            VirtualCameraPanelSection(title: "Looks", dark: dark) {
                LazyVGrid(columns: columns, spacing: UIScale.pt(8)) {
                    ForEach(VirtualCameraLookPreset.allCases, id: \.self) { preset in
                        VirtualCameraLookTile(
                            preset: preset, thumbnail: model.lookThumbnails[preset],
                            selected: model.composition.look.preset == preset, dark: dark
                        ) {
                            model.updateComposition { $0.look.preset = preset }
                        }
                    }
                }
                if model.composition.look.preset != .natural {
                    VirtualCameraSliderRow(
                        title: "Strength", value: model.binding(\.look.intensity), range: 0...1,
                        neutral: 1, format: percent, dark: dark)
                }
            }
            VirtualCameraPanelSection(title: "Light and color", dark: dark) {
                VirtualCameraSliderRow(
                    title: "Exposure", value: model.binding(\.look.exposure),
                    range: VirtualCameraLook.exposureRange, neutral: 0,
                    format: { String(format: "%+.1f EV", $0) }, dark: dark)
                VirtualCameraSliderRow(
                    title: "Brightness", value: model.binding(\.look.brightness),
                    range: VirtualCameraLook.brightnessRange, neutral: 0, format: signed, dark: dark
                )
                VirtualCameraSliderRow(
                    title: "Contrast", value: model.binding(\.look.contrast),
                    range: VirtualCameraLook.contrastRange, neutral: 1, format: percent, dark: dark)
                VirtualCameraSliderRow(
                    title: "Saturation", value: model.binding(\.look.saturation),
                    range: VirtualCameraLook.saturationRange, neutral: 1, format: percent,
                    dark: dark)
                VirtualCameraSliderRow(
                    title: "Warmth", value: model.binding(\.look.warmth),
                    range: VirtualCameraLook.signedRange, neutral: 0, format: signed, dark: dark)
                VirtualCameraSliderRow(
                    title: "Tint", value: model.binding(\.look.tint),
                    range: VirtualCameraLook.signedRange, neutral: 0, format: signed, dark: dark)
            }
            VirtualCameraPanelSection(title: "Detail", dark: dark) {
                VirtualCameraSliderRow(
                    title: "Sharpen", value: model.binding(\.look.sharpness),
                    range: VirtualCameraLook.unitRange, neutral: 0, format: percent, dark: dark)
                VirtualCameraSliderRow(
                    title: "Soften", value: model.binding(\.look.smoothing),
                    range: VirtualCameraLook.unitRange, neutral: 0, format: percent, dark: dark)
                VirtualCameraSliderRow(
                    title: "Vignette", value: model.binding(\.look.vignette),
                    range: VirtualCameraLook.unitRange, neutral: 0, format: percent, dark: dark)
                Button("Reset the look") {
                    model.updateComposition { $0.look = VirtualCameraLook() }
                }
                .buttonStyle(.edith(.borderless))
                .disabled(model.composition.look.isNeutral && model.composition.look.intensity == 1)
            }
        }
    }
}

struct VirtualCameraLookTile: View {
    let preset: VirtualCameraLookPreset
    let thumbnail: CGImage?
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: UIScale.pt(4)) {
                ZStack {
                    RoundedRectangle(cornerRadius: UIScale.pt(6)).fill(Color.black)
                    if let thumbnail {
                        Image(decorative: thumbnail, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
                .overlay(
                    RoundedRectangle(cornerRadius: UIScale.pt(6))
                        .stroke(
                            selected ? DashSkin.accent(dark) : DashSkin.line(dark),
                            lineWidth: selected ? 2 : 1))
                Text(preset.title)
                    .font(.system(size: UIScale.pt(11), weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
            }
        }
        .buttonStyle(.edith(.borderless))
        .accessibilityLabel(preset.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct VirtualCameraBackgroundPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    private var cameraGuidance: String {
        if model.systemBackgroundActive {
            return
                "macOS Background is active and passes through to your video app. Turn it off in the macOS Video Effects menu to use Edith's backgrounds."
        }
        if let route = model.snapshot?.route {
            return "Select \(route.cameraName) in your video app to see this background."
        }
        return
            "Set up a virtual camera in Output, then select it in your video app to see this background."
    }

    var body: some View {
        VirtualCameraPanelSection(
            title: "Background",
            detail: "Edith finds you in the picture and blurs or replaces everything behind you.",
            dark: dark
        ) {
            Text(cameraGuidance)
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .fixedSize(horizontal: false, vertical: true)
            EdithSegmentedPicker(
                "Background", selection: model.binding(\.background.mode),
                options: VirtualCameraBackgroundMode.allCases, label: { $0.title }
            )
            .labelsHidden()
            .disabled(model.systemBackgroundActive)
            switch model.systemBackgroundActive ? .none : model.composition.background.mode {
            case .none:
                Text("Apps see your camera picture, including any macOS video effects.")
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
            case .blur:
                VirtualCameraSliderRow(
                    title: "Blur", value: model.binding(\.background.blur), range: 0...1,
                    neutral: 0.6, format: percent, dark: dark)
            case .color:
                ColorPicker(
                    "Backdrop color", selection: model.colorBinding(\.background.color),
                    supportsOpacity: false)
            case .image:
                VirtualCameraImageRow(
                    title: "Backdrop image", path: model.composition.background.imagePath,
                    dark: dark, choose: { model.chooseImage(for: .background) },
                    remove: { model.removeImage(for: .background) })
            }
        }
    }
}

struct VirtualCameraImageRow: View {
    let title: String
    let path: String?
    let dark: Bool
    let choose: () -> Void
    let remove: () -> Void

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            Group {
                if let path {
                    StudioThumbnail(url: URL(fileURLWithPath: path), side: 56, corner: 6)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .frame(width: UIScale.pt(56), height: UIScale.pt(36))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
            .presenterCover(.camera)
            .background(RoundedRectangle(cornerRadius: UIScale.pt(6)).fill(DashSkin.paper2(dark)))
            Text(path == nil ? "No image" : title)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button(path == nil ? "Choose…" : "Replace…", action: choose)
                .buttonStyle(.edith(.secondary))
            if path != nil {
                Button(action: remove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.edith(.iconOnly))
                .help("Remove the image")
                .accessibilityLabel("Remove the image")
            }
        }
    }
}

struct VirtualCameraCornerPicker: View {
    let title: String
    @Binding var selection: VirtualCameraCorner

    var body: some View {
        Picker(title, selection: $selection) {
            ForEach(VirtualCameraCorner.allCases, id: \.self) { corner in
                Text(corner.title).tag(corner)
            }
        }
    }
}

struct VirtualCameraOverlayPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            VirtualCameraPanelSection(title: "Name tag", dark: dark) {
                VirtualCameraToggleRow(
                    title: "Show a name tag", isOn: model.binding(\.overlays.nameTag.enabled),
                    dark: dark)
                if model.composition.overlays.nameTag.enabled {
                    TextField("Name", text: model.binding(\.overlays.nameTag.title))
                        .textFieldStyle(.roundedBorder)
                    TextField("Title or pronouns", text: model.binding(\.overlays.nameTag.subtitle))
                        .textFieldStyle(.roundedBorder)
                    EdithSegmentedPicker(
                        "Style", selection: model.binding(\.overlays.nameTag.style),
                        options: VirtualCameraNameTagStyle.allCases, label: { $0.title })
                    VirtualCameraCornerPicker(
                        title: "Corner", selection: model.binding(\.overlays.nameTag.corner))
                    ColorPicker(
                        "Accent", selection: model.colorBinding(\.overlays.nameTag.accent),
                        supportsOpacity: false)
                }
            }
            VirtualCameraPanelSection(title: "Logo", dark: dark) {
                VirtualCameraImageRow(
                    title: "Logo", path: model.composition.overlays.logo.imagePath, dark: dark,
                    choose: { model.chooseImage(for: .logo) },
                    remove: { model.removeImage(for: .logo) })
                if model.composition.overlays.logo.imagePath != nil {
                    VirtualCameraToggleRow(
                        title: "Show the logo", isOn: model.binding(\.overlays.logo.enabled),
                        dark: dark)
                    VirtualCameraCornerPicker(
                        title: "Corner", selection: model.binding(\.overlays.logo.corner))
                    VirtualCameraSliderRow(
                        title: "Size", value: model.binding(\.overlays.logo.size),
                        range: VirtualCameraLogo.sizeRange, format: percent, dark: dark)
                    VirtualCameraSliderRow(
                        title: "Opacity", value: model.binding(\.overlays.logo.opacity),
                        range: 0...1, format: percent, dark: dark)
                }
            }
            VirtualCameraPanelSection(title: "Clock", dark: dark) {
                VirtualCameraToggleRow(
                    title: "Show the time", isOn: model.binding(\.overlays.clock.enabled),
                    dark: dark)
                if model.composition.overlays.clock.enabled {
                    VirtualCameraCornerPicker(
                        title: "Corner", selection: model.binding(\.overlays.clock.corner))
                    VirtualCameraToggleRow(
                        title: "24-hour clock",
                        isOn: model.binding(\.overlays.clock.twentyFourHour), dark: dark)
                    VirtualCameraToggleRow(
                        title: "Seconds", isOn: model.binding(\.overlays.clock.showsSeconds),
                        dark: dark)
                }
            }
            VirtualCameraPanelSection(
                title: "Frame", detail: "Round the corners and set the picture inside a matte.",
                dark: dark
            ) {
                VirtualCameraToggleRow(
                    title: "Frame the picture", isOn: model.binding(\.overlays.border.enabled),
                    dark: dark)
                if model.composition.overlays.border.enabled {
                    VirtualCameraSliderRow(
                        title: "Margin", value: model.binding(\.overlays.border.inset),
                        range: VirtualCameraBorder.insetRange, format: percent, dark: dark)
                    VirtualCameraSliderRow(
                        title: "Corner radius",
                        value: model.binding(\.overlays.border.cornerRadius),
                        range: VirtualCameraBorder.cornerRange, format: percent, dark: dark)
                    VirtualCameraSliderRow(
                        title: "Border", value: model.binding(\.overlays.border.width),
                        range: VirtualCameraBorder.widthRange, format: percent, dark: dark)
                    ColorPicker(
                        "Border color", selection: model.colorBinding(\.overlays.border.color),
                        supportsOpacity: false)
                    ColorPicker(
                        "Matte color", selection: model.colorBinding(\.overlays.border.matte),
                        supportsOpacity: false)
                }
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct VirtualCameraOutputPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    @ObservedObject var extensionManager: VirtualCameraExtensionManager
    let dark: Bool

    init(model: VirtualCameraPageModel, dark: Bool) {
        self.model = model
        self.extensionManager = model.extensionManager
        self.dark = dark
    }

    private var cameraSize: String? {
        if model.previewStatistics.sourceWidth > 0 {
            return "\(model.previewStatistics.sourceWidth)x\(model.previewStatistics.sourceHeight)"
        }
        if let snapshot = model.snapshot, snapshot.sourceWidth > 0 {
            return "\(snapshot.sourceWidth)x\(snapshot.sourceHeight)"
        }
        return nil
    }

    private var routeTitle: String {
        guard let route = model.snapshot?.route else { return "Sends to: nothing yet" }
        return "Sends to: \(route.cameraName)"
    }

    private var routeDetail: String {
        switch model.snapshot?.route {
        case .obs:
            "Pick OBS Virtual Camera in Zoom, Meet, FaceTime or any other app. Edith starts when an app opens it and stops when that app quits. Keep the OBS app closed while you use it."
        case .edithCamera:
            "Pick Edith Camera in any video app. Edith turns your camera on only while an app shows it."
        case nil:
            model.snapshot?.obsAvailable == true
                ? "Edith Camera is not installed. Choose Automatic or OBS Virtual Camera to send through OBS instead."
                : "Install Edith Camera below, or install OBS Studio and Edith can send through its virtual camera."
        }
    }

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
            VirtualCameraPanelSection(title: routeTitle, detail: routeDetail, dark: dark) {
                EdithSegmentedPicker(
                    "Output", selection: model.stateBinding(\.output),
                    options: VirtualCameraOutput.allCases, label: { $0.title }
                )
                .labelsHidden()
            }
            VirtualCameraPanelSection(
                title: "Edith Camera: \(extensionManager.phase.title)",
                detail: extensionManager.phase.detail, dark: dark
            ) {
                HStack {
                    switch extensionManager.phase {
                    case .notInstalled, .failed:
                        Button("Install Edith Camera") { extensionManager.install() }
                            .buttonStyle(.edith(.primary))
                    case .awaitingApproval:
                        Button("Open System Settings") { extensionManager.openSystemSettings() }
                            .buttonStyle(.edith(.primary))
                    case .installed:
                        Button("Remove", role: .destructive) { extensionManager.uninstall() }
                            .buttonStyle(.edith(.secondary))
                    default:
                        EmptyView()
                    }
                    Spacer()
                    Button("Check again") { extensionManager.refreshDetached() }
                        .buttonStyle(.edith(.borderless))
                }
            }
            VirtualCameraPanelSection(title: "In use by", dark: dark) {
                let clients = model.snapshot?.clients ?? []
                if clients.isEmpty {
                    Text(
                        "No app is using Edith Camera. Edith keeps your camera off until one does."
                    )
                    .font(.system(size: UIScale.pt(11)))
                    .foregroundStyle(DashSkin.inkFaint(dark))
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(clients, id: \.id) { client in
                        Label(client.name, systemImage: "video.fill")
                            .font(.system(size: UIScale.pt(12)))
                    }
                }
                VirtualCameraFact(
                    title: "Sends", value: (model.snapshot?.format ?? .standard).label, dark: dark)
                if let snapshot = model.snapshot, snapshot.live {
                    VirtualCameraFact(
                        title: "Frame rate",
                        value: String(format: "%.0f fps", snapshot.framesPerSecond),
                        dark: dark)
                }
                if let cameraSize = cameraSize {
                    VirtualCameraFact(title: "Camera", value: cameraSize, dark: dark)
                }
            }
            VirtualCameraPanelSection(
                title: "Pause",
                detail:
                    "Stop completely shuts down capture, preview and output until you choose Go live.",
                dark: dark
            ) {
                Button("Stop completely") { model.pause(.stopped) }
                    .buttonStyle(.edith(.secondary))
                    .disabled(model.state.privacy == .stopped)
                TextField("Card message", text: model.stateBinding(\.privacyMessage))
                    .textFieldStyle(.roundedBorder)
                HStack {
                    ForEach([VirtualCameraPrivacy.card, .blank, .freeze], id: \.self) { mode in
                        Button(mode.title) { model.pause(mode) }
                            .buttonStyle(.edith(.secondary))
                            .disabled(model.state.privacy == mode)
                    }
                }
                if model.state.privacy != .live {
                    Button("Go live") { model.resume() }
                        .buttonStyle(.edith(.primary))
                }
            }
            VirtualCameraPanelSection(title: "Preferences", dark: dark) {
                EdithSegmentedPicker(
                    "Scene changes", selection: model.stateBinding(\.transition),
                    options: VirtualCameraTransition.allCases, label: { $0.title })
                VirtualCameraToggleRow(
                    title: "Mirror self preview", isOn: model.stateBinding(\.mirrorPreview),
                    dark: dark)
                VirtualCameraToggleRow(
                    title: "Flip participant output", isOn: model.stateBinding(\.mirrorOutput),
                    dark: dark)
                Text(
                    "Meet mirrors its self preview. Use the audience preview here to check text and overlays."
                )
                .font(.system(size: UIScale.pt(11)))
                .foregroundStyle(DashSkin.inkFaint(dark))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}

struct VirtualCameraFact: View {
    let title: String
    let value: String
    let dark: Bool

    var body: some View {
        HStack {
            Text(title)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
            Spacer()
            Text(value)
                .font(DashSkin.mono(11))
                .foregroundStyle(DashSkin.inkFaint(dark))
        }
    }
}
