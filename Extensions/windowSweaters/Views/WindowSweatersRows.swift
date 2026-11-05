import AppKit
import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct WindowSweatersRows: View {
    private typealias Keys = AppStorageKeys.WindowSweaters

    let presentation: ControlPresentation
    @AppStorage(SweaterState.activeKey, store: SharedDefaults.store) private var active = true
    @AppStorage(Keys.pattern, store: SharedDefaults.store) private var pattern = "by-app"
    @AppStorage(Keys.stitch, store: SharedDefaults.store) private var stitch = SweaterStitch
        .stockinette
    @AppStorage(Keys.basket, store: SharedDefaults.store) private var basket = SweaterBaskets
        .defaultName
    @AppStorage(Keys.borderWidth, store: SharedDefaults.store) private var borderWidth =
        SweaterLimits.defaultBorderWidth
    @AppStorage(Keys.gauge, store: SharedDefaults.store) private var gauge = SweaterLimits
        .defaultGauge
    @AppStorage(Keys.order, store: SharedDefaults.store) private var order = SweaterOrder.below
    @AppStorage(Keys.anchor, store: SharedDefaults.store) private var anchor = SweaterAnchor.corner
    @AppStorage(Keys.unfocusedDim, store: SharedDefaults.store) private var unfocusedDim = 0.0
    @AppStorage(Keys.accessibilityFocus, store: SharedDefaults.store) private
        var accessibilityFocus = false
    @AppStorage(Keys.excludedApps, store: SharedDefaults.store) private var excludedApps = ""
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var appTheme =
        AppTheme.accent.rawValue

    private var selection: SweaterPattern { SweaterPattern.from(pattern) }

    private var minimumGauge: Double { SweaterPatternCatalog.minimumRows(for: selection) }

    var body: some View {
        Section {
            Toggle(isOn: $active.notifyingSettingsChange()) {
                Text("Sweaters on")
                Text("Shows or hides the knitting on every window. Your colours are kept.")
            }
            if active && !presentation.active {
                SettingsNoticeRow(
                    "Starts when this extension is enabled",
                    message: "Your choice is saved and takes effect as soon as it runs.",
                    symbol: "clock.fill")
            }
            Picker(selection: $pattern.notifyingSettingsChange()) {
                Text("By App").tag("by-app")
                Text("Plain").tag("none")
                Divider()
                ForEach(SweaterPatternCatalog.featured, id: \.name) { entry in
                    Text(entry.title).tag(entry.name)
                }
            } label: {
                Text("Pattern")
                Text(
                    "By App gives each app its own knitting. Plain uses one stitch, and a named pattern knits every window the same way."
                )
            }
            if selection == .plain {
                LabeledContent {
                    EdithSegmentedPicker(
                        "Stitch", selection: $stitch.notifyingSettingsChange(),
                        options: SweaterStitch.allCases, label: { $0.title }
                    )
                    .frame(width: UIScale.pt(252))
                } label: {
                    Text("Stitch")
                    Text("How the plain knitting is worked.")
                }
            }
            Picker(selection: $basket.notifyingSettingsChange()) {
                ForEach(SweaterBaskets.all) { entry in
                    Text(entry.title).tag(entry.name)
                }
            } label: {
                Text("Spare wool")
                Text(
                    "Apps without a sweater of their own take a colour from this basket. It never changes for the same app."
                )
            }
        } header: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                SweaterIntro(
                    preview: SweaterPreviewStrip(
                        pattern: selection, stitch: stitch, basket: basket,
                        borderWidth: borderWidth, gauge: max(gauge, minimumGauge), anchor: anchor,
                        appTheme: AppTheme(storedName: appTheme))
                )
                .padding(.horizontal, -SweaterIntro.formHeaderInset)
                if presentation.ready, let error = presentation.error {
                    PageNotice(error, title: "Settings could not be saved", tone: .warning) {
                        EmptyView()
                    } actions: {
                        Button("Try again") { presentation.retry() }
                    }
                    .padding(.horizontal, -SweaterIntro.formHeaderInset)
                }
                Text("Knitting")
            }
        }

        Section("Fit") {
            sliderRow(
                "Border width",
                detail: "How wide a band is knitted around each window.",
                value: $borderWidth, range: SweaterLimits.borderWidthRange, step: 1,
                readout: Self.label(
                    for: borderWidth, in: SweaterLimits.borderWidthPresets, unit: "pt"))
            sliderRow(
                "Stitch size",
                detail:
                    "Fewer rows knit chunkier. This pattern needs at least \(Int(minimumGauge)) rows to read.",
                value: $gauge, range: minimumGauge...SweaterLimits.gaugeRange.upperBound, step: 1,
                readout: Self.label(for: gauge, in: SweaterLimits.gaugePresets, unit: "rows"))
            LabeledContent {
                EdithSegmentedPicker(
                    "Sits", selection: $order.notifyingSettingsChange(),
                    options: [SweaterOrder.below, .above],
                    label: { $0 == .below ? "Behind" : "In front" }
                )
                .frame(width: UIScale.pt(184))
            } label: {
                Text("Sits")
                Text("In front reads more strongly but covers a sliver of the window edge.")
            }
            LabeledContent {
                EdithSegmentedPicker(
                    "Repeat starts", selection: $anchor.notifyingSettingsChange(),
                    options: [SweaterAnchor.corner, .centre],
                    label: { $0 == .corner ? "At the corner" : "Centred" }
                )
                .frame(width: UIScale.pt(184))
            } label: {
                Text("Repeat starts")
                Text("At the corner holds the pattern still while a window resizes.")
            }
            sliderRow(
                "Unfocused",
                detail: "Darkens the sweater on every window except the one you are using.",
                value: $unfocusedDim, range: SweaterLimits.dimRange, step: nil,
                readout: "\(Int(unfocusedDim * 100))%")
        }

        Section("Apps") {
            SettingsRow(
                "Never knit",
                subtitle: "App names, separated by commas, that keep their plain window edges."
            ) {
                TextField(
                    "Apps to skip", text: $excludedApps.notifyingSettingsChange(),
                    prompt: Text("Terminal, Preview")
                )
                .labelsHidden()
                .multilineTextAlignment(.leading)
                .textFieldStyle(.roundedBorder)
                .frame(width: UIScale.pt(260))
            }
            Toggle(isOn: $accessibilityFocus.notifyingSettingsChange()) {
                Text("Follow focus through Accessibility")
                Text(
                    "Asks each app which window is focused. More accurate in apps with panels, and needs Accessibility access."
                )
            }
        }
    }

    private func sliderRow(
        _ title: String, detail: String, value: Binding<Double>, range: ClosedRange<Double>,
        step: Double?, readout: String
    ) -> some View {
        SettingsRow(title, subtitle: detail) {
            HStack(spacing: UIScale.pt(12)) {
                Group {
                    if let step {
                        Slider(value: value.notifyingSettingsChange(), in: range, step: step)
                    } else {
                        Slider(value: value.notifyingSettingsChange(), in: range)
                    }
                }
                .labelsHidden()
                .frame(width: UIScale.pt(PageMetrics.settingsSliderWidth))
                Text(readout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(width: UIScale.pt(116), alignment: .trailing)
            }
        }
    }

    private static func label(
        for value: Double, in presets: [(title: String, value: Double)], unit: String
    ) -> String {
        let rounded = (value * 10).rounded() / 10
        if let match = presets.first(where: { abs($0.value - rounded) < 0.001 }) {
            return "\(match.title) · \(Int(rounded)) \(unit)"
        }
        return "\(Int(rounded)) \(unit)"
    }
}

private struct SweaterIntro: View {
    static let formHeaderInset = 10.0

    let preview: SweaterPreviewStrip
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        VStack(alignment: .leading, spacing: UIScale.pt(12)) {
            preview
                .padding(UIScale.pt(12))
                .frame(maxWidth: .infinity)
                .background(DashSkin.paper(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(8)))
            VStack(alignment: .leading, spacing: UIScale.pt(4)) {
                Text("A knitted border around every window")
                    .font(.edithText(.title3)).fontWeight(.semibold)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "Each app gets its own colours, so you can tell windows apart at a glance. It is drawn around the edges only: your windows and apps are never changed. The preview above follows your choices."
                )
                .font(.edithText(.body))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, UIScale.pt(16))
        .padding(.horizontal, Self.formHeaderInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DashSkin.paper2(dark), in: RoundedRectangle(cornerRadius: UIScale.pt(12)))
        .overlay(RoundedRectangle(cornerRadius: UIScale.pt(12)).strokeBorder(DashSkin.line(dark)))
    }
}

private struct SweaterPreviewStrip: View {
    let pattern: SweaterPattern
    let stitch: SweaterStitch
    let basket: String
    let borderWidth: Double
    let gauge: Double
    let anchor: SweaterAnchor
    let appTheme: AppTheme

    private static let sampleApps = ["Edith", "Claude", "Finder", "Spotify"]
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: UIScale.pt(10)) {
            ForEach(Self.sampleApps, id: \.self) { app in
                if let image = swatch(for: app) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(height: UIScale.pt(56))
                        .accessibilityLabel("\(app) sweater preview")
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func swatch(for app: String) -> NSImage? {
        let scale = 2
        let width = 110 * scale
        let height = 56 * scale
        guard
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGImageByteOrderInfo.order32Host.rawValue)
        else { return nil }
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))

        let window = CGRect(x: 22, y: 16, width: 66, height: 24)
        context.setFillColor(
            scheme == .dark
                ? CGColor(srgbRed: 0.17, green: 0.17, blue: 0.18, alpha: 1)
                : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        let panel = CGPath(
            roundedRect: window, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(panel)
        context.fillPath()

        var knitGauge = KnitGauge.standard
        knitGauge.rows = gauge
        let yarn = SweaterYarn.resolve(
            app: app, pattern: pattern, basket: SweaterBaskets.basket(named: basket),
            appTheme: appTheme)

        KnitRenderer.shared.draw(
            in: context, windowRect: window, radius: 6,
            band: min(borderWidth, 16), color: yarn.color, chart: yarn.chart, dim: 0, tuck: 1,
            stitch: stitch, anchor: anchor, gauge: knitGauge)

        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 110, height: 56))
    }
}
