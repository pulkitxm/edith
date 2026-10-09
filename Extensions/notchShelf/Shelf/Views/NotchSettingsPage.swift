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
                PageSectionHeader("Browser and alerts")
                preference("Notch browser", AppStorageKeys.Notch.browserEnabled, fallback: false)
                preference("System alerts", AppStorageKeys.Notch.alertsEnabled, fallback: true)
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
