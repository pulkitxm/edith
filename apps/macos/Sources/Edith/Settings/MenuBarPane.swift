import EdithKit
import SwiftUI

struct MenuBarPane: View {
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var systemStats = false
    @AppStorage("menuBarColorMode", store: SharedDefaults.store) private var menuBarColorMode =
        "auto"
    @AppStorage("smartColor", store: SharedDefaults.store) private var smartColor = true
    @AppStorage("menuBarSubColorHex", store: SharedDefaults.store) private var subColorHex =
        "8E8E93"
    @AppStorage("menuBarLowColorHex", store: SharedDefaults.store) private var lowColorHex =
        "34C759"
    @AppStorage("menuBarMidColorHex", store: SharedDefaults.store) private var midColorHex =
        "FF9500"
    @AppStorage("menuBarHighColorHex", store: SharedDefaults.store) private var highColorHex =
        "FF3B30"
    @AppStorage("warnPercent", store: SharedDefaults.store) private var warnPercent = 60
    @AppStorage("critPercent", store: SharedDefaults.store) private var critPercent = 85

    var body: some View {
        Form {
            Section("Menu bar stats") {
                Toggle("Show Claude usage (5h / 7d)", isOn: $limitsInMenuBar)
                    .pointerCursor()
                Toggle("Show CPU & memory", isOn: $systemStats)
                    .pointerCursor()
                Text("Live system CPU and memory usage, refreshed every couple of seconds.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Usage readout color") {
                Picker("Color", selection: $menuBarColorMode) {
                    Text("Auto").tag("auto")
                    Text("White").tag("white")
                    Text("Black").tag("black")
                    Text("Custom").tag("custom")
                }
                .pointerCursor()
                if menuBarColorMode == "custom" {
                    ColorPicker(
                        "Text color (5h / 7d)", selection: hexBinding($subColorHex),
                        supportsOpacity: false)
                    ColorPicker(
                        "Low risk", selection: hexBinding($lowColorHex), supportsOpacity: false)
                    ColorPicker(
                        "Medium risk", selection: hexBinding($midColorHex), supportsOpacity: false)
                    ColorPicker(
                        "High risk", selection: hexBinding($highColorHex), supportsOpacity: false)
                }
                Toggle("Smart color", isOn: $smartColor)
                    .pointerCursor()
                Text("Colors the readout by time-aware risk instead of the raw percentage.")
                    .font(.caption).foregroundStyle(.secondary)
                if !smartColor {
                    HStack {
                        Text("Thresholds")
                        Spacer()
                        Stepper(
                            "Warn \(warnPercent)%", value: $warnPercent, in: 10...critPercent - 5,
                            step: 5
                        )
                        .pointerCursor()
                        Stepper(
                            "Critical \(critPercent)%", value: $critPercent,
                            in: warnPercent + 5...100, step: 5
                        )
                        .pointerCursor()
                    }
                }
            }

            PanelTabsSection()
        }
        .formStyle(.grouped)
        .navigationTitle("Menu bar")
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { DashPalette.color(hex.wrappedValue) },
            set: { hex.wrappedValue = $0.menuBarPaneHex6 })
    }
}

extension Color {
    fileprivate var menuBarPaneHex6: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
