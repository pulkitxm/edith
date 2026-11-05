import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct HingeRows: View {
    let presentation: ControlPresentation
    @AppStorage(HingeState.activeKey, store: SharedDefaults.store) private var active = false
    @AppStorage(HingeSettings.effectStrength, store: SharedDefaults.store) private var strength =
        1.0
    @AppStorage(HingeSettings.sideFill, store: SharedDefaults.store) private var sideFill =
        HingeSideFill.blur
    @AppStorage(HingeSettings.cropsTop, store: SharedDefaults.store) private var cropsTop = true
    @AppStorage(HingeSettings.blursByDistance, store: SharedDefaults.store) private
        var blursByDistance = true
    @AppStorage(HingeSettings.openAngle, store: SharedDefaults.store) private var openAngle = 100.0
    @AppStorage(HingeSettings.sensorAvailable, store: SharedDefaults.store) private
        var sensorAvailable = false
    @AppStorage(HingeSettings.status, store: SharedDefaults.store) private var status = ""

    var body: some View {
        Form {
            Section {
                Group {
                    Toggle(isOn: $active.notifyingSettingsChange()) {
                        Text("Fold the desktop")
                        Text("Turning it off puts the screen straight back to normal.")
                    }
                    if !status.isEmpty {
                        Label {
                            Text(status).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(
                                .orange)
                        }
                        .font(.edithText(.subheadline))
                    }
                    LabeledContent {
                        HStack(alignment: .firstTextBaseline, spacing: UIScale.pt(8)) {
                            Text("\(Int(openAngle.rounded()))°")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Button("Use current angle") { presentation.perform("calibrate") }
                                .buttonStyle(.edith(.secondary))
                                .disabled(!sensorAvailable)
                                .help(
                                    sensorAvailable
                                        ? "Saves the lid angle right now as your open position."
                                        : "Needs a Mac with a lid angle sensor.")
                        }
                    } label: {
                        Text("Open position")
                        Text(
                            sensorAvailable || !presentation.active
                                ? "Open the lid the way you normally work, then press Use current angle."
                                : "This Mac has no lid angle sensor Hinge can read, so the fold cannot follow the lid."
                        )
                    }
                    LabeledContent {
                        HotKeyRecorderControl(keyPrefix: "hingeHotKey", defaultLabel: "⌃⌥H")
                    } label: {
                        Text("Shortcut")
                        Text("Turns the fold on or off from anywhere.")
                    }
                }
                .disabled(!presentation.active)
                .opacity(presentation.active ? 1 : 0.6)
            } header: {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    HingeIntro()
                    if presentation.ready, let error = presentation.error {
                        PageNotice(error, title: "Settings could not be saved", tone: .warning) {
                            EmptyView()
                        } actions: {
                            Button("Try again") { presentation.retry() }
                        }
                    }
                    if !presentation.active {
                        PageNotice(
                            "Hinge is switched off. Turn it on in Extensions to change these settings.",
                            title: "Hinge is not running", symbol: "power")
                    }
                    Text("Fold")
                }
            }

            Section("Look") {
                LabeledContent {
                    HStack(spacing: UIScale.pt(12)) {
                        Slider(
                            value: $strength.notifyingSettingsChange(),
                            in: HingeSettings.strengthRange
                        )
                        .labelsHidden()
                        .frame(maxWidth: UIScale.pt(220))
                        Text("\(Int(strength * 100))%")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                            .frame(minWidth: UIScale.pt(40), alignment: .trailing)
                    }
                } label: {
                    Text("Strength")
                    Text("How far the desktop bends as the lid closes.")
                }
                LabeledContent {
                    EdithSegmentedPicker(
                        "Sides",
                        selection: $sideFill.notifyingSettingsChange(),
                        options: HingeSideFill.allCases,
                        label: { $0 == .blur ? "Blur" : "Black" }
                    )
                    .frame(width: UIScale.pt(168))
                } label: {
                    Text("Sides")
                    Text("What fills the space beside the folded picture.")
                }
                Toggle(isOn: $cropsTop.notifyingSettingsChange()) {
                    Text("Crop the top")
                    Text("Trims the top edge as it bends so the picture does not stretch.")
                }
                Toggle(isOn: $blursByDistance.notifyingSettingsChange()) {
                    Text("Blur by distance")
                    Text("Softens the part of the picture that bends furthest away.")
                }
            }
            .disabled(!presentation.active)
            .opacity(presentation.active ? 1 : 0.6)
        }
        .edithForm()
    }
}

private struct HingeIntro: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.compactLayout) private var compact

    var body: some View {
        let dark = scheme == .dark
        HStack(alignment: .center, spacing: UIScale.pt(compact ? 16 : 20)) {
            HingeFoldArt(dark: dark)
                .frame(width: UIScale.pt(compact ? 96 : 120), height: UIScale.pt(compact ? 80 : 96))
            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Text("Your desktop bends as the lid closes")
                    .font(.edithText(.title3)).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Hinge reads the lid angle and folds the picture on screen like a page. It only changes how the screen is drawn: windows, apps and files are never touched."
                )
                .font(.edithText(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                WrapHStack(spacing: UIScale.pt(8), lineSpacing: UIScale.pt(8)) {
                    HingeFact(symbol: "eye", text: "Visual only")
                    HingeFact(symbol: "laptopcomputer", text: "Follows the lid sensor")
                    HingeFact(symbol: "keyboard", text: "⌃⌥H turns it on or off")
                }
                .padding(.top, UIScale.pt(4))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(UIScale.pt(16))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark)))
        .accessibilityElement(children: .combine)
    }
}

private struct HingeFact: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.edithText(.subheadline))
            .foregroundStyle(.secondary)
            .padding(.horizontal, UIScale.pt(8))
            .frame(height: UIScale.pt(24))
            .background(Color.primary.opacity(0.06), in: Capsule())
    }
}

private struct HingeFoldArt: View {
    let dark: Bool

    var body: some View {
        let accent = DashSkin.accent(dark)
        let base = Color.primary.opacity(dark ? 0.4 : 0.28)
        Canvas { context, size in
            let screenWidth = size.width * 0.8
            let left = (size.width - screenWidth) / 2
            let baseHeight = max(3, size.height * 0.07)
            let flatHeight = size.height * 0.36
            let crease = size.height - baseHeight - 3 - flatHeight
            let foldHeight = flatHeight * 0.62
            let inset = screenWidth * 0.1
            let flat = CGRect(x: left, y: crease, width: screenWidth, height: flatHeight)
            var bent = Path()
            bent.move(to: CGPoint(x: left, y: crease))
            bent.addLine(to: CGPoint(x: left + inset, y: crease - foldHeight))
            bent.addLine(to: CGPoint(x: left + screenWidth - inset, y: crease - foldHeight))
            bent.addLine(to: CGPoint(x: left + screenWidth, y: crease))
            bent.closeSubpath()
            let shading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [accent.opacity(0.95), accent.opacity(0.5)]),
                startPoint: CGPoint(x: 0, y: crease - foldHeight),
                endPoint: CGPoint(x: 0, y: crease + flatHeight))
            context.fill(bent, with: shading)
            context.fill(Path(roundedRect: flat, cornerRadius: 3), with: shading)
            context.fill(
                Path(
                    roundedRect: CGRect(
                        x: left + inset + 6, y: crease - foldHeight + 5,
                        width: screenWidth * 0.3, height: foldHeight * 0.32), cornerRadius: 2),
                with: .color(.white.opacity(0.7)))
            context.fill(
                Path(
                    roundedRect: CGRect(
                        x: flat.maxX - screenWidth * 0.34 - 6, y: flat.maxY - flatHeight * 0.34 - 6,
                        width: screenWidth * 0.34, height: flatHeight * 0.34), cornerRadius: 2),
                with: .color(.white.opacity(0.6)))
            var line = Path()
            line.move(to: CGPoint(x: left, y: crease))
            line.addLine(to: CGPoint(x: left + screenWidth, y: crease))
            context.stroke(line, with: .color(.white.opacity(0.8)), lineWidth: 1)
            context.fill(
                Path(
                    roundedRect: CGRect(
                        x: 0, y: size.height - baseHeight, width: size.width, height: baseHeight),
                    cornerRadius: baseHeight / 2),
                with: .color(base))
        }
        .accessibilityHidden(true)
    }
}
