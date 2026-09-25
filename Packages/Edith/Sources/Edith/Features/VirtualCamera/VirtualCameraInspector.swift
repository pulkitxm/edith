import AppKit
import EdithCameraSupport
import EdithKit
import SwiftUI

struct VirtualCameraInspector: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            HStack(spacing: UIScale.pt(4)) {
                ForEach(VirtualCameraInspectorTab.allCases) { tab in
                    Button {
                        model.tab = tab
                    } label: {
                        VStack(spacing: UIScale.pt(3)) {
                            Image(systemName: tab.symbolName)
                                .font(.system(size: UIScale.pt(13)))
                            Text(tab.title)
                                .font(.system(size: UIScale.pt(10), weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(
                            model.tab == tab ? DashSkin.accent(dark) : DashSkin.inkSoft(dark))
                    }
                    .buttonStyle(.edith(.toolbar))
                    .accessibilityAddTraits(model.tab == tab ? .isSelected : [])
                }
            }
            .padding(UIScale.pt(4))
            .background(
                RoundedRectangle(cornerRadius: UIScale.pt(10)).fill(DashSkin.paper2(dark)))
            Group {
                switch model.tab {
                case .frame: VirtualCameraFramePanel(model: model, dark: dark)
                case .look: VirtualCameraLookPanel(model: model, dark: dark)
                case .background: VirtualCameraBackgroundPanel(model: model, dark: dark)
                case .overlays: VirtualCameraOverlayPanel(model: model, dark: dark)
                case .output: VirtualCameraOutputPanel(model: model, dark: dark)
                }
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
                HStack {
                    Text("Rotate")
                        .font(.system(size: UIScale.pt(12)))
                        .foregroundStyle(DashSkin.inkSoft(dark))
                    Spacer()
                    Picker("Rotate", selection: model.binding(\.framing.quarterTurns)) {
                        Text("0°").tag(0)
                        Text("90°").tag(1)
                        Text("180°").tag(2)
                        Text("270°").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: UIScale.pt(180))
                }
                Toggle("Flip horizontally", isOn: model.binding(\.framing.flipHorizontal))
                Toggle("Flip vertically", isOn: model.binding(\.framing.flipVertical))
            }
            VirtualCameraPanelSection(
                title: "Auto framing",
                detail: "Follows faces and keeps everyone in the shot, like Center Stage.",
                dark: dark
            ) {
                Picker("Auto framing", selection: model.binding(\.framing.autoFrame)) {
                    ForEach(VirtualCameraAutoFrame.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            VirtualCameraPanelSection(
                title: "Sharp zoom",
                detail:
                    "Switch the camera to a higher resolution while zoomed in, when it has one.",
                dark: dark
            ) {
                Toggle("Use the camera's best resolution", isOn: model.stateBinding(\.sharpZoom))
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
                LazyVGrid(columns: columns, spacing: UIScale.pt(6)) {
                    ForEach(VirtualCameraLookPreset.allCases, id: \.self) { preset in
                        let selected = model.composition.look.preset == preset
                        Button(preset.title) {
                            model.updateComposition { $0.look.preset = preset }
                        }
                        .buttonStyle(.edith(.selection))
                        .overlay(
                            RoundedRectangle(cornerRadius: UIScale.pt(8))
                                .stroke(
                                    selected ? DashSkin.accent(dark) : Color.clear, lineWidth: 1.5)
                        )
                        .accessibilityAddTraits(selected ? .isSelected : [])
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

struct VirtualCameraBackgroundPanel: View {
    @ObservedObject var model: VirtualCameraPageModel
    let dark: Bool

    var body: some View {
        VirtualCameraPanelSection(
            title: "Background",
            detail: "Edith finds you in the picture and blurs or replaces everything behind you.",
            dark: dark
        ) {
            Picker("Background", selection: model.binding(\.background.mode)) {
                ForEach(VirtualCameraBackgroundMode.allCases, id: \.self) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch model.composition.background.mode {
            case .none:
                Text("Apps see your real background.")
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
                if let path, let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "photo")
                        .foregroundStyle(DashSkin.inkFaint(dark))
                }
            }
            .frame(width: UIScale.pt(56), height: UIScale.pt(36))
            .clipShape(RoundedRectangle(cornerRadius: UIScale.pt(6)))
            .background(RoundedRectangle(cornerRadius: UIScale.pt(6)).fill(DashSkin.paper2(dark)))
            Text(path == nil ? "No image" : title)
                .font(.system(size: UIScale.pt(12)))
                .foregroundStyle(DashSkin.inkSoft(dark))
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
                Toggle("Show a name tag", isOn: model.binding(\.overlays.nameTag.enabled))
                if model.composition.overlays.nameTag.enabled {
                    TextField("Name", text: model.binding(\.overlays.nameTag.title))
                        .textFieldStyle(.roundedBorder)
                    TextField("Title or pronouns", text: model.binding(\.overlays.nameTag.subtitle))
                        .textFieldStyle(.roundedBorder)
                    Picker("Style", selection: model.binding(\.overlays.nameTag.style)) {
                        ForEach(VirtualCameraNameTagStyle.allCases, id: \.self) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
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
                    Toggle("Show the logo", isOn: model.binding(\.overlays.logo.enabled))
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
                Toggle("Show the time", isOn: model.binding(\.overlays.clock.enabled))
                if model.composition.overlays.clock.enabled {
                    VirtualCameraCornerPicker(
                        title: "Corner", selection: model.binding(\.overlays.clock.corner))
                    Toggle("24-hour clock", isOn: model.binding(\.overlays.clock.twentyFourHour))
                    Toggle("Seconds", isOn: model.binding(\.overlays.clock.showsSeconds))
                }
            }
            VirtualCameraPanelSection(
                title: "Frame", detail: "Round the corners and set the picture inside a matte.",
                dark: dark
            ) {
                Toggle("Frame the picture", isOn: model.binding(\.overlays.border.enabled))
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

    var body: some View {
        VStack(spacing: UIScale.pt(12)) {
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
                    Button("Check again") { extensionManager.refresh() }
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
                if model.previewStatistics.sourceWidth > 0 {
                    VirtualCameraFact(
                        title: "Camera",
                        value:
                            "\(model.previewStatistics.sourceWidth)x\(model.previewStatistics.sourceHeight)",
                        dark: dark)
                }
            }
            VirtualCameraPanelSection(
                title: "Pause",
                detail: "Pausing turns your camera off while apps keep showing a picture.",
                dark: dark
            ) {
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
                Picker("Scene changes", selection: model.stateBinding(\.transition)) {
                    ForEach(VirtualCameraTransition.allCases, id: \.self) { transition in
                        Text(transition.title).tag(transition)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Mirror the preview", isOn: model.stateBinding(\.mirrorPreview))
                Text(
                    "Mirroring only flips this preview. Apps receive the picture the right way round."
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
