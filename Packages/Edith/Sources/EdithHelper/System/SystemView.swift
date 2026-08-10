import EdithKit
import SwiftUI

struct SystemView: View {
    @Environment(SystemStore.self) private var store
    @AppStorage(AppStorageKeys.General.theme, store: SharedDefaults.store) private var themeName =
        "accent"

    private var theme: Color { themeColor(themeName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 12) {
                eyebrow("POWER")
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Prevent sleep")
                            .font(.system(size: 13))
                        Text("Keeps the display awake; closing the lid still sleeps")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.preventingSleep },
                            set: { store.setPreventSleep($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(theme)
                    .pointerCursor()
                }
            }
            .card()

            VStack(alignment: .leading, spacing: 12) {
                eyebrow("KEYBOARD")
                Text(
                    "Blocks every key - letters, shortcuts, volume, brightness - so you can wipe the keyboard. The trackpad stays live; exit with the Done button or the 60s auto-restore."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !store.hasInputMonitoring || !store.hasAccessibility {
                    permissionRow(
                        "Input monitoring", granted: store.hasInputMonitoring,
                        grant: { store.requestInputMonitoring() })
                    permissionRow(
                        "Accessibility", granted: store.hasAccessibility,
                        grant: { store.requestAccessibility() })
                    HStack(spacing: 6) {
                        Text(
                            "Grant opens System Settings - flip Edith on there and this updates by itself. Still showing Grant after enabling?"
                        )
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        Button("Relaunch") { store.relaunch() }
                            .buttonStyle(HoverButtonStyle())
                            .font(.system(size: 11))
                            .foregroundStyle(theme)
                            .help("macOS applies fresh grants only to a fresh process")
                    }
                    .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
                        store.refreshPermissions()
                    }
                } else {
                    Button {
                        store.beginCleaning()
                    } label: {
                        Label("Clean keyboard", systemImage: "keyboard")
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(HoverButtonStyle())
                    .foregroundStyle(theme)
                    .disabled(store.phase != .idle)
                    .help("3-second countdown, then the keyboard locks until Done")
                }
            }
            .card()
        }
        .onAppear { store.refreshPermissions() }
    }

    private func permissionRow(
        _ name: String, granted: Bool, grant: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 12))
                .foregroundStyle(granted ? .green : .secondary)
            Text(name)
                .font(.system(size: 12))
            Spacer()
            if !granted {
                Button("Grant…") { grant() }
                    .buttonStyle(HoverButtonStyle())
                    .font(.system(size: 11))
                    .foregroundStyle(theme)
                    .help("Opens System Settings on the right pane")
            }
        }
    }
}
