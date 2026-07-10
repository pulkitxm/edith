import AppKit
import EdithKit
import SwiftUI

struct UsagePane: View {
    @AppStorage("tabUsageEnabled", store: SharedDefaults.store) private var enabled = true
    @AppStorage("limitsInMenuBar", store: SharedDefaults.store) private var limitsInMenuBar = true
    @AppStorage("menuBarColorMode", store: SharedDefaults.store) private var menuBarColorMode =
        "auto"
    @AppStorage("menuBarSubColorHex", store: SharedDefaults.store) private var subColorHex =
        "8E8E93"
    @AppStorage("menuBarLowColorHex", store: SharedDefaults.store) private var lowColorHex =
        "34C759"
    @AppStorage("menuBarMidColorHex", store: SharedDefaults.store) private var midColorHex =
        "FF9500"
    @AppStorage("menuBarHighColorHex", store: SharedDefaults.store) private var highColorHex =
        "FF3B30"
    @AppStorage("smartColor", store: SharedDefaults.store) private var smartColor = true
    @AppStorage("warnPercent", store: SharedDefaults.store) private var warnPercent = 60
    @AppStorage("critPercent", store: SharedDefaults.store) private var critPercent = 85
    @AppStorage("pacingMargin", store: SharedDefaults.store) private var pacingMargin = 10.0

    @AppStorage("budgetEnabled", store: SharedDefaults.store) private var budgetEnabled = false
    @AppStorage("budgetMode", store: SharedDefaults.store) private var budgetMode = "pace"
    @AppStorage("budgetKind", store: SharedDefaults.store) private var budgetKind = "weekly"
    @AppStorage("budgetCapPercent", store: SharedDefaults.store) private var budgetCap = 50.0
    @AppStorage("budgetDeadline", store: SharedDefaults.store) private var budgetDeadlineTS = 0.0

    @AppStorage("notifyMaster", store: SharedDefaults.store) private var notifyMaster = false
    @AppStorage("notifyTrackSession", store: SharedDefaults.store) private var trackSession = true
    @AppStorage("notifyTrackWeekly", store: SharedDefaults.store) private var trackWeekly = true
    @AppStorage("notifyRecovery", store: SharedDefaults.store) private var recovery = true
    @AppStorage("notifyPacingWarning", store: SharedDefaults.store) private var pacingWarning = true
    @AppStorage("notifyPacingHot", store: SharedDefaults.store) private var pacingHot = true
    @AppStorage("notifyReminderSession", store: SharedDefaults.store) private var reminderSession =
        false
    @AppStorage("notifyReminderSessionOffsetMin", store: SharedDefaults.store)
    private var reminderSessionOffset = 30
    @AppStorage("notifyReminderWeekly", store: SharedDefaults.store) private var reminderWeekly =
        false
    @AppStorage("notifyReminderWeeklyOffsetMin", store: SharedDefaults.store)
    private var reminderWeeklyOffset = 120
    @AppStorage("notifyTokenExpired", store: SharedDefaults.store) private var tokenExpired = true

    @State private var testSent = false

    var body: some View {
        Form {
            Section {
                Toggle("Usage & limits", isOn: $enabled)
                    .pointerCursor()
                Text("Session and weekly rate-limit rings, plus their menu bar readout.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Personal budget") {
                Toggle("Pace my Claude usage", isOn: $budgetEnabled)
                    .pointerCursor()
                Text(
                    "Set a personal cap under the real limit and get told if you're spending too fast."
                )
                .font(.caption).foregroundStyle(.secondary)
                if budgetEnabled {
                    Picker("Mode", selection: $budgetMode) {
                        Text("Auto daily pace").tag("pace")
                        Text("Cap by a deadline").tag("cap")
                    }.pointerCursor()
                    Picker("Window", selection: $budgetKind) {
                        Text("Weekly").tag("weekly")
                        Text("Session (5h)").tag("session")
                    }.pointerCursor()
                    HStack {
                        Text("Cap")
                        Slider(value: $budgetCap, in: 10...100, step: 5)
                        Text("\(Int(budgetCap))%").monospacedDigit().frame(
                            width: 40, alignment: .trailing)
                    }
                    if budgetMode == "cap" {
                        DatePicker(
                            "Stay under until",
                            selection: Binding(
                                get: {
                                    budgetDeadlineTS > 0
                                        ? Date(timeIntervalSinceReferenceDate: budgetDeadlineTS)
                                        : Date().addingTimeInterval(2 * 86400)
                                },
                                set: { budgetDeadlineTS = $0.timeIntervalSinceReferenceDate }),
                            displayedComponents: [.date, .hourAndMinute])
                    }
                }
            }

            Section {
                Toggle("Show in menu bar", isOn: $limitsInMenuBar)
                    .pointerCursor()
                Picker("Menu bar color", selection: $menuBarColorMode) {
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
                HStack {
                    Toggle("Smart color", isOn: $smartColor)
                        .pointerCursor()
                    InfoDot(
                        "When on, both the menu bar color AND the alerts below key off a time-aware risk model instead of the raw percentage - so a weekly alert can fire before you hit the warn threshold if you're burning faster than an even pace."
                    )
                }
                HStack {
                    Text("Thresholds")
                    Spacer()
                    Stepper(
                        "Warn \(warnPercent)%", value: $warnPercent, in: 10...critPercent - 5,
                        step: 5
                    )
                    .pointerCursor()
                    Stepper(
                        "Critical \(critPercent)%", value: $critPercent, in: warnPercent + 5...100,
                        step: 5
                    )
                    .pointerCursor()
                }
            } header: {
                Text("Limits")
            }

            Section {
                Toggle("Enable alerts", isOn: $notifyMaster)
                    .pointerCursor()
                Group {
                    HStack {
                        Toggle("Session (5h) alerts", isOn: $trackSession)
                            .pointerCursor()
                        InfoDot(
                            "Fires once when the session window crosses warn or critical - it won't repeat while you stay in that zone."
                        )
                    }
                    HStack {
                        Toggle("Weekly alerts", isOn: $trackWeekly)
                            .pointerCursor()
                        InfoDot(
                            "Fires once when the weekly window crosses warn or critical - same one-shot-per-zone behavior as session alerts."
                        )
                    }
                    Toggle("Back to green", isOn: $recovery)
                        .pointerCursor()
                    HStack {
                        Text("Pacing margin")
                        Spacer()
                        Stepper(
                            "±\(Int(pacingMargin)) pp", value: $pacingMargin, in: 5...25, step: 5
                        )
                        .pointerCursor()
                    }
                    HStack {
                        Toggle("Drifting / burning hot", isOn: $pacingWarning)
                            .pointerCursor()
                        InfoDot(
                            "A separate signal from the level alerts above: how far ahead of an even burn-rate pace you are, regardless of the absolute percentage."
                        )
                    }
                    Toggle("Token expired", isOn: $tokenExpired)
                        .pointerCursor()
                    HStack {
                        Toggle("Remind before session reset", isOn: $reminderSession)
                            .pointerCursor()
                        Picker("", selection: $reminderSessionOffset) {
                            Text("5 min").tag(5)
                            Text("15 min").tag(15)
                            Text("30 min").tag(30)
                            Text("1 h").tag(60)
                        }
                        .labelsHidden().pointerCursor().disabled(!reminderSession)
                    }
                    HStack {
                        Toggle("Remind before weekly reset", isOn: $reminderWeekly)
                            .pointerCursor()
                        Picker("", selection: $reminderWeeklyOffset) {
                            Text("1 h").tag(60)
                            Text("2 h").tag(120)
                            Text("6 h").tag(360)
                            Text("12 h").tag(720)
                        }
                        .labelsHidden().pointerCursor().disabled(!reminderWeekly)
                    }
                }
                .disabled(!notifyMaster)
                .opacity(notifyMaster ? 1 : 0.5)

                HStack {
                    Button("Send test notification") {
                        IPC.post(IPC.Name.requestTestNotification)
                        testSent = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { testSent = false }
                    }
                    .pointerCursor()
                    if testSent {
                        Text("Sent - check Notification Center")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text(
                    "Alerts fire once per level or zone crossing, not on a repeating timer - staying in the same zone won't page you again."
                )
                .font(.caption)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Usage")
    }

    private func hexBinding(_ hex: Binding<String>) -> Binding<Color> {
        Binding(
            get: { DashPalette.color(hex.wrappedValue) },
            set: { hex.wrappedValue = $0.menuBarHex6 })
    }
}

extension Color {
    fileprivate var menuBarHex6: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "%02X%02X%02X", r, g, b)
    }
}
