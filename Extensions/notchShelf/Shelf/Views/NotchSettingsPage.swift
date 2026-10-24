import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchSettingsPage: View {
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
            if let error = model.error {
                Section {
                    Text(error).font(.edithText(.callout)).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.refresh() } }.buttonStyle(
                        .edith(.secondary))
                }
            }
            if !model.available {
                Section {
                    Text("Enable Notch Shelf to configure its running engine.").font(
                        .edithText(.callout))
                }
            }
            Section("Layout") {
                Button("Customize Home & Notch") { model.perform("notch.customize") }
                Text(
                    "Arrange widgets, resize cards, and configure your Notch in the visual editor."
                ).settingsCaption()
            }
            Section {
                preference(
                    "Open when dragging near the notch", AppStorageKeys.Notch.shelfOpenOnDrag)
                Text("The island slides out mid-drag so you can drop without clicking first.")
                    .settingsCaption()
                preference("Open on hover", AppStorageKeys.Notch.shelfOpenOnHover)
                Text("Expand when the mouse rests on the notch, without a drag.")
                    .settingsCaption()
                Toggle(isOn: boolBinding(AppStorageKeys.Notch.shelfRequireOption)) {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Require \u{2325} to trigger")
                        InfoDot(
                            "Only expand - on drag or on hover - while you're holding Option. Keeps accidental passes over the notch from opening it."
                        )
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section("Browser") {
                preference("Browser tab", AppStorageKeys.Notch.browserEnabled)
                Text(
                    "A tabbed WebKit browser in the shelf, signed in with one of your Google Chrome profiles. Cookies and site storage are copied into a private store on this Mac and resync every few minutes while you browse."
                )
                .settingsCaption()
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
                        }
                    } label: {
                        Text(
                            model.snapshot.browserProfile.map { "Chrome profile: \($0)" }
                                ?? "No Chrome profile attached")
                        Text(
                            model.snapshot.browserProfile == nil
                                ? "Open the shelf's browser tab to pick a profile."
                                : "Cookies and site storage copied from Chrome stay on this Mac.")
                    }
                }
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                Picker(selection: stringBinding(AppStorageKeys.Notch.shelfKeepDuration)) {
                    Text("Forever").tag("forever")
                    Text("1 hour").tag("oneHour")
                    Text("1 day").tag("oneDay")
                    Text("1 week").tag("oneWeek")
                    Text("1 month").tag("oneMonth")
                } label: {
                    HStack(spacing: UIScale.pt(6)) {
                        Text("Keep items for")
                        InfoDot(
                            "Parked files auto-delete after this long. They're copies - originals are never touched."
                        )
                    }
                }
                preference(
                    "Remove after dragging out", AppStorageKeys.Notch.shelfRemoveAfterDragOut)
                Text("Treats the shelf as a hand-off tray rather than storage.")
                    .settingsCaption()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)

            Section {
                preference("Show what's playing", AppStorageKeys.Notch.shelfShowMusic)
                Text(
                    "Album art and a live equalizer hug the notch while music plays in the library, Spotify, or Apple Music."
                )
                .settingsCaption()
                preference("Notch alerts", AppStorageKeys.Notch.alertsEnabled)
                Text(
                    "Drops a brief card from the notch. Alerts that arrive while the notch is open queue up and show after it closes."
                )
                .settingsCaption()
                if boolValue(AppStorageKeys.Notch.alertsEnabled) {
                    preference("Audio output changes", AppStorageKeys.Notch.alertAudio)
                    preference("Power plugged / unplugged", AppStorageKeys.Notch.alertPower)
                    preference("Battery low", AppStorageKeys.Notch.alertBattery)
                    preference(
                        "Bluetooth connect / disconnect", AppStorageKeys.Notch.alertBluetooth)
                    if boolValue(AppStorageKeys.Notch.alertBluetooth),
                        model.snapshot.bluetoothPrivacyRequired == true
                    {
                        Button("Open Bluetooth Privacy Settings...") {
                            model.perform("notch.bluetooth.settings")
                        }
                    }
                }
                preference("Per-app volume mixer (beta)", AppStorageKeys.Notch.audioMixerEnabled)
                    .disabled(
                        !audioMixerAvailable && !boolValue(AppStorageKeys.Notch.audioMixerEnabled))
                if audioMixerAvailable {
                    Text(
                        "Adds an Audio tab to set each app's volume. macOS asks for application audio access the first time. Off by default."
                    )
                    .settingsCaption()
                } else {
                    Text("Unavailable on this macOS version. Requires macOS 14.4 or later.")
                        .settingsCaption()
                }
                preference("Show on external displays", AppStorageKeys.Notch.shelfShowOnExternal)
                Text("Draws a small pill at the top of screens without a notch.")
                    .settingsCaption()
                preference("Haptic feedback", AppStorageKeys.Notch.shelfHaptics)
                Text("A small trackpad tap when the shelf reacts.")
                    .settingsCaption()
            }
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.5)
        }
        .edithForm()
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

    private func preference(_ title: String, _ key: String) -> some View {
        Toggle(title, isOn: boolBinding(key))
    }
}
