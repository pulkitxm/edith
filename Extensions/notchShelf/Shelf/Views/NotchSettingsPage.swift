import EdithExtensionSupport
import EdithExtensionUI
import SwiftUI

struct NotchSettingsPage: View {
    let controller: NotchShelfController

    var body: some View {
        PageScaffold {
            PageHeader("Notch Shelf")
        } content: {
            VStack(alignment: .leading, spacing: UIScale.pt(16)) {
                PageSectionHeader("Shelf")
                preference("Open on hover", AppStorageKeys.Notch.shelfOpenOnHover, fallback: true)
                preference(
                    "Open when dragging", AppStorageKeys.Notch.shelfOpenOnDrag, fallback: true)
                preference(
                    "Show on external displays", AppStorageKeys.Notch.shelfShowOnExternal,
                    fallback: true)
                preference(
                    "Remove files after dragging out", AppStorageKeys.Notch.shelfRemoveAfterDragOut,
                    fallback: true)
                preference(
                    "Require Option", AppStorageKeys.Notch.shelfRequireOption, fallback: false)
                preference("Haptic feedback", AppStorageKeys.Notch.shelfHaptics, fallback: true)
                Picker(
                    "Keep files for",
                    selection: stringPreference(
                        AppStorageKeys.Notch.shelfKeepDuration, fallback: "forever")
                ) {
                    Text("Forever").tag("forever")
                    Text("1 hour").tag("oneHour")
                    Text("1 day").tag("oneDay")
                    Text("1 week").tag("oneWeek")
                    Text("1 month").tag("oneMonth")
                }
                PageSectionHeader("Browser and alerts")
                preference("Notch browser", AppStorageKeys.Notch.browserEnabled, fallback: false)
                Picker(
                    "Search with",
                    selection: stringPreference(
                        AppStorageKeys.Notch.browserSearchEngine,
                        fallback: BrowserSearchEngine.fallback.rawValue)
                ) {
                    ForEach(BrowserSearchEngine.allCases, id: \.rawValue) { engine in
                        Text(engine.title).tag(engine.rawValue)
                    }
                }
                preference("System alerts", AppStorageKeys.Notch.alertsEnabled, fallback: true)
                preference("Audio output alerts", AppStorageKeys.Notch.alertAudio, fallback: true)
                preference("Power alerts", AppStorageKeys.Notch.alertPower, fallback: true)
                preference("Low battery alerts", AppStorageKeys.Notch.alertBattery, fallback: true)
                preference("Bluetooth alerts", AppStorageKeys.Notch.alertBluetooth, fallback: false)
                Button("Customize widgets, tabs and glances") { controller.openCustomization() }
                    .buttonStyle(.edith(.secondary))
                Text(
                    "Only enabled extensions contribute widgets and provider tabs. Browser and camera preview belong to Notch Shelf."
                )
                .font(.edithText(.callout)).foregroundStyle(.secondary)
            }
        }
    }

    private func stringPreference(_ key: String, fallback: String) -> Binding<String> {
        Binding(
            get: {
                _ = controller.activeIDs
                return controller.context.defaults.string(forKey: key) ?? fallback
            },
            set: { value in
                controller.context.defaults.set(value, forKey: key)
                controller.synchronize()
            })
    }

    private func preference(_ title: String, _ key: String, fallback: Bool) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: {
                    _ = controller.activeIDs
                    return controller.context.defaults.object(forKey: key) as? Bool ?? fallback
                },
                set: { value in
                    controller.context.defaults.set(value, forKey: key)
                    controller.synchronize()
                    controller.rebuildPanels()
                })
        ).toggleStyle(.switch)
    }
}
