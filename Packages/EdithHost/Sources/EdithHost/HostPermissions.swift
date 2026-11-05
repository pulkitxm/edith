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
                case .fullDisk, .applicationAudio, .bluetooth, .automation: break
                }
            }, openSettings: { NSWorkspace.shared.open($0) })
    }
}

@MainActor @Observable final class HostPermissions {
    static let awaitingRelaunchKey = "permissionsAwaitingRelaunch"
    private(set) var granted: [HostPermission: Bool] = [:]
    private(set) var requesting: HostPermission?
    private(set) var awaitingRelaunch: Set<HostPermission>
    private let environment: HostPermissionEnvironment
    private var revision = 0
    private let recordPrompt: @MainActor () -> Void
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let relaunchApplication: @MainActor () -> Void
    init(
        environment: HostPermissionEnvironment = .live,
        defaults: UserDefaults = SharedDefaults.store,
        recordPrompt: @escaping @MainActor () -> Void = { HostPermissionPromptTracker.record() },
        relaunch: @escaping @MainActor () -> Void = { HostApplicationRelaunch.perform() }
    ) {
        self.environment = environment
        self.defaults = defaults
        self.recordPrompt = recordPrompt
        relaunchApplication = relaunch
        awaitingRelaunch = Self.stored(in: defaults)
    }

    private static func stored(in defaults: UserDefaults) -> Set<HostPermission> {
        Set(
            (defaults.stringArray(forKey: awaitingRelaunchKey) ?? [])
                .compactMap(HostPermission.init(rawValue:)).filter(\.needsRelaunch))
    }

    func refresh() async {
        revision += 1
        let current = revision
        let status = await environment.read()
        guard !Task.isCancelled, revision == current else { return }
        granted = status
        let stored = Self.stored(in: defaults)
        let remaining = stored.filter { status[$0] != true }
        if remaining != stored {
            setAwaitingRelaunch(remaining)
        } else if stored != awaitingRelaunch {
            awaitingRelaunch = stored
        }
    }

    func watch(interval: Duration = .seconds(1), while active: @MainActor () -> Bool = { true })
        async
    {
        while !Task.isCancelled, active() {
            await refresh()
            try? await Task.sleep(for: interval)
        }
    }

    func request(_ permission: HostPermission) async {
        guard !permission.grantsOnFirstUse, requesting == nil else { return }
        requesting = permission
        defer { requesting = nil }
        recordPrompt()
        await environment.request(permission)
        guard !Task.isCancelled else { return }
        markAwaitingRelaunch(permission)
        await refresh()
        guard !Task.isCancelled, granted[permission] != true,
            let settings = permission.settingsURL
        else { return }
        _ = environment.openSettings(settings)
    }

    func openSettings(_ permission: HostPermission) -> Bool {
        guard let url = permission.settingsURL else { return false }
        markAwaitingRelaunch(permission)
        return environment.openSettings(url)
    }

    func relaunch() {
        setAwaitingRelaunch([])
        defaults.synchronize()
        relaunchApplication()
    }

    func usages(entries: [HostExtension], activeIDs: Set<String>) -> [HostPermissionUsage] {
        HostPermissionCatalog.usages(entries: entries, activeIDs: activeIDs, granted: granted)
    }

    private func markAwaitingRelaunch(_ permission: HostPermission) {
        guard permission.needsRelaunch, granted[permission] != true else { return }
        setAwaitingRelaunch(awaitingRelaunch.union([permission]))
    }

    private func setAwaitingRelaunch(_ value: Set<HostPermission>) {
        awaitingRelaunch = value
        defaults.set(value.map(\.rawValue).sorted(), forKey: Self.awaitingRelaunchKey)
    }
}
