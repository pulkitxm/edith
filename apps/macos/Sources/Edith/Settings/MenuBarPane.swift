import EdithKit
import SwiftUI

struct MenuBarPane: View {
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true
    @AppStorage("menuBarSystemStats", store: SharedDefaults.store) private var systemStats = false
    @AppStorage("mainWindowSection", store: SharedDefaults.store) private var mainWindowSection =
        MainDestination.dashboard.rawValue
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
    @AppStorage("menuBarStatsColorHex", store: SharedDefaults.store) private var statsColorHex =
        "FFFFFF"

    var body: some View {
        Form {
            Section {
                LabeledContent("What appears in the menu bar") {
                    Button("Open Extensions") {
                        mainWindowSection = MainDestination.extensions.rawValue
                    }
                    .pointerCursor()
                }
                Text(
                    "Each extension decides whether it shows a menu bar item; this pane only styles them."
                )
                .font(.caption).foregroundStyle(.secondary)
            }

            if systemStats {
                Section("CPU & memory") {
                    ColorPicker(
                        "Color", selection: hexBinding($statsColorHex), supportsOpacity: false)
                }
            }

            if limitsInMenuBar {
                Section {
                    Picker("Color", selection: colorModeBinding) {
                        Text("White").tag("white")
                        Text("Black").tag("black")
                        Text("Custom").tag("custom")
                    }
                    .pointerCursor()

                    if isCustomColor {
                        ColorPicker(
                            "Text (5h / 7d)", selection: hexBinding($subColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "Low risk", selection: hexBinding($lowColorHex), supportsOpacity: false)
                        ColorPicker(
                            "Medium risk", selection: hexBinding($midColorHex),
                            supportsOpacity: false)
                        ColorPicker(
                            "High risk", selection: hexBinding($highColorHex),
                            supportsOpacity: false)
                        Toggle("Smart color", isOn: $smartColor)
                            .pointerCursor()
                        if !smartColor {
                            HStack {
                                Text("Thresholds")
                                Spacer()
                                Stepper(
                                    "Warn \(warnPercent)%", value: $warnPercent,
                                    in: 10...critPercent - 5, step: 5
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
                } header: {
                    Text("Agent limit readout")
                } footer: {
                    Text(
                        isCustomColor
                            ? "The percentage shifts from Low to High risk as usage climbs. Smart color drives that shift by time-aware pacing instead of the raw percentage."
                            : "White and Black force a single tint. Pick Custom to color by risk stage."
                    )
                    .font(.caption)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Menu bar")
    }

    private var isCustomColor: Bool {
        menuBarColorMode == "custom" || menuBarColorMode == "auto"
    }

    private var colorModeBinding: Binding<String> {
        Binding(
            get: { isCustomColor ? "custom" : menuBarColorMode },
            set: { menuBarColorMode = $0 })
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { DashPalette.color(hex.wrappedValue) },
            set: { hex.wrappedValue = $0.hex6 })
    }
}
