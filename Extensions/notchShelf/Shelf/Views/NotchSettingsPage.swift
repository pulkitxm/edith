import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchSettingsPage: View {
    private static let formHeaderInset = 10.0

    let model: NotchSettingsModel

    init(model: NotchSettingsModel) { self.model = model }

    init(controller: NotchShelfController) {
        model = NotchSettingsModel(snapshot: controller.settingsSnapshot()) { operation, payload in
            try await controller.execute(operation, payload: payload)
        }
    }

    private var enabled: Bool { model.available }

    private var audioMixerAvailable: Bool {
        if #available(macOS 14.4, *) { return true }
        return false
    }

    var body: some View {
        Form {
            Section {
                Group {
                    LabeledContent {
                        Button("Customize...") { model.perform("notch.customize") }
                            .buttonStyle(.edith(.secondary))
                    } label: {
                        Text("Home and notch layout")
                        Text(
                            "Arrange widgets, resize cards and choose the tabs in the visual editor."
                        )
                    }
                }
                .disabled(!enabled)
                .opacity(enabled ? 1 : 0.6)
            } header: {
                VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                    if let error = model.error {
                        PageNotice(error, title: "Settings could not be loaded", tone: .warning) {
                            EmptyView()
                        } actions: {
                            Button("Try again") { Task { await model.refresh() } }
                        }
                        .padding(.horizontal, -Self.formHeaderInset)
                    }
                    if !model.available {
                        PageNotice(
                            "Notch Shelf is switched off, so these settings are locked. Turn it on in Extensions to use the shelf, browser and alerts.",
                            title: "Notch Shelf is not running", symbol: "power"
                        )
                        .padding(.horizontal, -Self.formHeaderInset)
                    }
                    Text("Layout")
                }
            }

            Section("Opening") {
                preference(
                    "Open when dragging near the notch", AppStorageKeys.Notch.shelfOpenOnDrag,
                    detail: "The shelf slides out mid-drag so you can drop a file without clicking."
                )
                preference(
                    "Open on hover", AppStorageKeys.Notch.shelfOpenOnHover,
                    detail: "Opens when the pointer rests on the notch.")
                preference(
                    "Require \u{2325} to open", AppStorageKeys.Notch.shelfRequireOption,
                    detail:
                        "Only opens while you hold Option, so passing over the notch does nothing.")
                preference(
                    "Show on external displays", AppStorageKeys.Notch.shelfShowOnExternal,
                    detail: "Draws a small pill at the top of screens without a notch.")
                preference(
                    "Haptic feedback", AppStorageKeys.Notch.shelfHaptics,
                    detail: "A light trackpad tap when the shelf reacts.")
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)

            Section("Shelf") {
                Picker(selection: stringBinding(AppStorageKeys.Notch.shelfKeepDuration)) {
                    Text("Forever").tag("forever")
                    Text("1 hour").tag("oneHour")
                    Text("1 day").tag("oneDay")
                    Text("1 week").tag("oneWeek")
                    Text("1 month").tag("oneMonth")
                } label: {
                    Text("Keep items for")
                    Text(
                        "Parked files are copies and are deleted after this long. Originals are never touched."
                    )
                }
                preference(
                    "Remove after dragging out", AppStorageKeys.Notch.shelfRemoveAfterDragOut,
                    detail: "Treats the shelf as a hand-off tray rather than storage.")
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)

            Section("Browser") {
                preference(
                    "Browser tab", AppStorageKeys.Notch.browserEnabled,
                    detail:
                        "A small browser in the notch, signed in with one of your Chrome profiles. Its cookies are copied to a private store on this Mac."
                )
                if boolValue(AppStorageKeys.Notch.browserEnabled) {
                    Picker(
                        "Search with",
                        selection: stringBinding(AppStorageKeys.Notch.browserSearchEngine)
                    ) {
                        ForEach(BrowserSearchEngine.allCases, id: \.rawValue) { engine in
                            Text(engine.title).tag(engine.rawValue)
                        }
                    }
                    LabeledContent {
                        if model.snapshot.browserProfile != nil {
                            Button("Detach and Clear Data", role: .destructive) {
                                model.perform("notch.browser.detach")
                            }
                            .buttonStyle(.edith(.destructive))
                            .help(
                                "Deletes the cookies and site data copied from Chrome. Your Chrome profile is not changed."
                            )
                        }
                    } label: {
                        Text(
                            model.snapshot.browserProfile.map { "Chrome profile: \($0)" }
                                ?? "No Chrome profile attached")
                        Text(
                            model.snapshot.browserProfile == nil
                                ? "Open the notch and choose the Browser tab to sign in with a Chrome profile."
                                : "Cookies and site storage copied from Chrome stay on this Mac.")
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)

            Section("Music and alerts") {
                preference(
                    "Show what's playing", AppStorageKeys.Notch.shelfShowMusic,
                    detail: "Album art and a live equalizer sit beside the notch while music plays."
                )
                preference(
                    "Notch alerts", AppStorageKeys.Notch.alertsEnabled,
                    detail:
                        "A brief card drops from the notch. Alerts that arrive while it is open wait until it closes."
                )
                if boolValue(AppStorageKeys.Notch.alertsEnabled) {
                    preference("Audio output changes", AppStorageKeys.Notch.alertAudio)
                    preference("Power plugged in or unplugged", AppStorageKeys.Notch.alertPower)
                    preference("Battery low", AppStorageKeys.Notch.alertBattery)
                    preference(
                        "Bluetooth connects or disconnects", AppStorageKeys.Notch.alertBluetooth)
                    if boolValue(AppStorageKeys.Notch.alertBluetooth),
                        model.snapshot.bluetoothPrivacyRequired == true
                    {
                        LabeledContent {
                            Button("Open Privacy Settings...") {
                                model.perform("notch.bluetooth.settings")
                            }
                            .buttonStyle(.edith(.secondary))
                        } label: {
                            Text("Bluetooth access needed")
                            Text("macOS asks before Edith can see Bluetooth devices.")
                        }
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)

            Section("Audio") {
                preference(
                    "Per-app volume mixer (beta)", AppStorageKeys.Notch.audioMixerEnabled,
                    detail: audioMixerAvailable
                        ? "Adds an Audio tab with a volume slider for each app. macOS asks for audio access the first time."
                        : "Needs macOS 14.4 or later, so it is unavailable on this Mac."
                )
                .disabled(
                    !audioMixerAvailable && !boolValue(AppStorageKeys.Notch.audioMixerEnabled))
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.6)
        }
        .settingsForm()
        .pageTask { await model.refresh() }
    }

    private func boolValue(_ key: String) -> Bool { model.snapshot.preferences[key] == "1" }

    private func boolBinding(_ key: String) -> Binding<Bool> {
        Binding(get: { boolValue(key) }, set: { model.set(key, value: $0 ? "1" : "0") })
    }

    private func stringBinding(_ key: String) -> Binding<String> {
        Binding(
            get: { model.snapshot.preferences[key] ?? NotchSettingsSchema.defaults[key] ?? "" },
            set: { model.set(key, value: $0) })
    }

    private func preference(_ title: String, _ key: String, detail: String? = nil) -> some View {
        Toggle(isOn: boolBinding(key)) {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
