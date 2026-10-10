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

    var body: some View {
        PageScaffold {
            PageHeader("Notch Shelf")
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                if let error = model.error {
                    Text(error).font(.edithText(.callout)).foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.refresh() } }.buttonStyle(
                        .edith(.secondary))
                }
                if !model.available {
                    Text("Enable Notch Shelf to configure its running engine.").font(
                        .edithText(.callout))
                }
                settings.disabled(!model.available || model.busy)
            }
        }.pageTask { await model.refresh() }
    }

    private var settings: some View {
        VStack(alignment: .leading, spacing: UIScale.pt(16)) {
            PageSectionHeader("Layout")
            Button("Customize Home & Notch") { model.perform("notch.customize") }
                .buttonStyle(.edith(.secondary))
            caption("Arrange widgets, resize cards, and configure your Notch in the visual editor.")
            PageSectionHeader("Shelf")
            preference("Open when dragging near the notch", AppStorageKeys.Notch.shelfOpenOnDrag)
            caption("The island slides out mid-drag so you can drop without clicking first.")
            preference("Open on hover", AppStorageKeys.Notch.shelfOpenOnHover)
            caption("Expand when the mouse rests on the notch, without a drag.")
            preference("Require ⌥ to trigger", AppStorageKeys.Notch.shelfRequireOption)
            caption(
                "Only expand while holding Option. Keeps accidental passes over the notch from opening it."
            )
            Picker(
                "Keep items for",
                selection: stringPreference(AppStorageKeys.Notch.shelfKeepDuration)
            ) {
                Text("Forever").tag("forever")
                Text("1 hour").tag("oneHour")
                Text("1 day").tag("oneDay")
                Text("1 week").tag("oneWeek")
                Text("1 month").tag("oneMonth")
            }
            caption(
                "Parked files auto-delete after this long. They are copies, originals are never touched."
            )
            preference("Remove after dragging out", AppStorageKeys.Notch.shelfRemoveAfterDragOut)
            caption("Treats the shelf as a hand-off tray rather than storage.")
            PageSectionHeader("Browser")
            preference("Browser tab", AppStorageKeys.Notch.browserEnabled)
            caption(
                "A tabbed WebKit browser in the shelf, signed in with one of your Google Chrome profiles. Cookies and site storage are copied into a private store on this Mac and resync every few minutes while you browse."
            )
            if boolValue(AppStorageKeys.Notch.browserEnabled) {
                Picker(
                    "Search with",
                    selection: stringPreference(AppStorageKeys.Notch.browserSearchEngine)
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
                    caption(
                        model.snapshot.browserProfile == nil
                            ? "Open the shelf's browser tab to pick a profile."
                            : "Cookies and site storage copied from Chrome stay on this Mac.")
                }
            }
            PageSectionHeader("Glances and alerts")
            preference("Show what's playing", AppStorageKeys.Notch.shelfShowMusic)
            caption(
                "Album art and a live equalizer hug the notch while music plays in the library, Spotify, or Apple Music."
            )
            preference("Notch alerts", AppStorageKeys.Notch.alertsEnabled)
            caption(
                "Drops a brief card from the notch. Alerts that arrive while the notch is open queue up and show after it closes."
            )
            if boolValue(AppStorageKeys.Notch.alertsEnabled) {
                preference("Audio output changes", AppStorageKeys.Notch.alertAudio)
                preference("Power plugged / unplugged", AppStorageKeys.Notch.alertPower)
                preference("Battery low", AppStorageKeys.Notch.alertBattery)
                preference("Bluetooth connect / disconnect", AppStorageKeys.Notch.alertBluetooth)
                if boolValue(AppStorageKeys.Notch.alertBluetooth),
                    model.snapshot.bluetoothPrivacyRequired == true
                {
                    Button("Open Bluetooth Privacy Settings...") {
                        model.perform("notch.bluetooth.settings")
                    }
                    .buttonStyle(.edith(.secondary))
                }
            }
            preference("Show on external displays", AppStorageKeys.Notch.shelfShowOnExternal)
            caption("Draws a small pill at the top of screens without a notch.")
            preference("Haptic feedback", AppStorageKeys.Notch.shelfHaptics)
            caption("A small trackpad tap when the shelf reacts.")
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.edithText(.caption)).foregroundStyle(.secondary)
    }

    private func boolValue(_ key: String) -> Bool { model.snapshot.preferences[key] == "1" }

    private func stringPreference(_ key: String) -> Binding<String> {
        Binding(
            get: { model.snapshot.preferences[key] ?? NotchSettingsSchema.defaults[key] ?? "" },
            set: { model.set(key, value: $0) })
    }

    private func preference(_ title: String, _ key: String) -> some View {
        Toggle(
            title,
            isOn: Binding(get: { boolValue(key) }, set: { model.set(key, value: $0 ? "1" : "0") })
        )
        .toggleStyle(.switch)
    }
}
