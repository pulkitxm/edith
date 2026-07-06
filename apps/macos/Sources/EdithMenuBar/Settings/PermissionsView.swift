import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import EventKit
import SwiftUI
import UserNotifications

@MainActor
final class PermissionsModel: ObservableObject {
    static let shared = PermissionsModel()

    @Published private(set) var calendar = false
    @Published private(set) var notifications = false
    @Published private(set) var accessibility = false
    @Published private(set) var inputMonitoring = false
    @Published private(set) var fullDisk = false

    private let eventStore = EKEventStore()
    private var ipcTokens: [NSObjectProtocol] = []

    func startIPCBridge() {
        guard ipcTokens.isEmpty else { return }
        ipcTokens = [
            IPC.observe(IPC.Name.requestPermissionsRefresh) { [weak self] in self?.refresh() },
            IPC.observe(IPC.Name.grantCalendar) { [weak self] in self?.grantCalendar() },
            IPC.observe(IPC.Name.grantNotifications) { [weak self] in
                self?.grantNotifications()
            },
            IPC.observe(IPC.Name.grantAccessibility) { [weak self] in
                self?.grantAccessibility()
            },
            IPC.observe(IPC.Name.grantInputMonitoring) { [weak self] in
                self?.grantInputMonitoring()
            },
            IPC.observe(IPC.Name.grantFullDisk) { [weak self] in self?.grantFullDisk() },
        ]
    }

    func refresh() {
        calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        fullDisk = Self.hasFullDiskAccess()
        mirrorToSharedDefaults()
        Task { @MainActor in
            let status = await UNUserNotificationCenter.current()
                .notificationSettings().authorizationStatus
            notifications = status == .authorized || status == .provisional
            mirrorToSharedDefaults()
        }
    }

    private func mirrorToSharedDefaults() {
        let d = SharedDefaults.store
        d.set(calendar, forKey: "permCalendarGranted")
        d.set(notifications, forKey: "permNotificationsGranted")
        d.set(accessibility, forKey: "permAccessibilityGranted")
        d.set(inputMonitoring, forKey: "permInputMonitoringGranted")
        d.set(fullDisk, forKey: "permFullDiskGranted")
    }

    var needsAttention: Bool {
        let d = SharedDefaults.store
        func on(_ key: String) -> Bool { d.object(forKey: key) as? Bool ?? true }
        return PermissionsStatus.needsAttention(
            calendarTab: on("tabCalendarEnabled"), systemTab: on("tabSystemEnabled"),
            notifyMaster: d.bool(forKey: "notifyMaster"),
            calendar: calendar, accessibility: accessibility,
            inputMonitoring: inputMonitoring, notifications: notifications)
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
