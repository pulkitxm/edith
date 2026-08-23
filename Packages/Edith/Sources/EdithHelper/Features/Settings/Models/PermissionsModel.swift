import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import EdithKit
import EventKit
import SwiftUI
import UserNotifications

@MainActor
@Observable
final class PermissionsModel {
    static let shared = PermissionsModel()

    private(set) var notifications = false
    private(set) var accessibility = false
    private(set) var inputMonitoring = false
    private(set) var fullDisk = false
    private(set) var screenRecording = false
    private(set) var camera = false

    private let eventStore = EKEventStore()
    private var ipcTokens: [NSObjectProtocol] = []

    func startIPCBridge() {
        guard ipcTokens.isEmpty else { return }
        let grantTokens = ExtensionPermission.allCases.compactMap { permission in
            permission.grantRequest.map { request in
                IPC.observe(request) { [weak self] in self?.request(permission) }
            }
        }
        let activeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        ipcTokens =
            [IPC.observe(IPC.Name.requestPermissionsRefresh) { [weak self] in self?.refresh() }]
            + grantTokens + [activeToken]
    }

    func request(_ permission: ExtensionPermission) {
        _ = try? operations.request(permission)
    }

    func openSettings(for permission: ExtensionPermission) {
        _ = try? operations.openSettings(for: permission)
    }

    private var operations: PermissionOperationCenter {
        PermissionOperationCenter(
            environment: PermissionOperationEnvironment(
                defaults: SharedDefaults.store,
                requestPermission: { [weak self] in self?.performRequest($0) ?? false },
                refreshStatus: { [weak self] in self?.refresh() },
                openSettings: { NSWorkspace.shared.open($0) },
                recordPrompt: { PermissionPromptTracker.record() }))
    }

    private func performRequest(_ permission: ExtensionPermission) -> Bool {
        switch permission {
        case .calendar:
            requestCalendar()
            return true
        case .notifications:
            requestNotifications()
            return true
        case .accessibility:
            requestAccessibility()
            return true
        case .inputMonitoring:
            requestInputMonitoring()
            return true
        case .fullDisk:
            return true
        case .screenRecording:
            requestScreenRecording()
            return true
        case .camera:
            return requestCamera()
        case .bluetooth, .automation:
            return false
        }
    }

    func refresh() {
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
        fullDisk = Self.hasFullDiskAccess()
        screenRecording = CGPreflightScreenCaptureAccess()
        camera = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
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
        var changed = false
        func setIfChanged(_ value: Bool, _ key: String) {
            if d.object(forKey: key) as? Bool != value {
                d.set(value, forKey: key)
                changed = true
            }
        }
        setIfChanged(notifications, AppStorageKeys.Permissions.notificationsGranted)
        setIfChanged(accessibility, AppStorageKeys.Permissions.accessibilityGranted)
        setIfChanged(inputMonitoring, AppStorageKeys.Permissions.inputMonitoringGranted)
        setIfChanged(fullDisk, AppStorageKeys.Permissions.fullDiskGranted)
        setIfChanged(screenRecording, AppStorageKeys.Permissions.screenRecordingGranted)
        setIfChanged(camera, AppStorageKeys.Permissions.cameraGranted)
        if changed { IPC.post(IPC.Name.permissionsRefreshed) }
    }

    var needsAttention: Bool { PermissionsStatus.current }

    private func requestCalendar() {
        Task { @MainActor in
            _ = try? await eventStore.requestFullAccessToEvents()
            refresh()
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
            _, _ in
            Task { @MainActor in self.refresh() }
        }
    }

    private func requestAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        refreshAfterGrant()
    }

    private func requestInputMonitoring() {
        CGRequestListenEventAccess()
        refreshAfterGrant()
    }

    private func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        refreshAfterGrant()
    }

    private func requestCamera() -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { _ in
                Task { @MainActor in self.refresh() }
            }
            return false
        default:
            refreshAfterGrant()
            return true
        }
    }

    private func refreshAfterGrant() {
        refresh()
        for delay in [0.5, 2.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.refresh()
            }
        }
    }

    static func hasFullDiskAccess() -> Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tcc) else { return false }
        try? handle.close()
        return true
    }
}
