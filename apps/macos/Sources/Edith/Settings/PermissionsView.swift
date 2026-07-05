import AppKit
import ApplicationServices
import CoreGraphics
import EventKit
import SwiftUI
import UserNotifications

@MainActor
final class PermissionsModel: ObservableObject {
    @Published private(set) var calendar = false
    @Published private(set) var notifications = false
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var fullDisk = false

    private let eventStore = EKEventStore()

    func refresh() {
        calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        fullDisk = Self.hasFullDiskAccess()
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            notifications = status == .authorized || status == .provisional
        }
    }

    var needsAttention: Bool {
        let d = UserDefaults.standard
        func on(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        return Self.needsAttention(
            calendarTab: on("tabCalendarEnabled"), systemTab: on("tabSystemEnabled"),
            notifyMaster: d.bool(forKey: "notifyMaster"),
            calendar: calendar, accessibility: accessibility,
            inputMonitoring: inputMonitoring, notifications: notifications)
    }

    nonisolated static func needsAttention(
        calendarTab: Bool, systemTab: Bool, notifyMaster: Bool,
        calendar: Bool, accessibility: Bool, inputMonitoring: Bool, notifications: Bool
    ) -> Bool {
        if calendarTab, !calendar { return true }
        if systemTab, !accessibility || !inputMonitoring { return true }
        if notifyMaster, !notifications { return true }
        return false
    }

    func grantCalendar() {
        Task { @MainActor in
            _ = try? await eventStore.requestFullAccessToEvents()
            refresh()
        }
        openSecuritySettings("Privacy_Calendars")
    }

    func grantNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
            Task { @MainActor in self.refresh() }
        }
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.notifications")!)
    }

    func grantAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        openSecuritySettings("Privacy_Accessibility")
    }

    func grantInputMonitoring() {
        CGRequestListenEventAccess()
        openSecuritySettings("Privacy_ListenEvent")
    }

    func grantFullDisk() {
        openSecuritySettings("Privacy_AllFiles")
    }

    private func openSecuritySettings(_ anchor: String) {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!)
    }

    static func hasFullDiskAccess() -> Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tcc) else { return false }
        try? handle.close()
        return true
    }
}

struct PermissionsView: View {
    @ObservedObject var model: PermissionsModel
    @AppStorage("theme") private var themeName = "accent"

    private var theme: Color { themeColor(themeName) }

    private struct Permission: Identifiable {
        let id: String
        let name: String
        let icon: String
        let detail: String
        let granted: Bool
        let required: Bool
        let grant: () -> Void
    }

    private var permissions: [Permission] {
        [
            Permission(
                id: "calendar", name: "Calendar", icon: "calendar",
                detail: "Shows today's events in the Calendar tab.",
                granted: model.calendar, required: true, grant: model.grantCalendar),
            Permission(
                id: "notifications", name: "Notifications", icon: "bell.badge",
                detail: "Limit, pacing, and reset alerts for Agent Usage.",
                granted: model.notifications, required: true, grant: model.grantNotifications),
            Permission(
                id: "accessibility", name: "Accessibility", icon: "figure.wave",
                detail: "Blocks keys during keyboard cleaning in the System tab.",
                granted: model.accessibility, required: true, grant: model.grantAccessibility),
            Permission(
                id: "input", name: "Input Monitoring", icon: "keyboard",
                detail: "Detects key presses while cleaning the keyboard.",
                granted: model.inputMonitoring, required: true, grant: model.grantInputMonitoring),
            Permission(
                id: "disk", name: "Full Disk Access", icon: "externaldrive",
                detail: "Reads your Claude credentials and usage data and writes the dashboard.",
                granted: model.fullDisk, required: false, grant: model.grantFullDisk),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                eyebrow("PERMISSIONS")
                Text(
                    "Edith asks for these as you use its features. Grant opens System Settings — flip Edith on there and this list updates on its own."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .card()

            VStack(alignment: .leading, spacing: 14) {
                ForEach(permissions) { permission in
                    row(permission)
                }
            }
            .card()
        }
        .onAppear { model.refresh() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
    }

    private func row(_ permission: Permission) -> some View {
        HStack(spacing: 11) {
            Image(systemName: permission.icon)
                .font(.system(size: 14))
                .foregroundStyle(
                    permission.granted ? AnyShapeStyle(theme) : AnyShapeStyle(.secondary)
                )
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.name).font(.system(size: 13))
                Text(permission.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if permission.granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.green)
                    Text("Granted").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .trailing, spacing: 2) {
                    Button("Grant…") { permission.grant() }
                        .buttonStyle(HoverButtonStyle())
                        .font(.system(size: 11))
                        .foregroundStyle(theme)
                    if !permission.required {
                        Text("Optional").font(.system(size: 9)).foregroundStyle(.tertiary)
                    }
                }
            }
        }
    }
}
