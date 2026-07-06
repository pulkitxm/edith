import EdithKit
import SwiftUI

private struct MainPermission: Identifiable {
    let id: String
    let name: String
    let icon: String
    let usedFor: String
    let key: String
    let request: Notification.Name
}

private let permissions: [MainPermission] = [
    MainPermission(
        id: "calendar", name: "Calendar", icon: "calendar",
        usedFor: "Showing today's events in the Calendar module.",
        key: "permCalendarGranted", request: IPC.Name.grantCalendar),
    MainPermission(
        id: "notifications", name: "Notifications", icon: "bell.badge",
        usedFor: "Limit, pacing, and reset alerts in Usage.",
        key: "permNotificationsGranted", request: IPC.Name.grantNotifications),
    MainPermission(
        id: "accessibility", name: "Accessibility", icon: "figure.wave",
        usedFor: "Blocking keys during keyboard cleaning in System.",
        key: "permAccessibilityGranted", request: IPC.Name.grantAccessibility),
    MainPermission(
        id: "input", name: "Input Monitoring", icon: "keyboard",
        usedFor: "Detecting key presses while cleaning the keyboard in System.",
        key: "permInputMonitoringGranted", request: IPC.Name.grantInputMonitoring),
    MainPermission(
        id: "disk", name: "Full Disk Access", icon: "externaldrive",
        usedFor: "Optional - reads your Claude credentials and usage data for the dashboard.",
        key: "permFullDiskGranted", request: IPC.Name.grantFullDisk),
    MainPermission(
        id: "screenRecording", name: "Screen Recording",
        icon: "rectangle.inset.filled.badge.record",
        usedFor: "Optional - reads window titles for auto presenter mode.",
        key: "permScreenRecordingGranted", request: IPC.Name.grantScreenRecording),
]

struct MainPermissionsPane: View {
    @State private var granted: [String: Bool] = [:]
    @State private var refreshTimer: Timer?

    var body: some View {
        Form {
            Section {
                Text(
                    "These are all held by Edith's menu bar helper, the process that actually uses them. Grant opens System Settings - flip Edith on there and this updates on its own."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                ForEach(permissions) { permission in
                    row(permission)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Permissions")
        .onAppear {
            IPC.post(IPC.Name.requestPermissionsRefresh)
            refresh()
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                IPC.post(IPC.Name.requestPermissionsRefresh)
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear {
            refreshTimer?.invalidate()
            refreshTimer = nil
        }
    }

    private func refresh() {
        for permission in permissions {
            granted[permission.key] = SharedDefaults.store.bool(forKey: permission.key)
        }
    }

    private func row(_ permission: MainPermission) -> some View {
        let isGranted = granted[permission.key] ?? false
        return LabeledContent {
            if isGranted {
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Grant…") { IPC.post(permission.request) }
                    .pointerCursor()
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: permission.icon)
                    .foregroundStyle(isGranted ? .primary : .secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(permission.name)
                    Text(permission.usedFor)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
