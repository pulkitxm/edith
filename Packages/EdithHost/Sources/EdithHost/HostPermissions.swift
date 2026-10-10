import AppKit
import AVFoundation
import EdithExtensionSupport
import EdithHostCore
import EventKit
import IOKit.hid
import Observation
import UserNotifications

@MainActor struct HostPermissionEnvironment {
    let read: () async -> [HostPermission: Bool]
    let request: (HostPermission) async -> Void
    let openSettings: (URL) -> Bool

    static var live: Self {
        Self(
            read: {
                let notifications = await UNUserNotificationCenter.current().notificationSettings()
                let home =
                    ProcessInfo.processInfo.environment["EDITH_EXTENSION_FIXTURE_HOME"].map {
                        URL(fileURLWithPath: $0)
                    }
                    ?? FileManager.default.homeDirectoryForCurrentUser
                let fullDiskProbe = home.appendingPathComponent(
                    "Library/Application Support/com.apple.TCC/TCC.db")
                return [
                    .calendar: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                    .notifications: notifications.authorizationStatus == .authorized
                        || notifications.authorizationStatus == .provisional,
                    .accessibility: AXIsProcessTrusted(),
                    .inputMonitoring: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
                        == kIOHIDAccessTypeGranted,
                    .fullDisk: FileManager.default.isReadableFile(atPath: fullDiskProbe.path),
                    .screenRecording: CGPreflightScreenCaptureAccess(),
                    .camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
                ]
            },
            request: { permission in
                switch permission {
                case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
                case .notifications:
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(
                        options: [.alert, .sound, .badge])
                case .accessibility:
                    _ = AXIsProcessTrustedWithOptions(
                        ["AXTrustedCheckOptionPrompt": true]
                            as CFDictionary)
                case .inputMonitoring: _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                case .screenRecording: _ = CGRequestScreenCaptureAccess()
                case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
                case .fullDisk: break
                case .applicationAudio, .bluetooth, .automation: return
                }
                if let settings = permission.settingsURL { NSWorkspace.shared.open(settings) }
            }, openSettings: { NSWorkspace.shared.open($0) })
    }
}

@MainActor @Observable final class HostPermissions {
    private(set) var granted: [HostPermission: Bool] = [:]
    private(set) var requesting: HostPermission?
    private let environment: HostPermissionEnvironment
    private var revision = 0
    init(environment: HostPermissionEnvironment = .live) { self.environment = environment }

    func refresh() async {
        revision += 1
        let current = revision
        let status = await environment.read()
        guard !Task.isCancelled, revision == current else { return }
        granted = status
    }
    func request(_ permission: HostPermission) async {
        guard !permission.grantsOnFirstUse, requesting == nil else { return }
        requesting = permission
        defer { requesting = nil }
        await environment.request(permission)
        guard !Task.isCancelled else { return }
        await refresh()
    }
    func openSettings(_ permission: HostPermission) -> Bool {
        permission.settingsURL.map(environment.openSettings) ?? false
    }
    func usages(entries: [HostExtension], activeIDs: Set<String>) -> [HostPermissionUsage] {
        HostPermissionCatalog.usages(entries: entries, activeIDs: activeIDs, granted: granted)
    }
}
