import AppKit
import EdithKit
import SwiftUI

extension SweaterStitch: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

extension SweaterAnchor: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

extension SweaterOrder: ConfigurationBindingValue {
    var configurationValue: JSONValue { .string(rawValue) }
}

struct WindowSweatersRows: View {
    private typealias Keys = AppStorageKeys.WindowSweaters

    @AppStorage(SweaterState.enabledKey, store: SharedDefaults.store) private var enabled = false
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
            Toggle("Sweaters on", isOn: $active.configured(SweaterState.activeKey))
            Text(
                "Takes the knitting off every window without removing the extension. Your colourways are kept."
            )
            .settingsCaption()

            SweaterPreviewStrip(
                pattern: selection, stitch: stitch, basket: basket, borderWidth: borderWidth,
                gauge: max(gauge, minimumGauge), anchor: anchor,
                appTheme: AppTheme(storedName: appTheme))

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Picker("Pattern", selection: $pattern.configured(Keys.pattern)) {
                    Text("By App").tag("by-app")
                    Text("Plain").tag("none")
                    Divider()
                    ForEach(SweaterPatternCatalog.featured, id: \.name) { entry in
                        Text(entry.title).tag(entry.name)
                    }
                }
                Text(
                    "By App gives each app its own knitting. Plain leaves a single stitch, and the named patterns knit every window the same way in its own colour."
                )
                .settingsCaption()
            }

            if selection == .plain {
                VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                    Picker("Stitch", selection: $stitch.configured(Keys.stitch)) {
                        ForEach(SweaterStitch.allCases, id: \.self) { value in
                            Text(value.title).tag(value)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text("How the plain knitting is worked.")
                        .settingsCaption()
                }
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Picker("Spare wool", selection: $basket.configured(Keys.basket)) {
                    ForEach(SweaterBaskets.all) { entry in
                        Text(entry.title).tag(entry.name)
                    }
                }
                Text(
                    "Apps without a sweater of their own take a colour from this basket, picked from their name so it never changes."
                )
                .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Border width") {
                    Text(
                        Self.label(
                            for: borderWidth, in: SweaterLimits.borderWidthPresets, unit: "pt")
                    )
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Slider(
                    value: $borderWidth.configured(Keys.borderWidth),
                    in: SweaterLimits.borderWidthRange, step: 1)
                Text("How wide a band is knitted around each window.")
                    .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Stitch size") {
                    Text(Self.label(for: gauge, in: SweaterLimits.gaugePresets, unit: "rows"))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $gauge.configured(Keys.gauge),
                    in: minimumGauge...SweaterLimits.gaugeRange.upperBound, step: 1)
                Text(
                    "Stitch rows across the band. Fewer rows knit chunkier; a pattern needs at least \(Int(minimumGauge)) to read."
                )
                .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Picker("Sits", selection: $order.configured(Keys.order)) {
                    Text("Behind").tag(SweaterOrder.below)
                    Text("In front").tag(SweaterOrder.above)
                }
                .pickerStyle(.segmented)
                Text(
                    "Behind tucks the knitting under the window edge. In front lays it over the edge, which reads more strongly but covers a sliver of the window."
                )
                .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent("Unfocused") {
                    Text("\(Int(unfocusedDim * 100))%")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(
                    value: $unfocusedDim.configured(Keys.unfocusedDim),
                    in: SweaterLimits.dimRange)
                Text("Darkens the sweater on every window except the one you are using.")
                    .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                Picker("Repeat starts", selection: $anchor.configured(Keys.anchor)) {
                    Text("At the corner").tag(SweaterAnchor.corner)
                    Text("Centred").tag(SweaterAnchor.centre)
                }
                .pickerStyle(.segmented)
                Text(
                    "Anchoring at the corner holds the pattern still while a window resizes. Centring composes each side, but slides as the window grows."
                )
                .settingsCaption()
            }

            VStack(alignment: .leading, spacing: UIScale.pt(6)) {
                LabeledContent {
                    TextField(
                        "Terminal, Preview", text: $excludedApps.configured(Keys.excludedApps)
                    )
                    .textFieldStyle(.roundedBorder)
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Never knit")
                        InfoDot("Comma-separated app names that stay bare.")
                    }
                }
                Text("Apps listed here keep their plain window edges.")
                    .settingsCaption()
            }

            Toggle(
                "Follow focus through Accessibility",
                isOn: $accessibilityFocus.configured(Keys.accessibilityFocus))
            Text(
                "Reads the focused window from the app itself rather than the window server. More accurate in apps with panels, and needs Accessibility."
            )
            .settingsCaption()
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
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

private struct SweaterPreviewStrip: View {
    let pattern: SweaterPattern
    let stitch: SweaterStitch
    let basket: String
    let borderWidth: Double
    let gauge: Double
    let anchor: SweaterAnchor
    let appTheme: AppTheme

    private static let sampleApps = ["Edith", "Claude", "Finder", "Spotify"]

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
        .padding(.vertical, UIScale.pt(4))
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
        context.setFillColor(NSColor.textBackgroundColor.cgColor)
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
