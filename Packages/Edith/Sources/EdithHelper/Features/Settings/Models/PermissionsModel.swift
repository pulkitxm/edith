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
    private(set) var refreshError: String?

    struct Snapshot: Sendable {
        let notifications: Bool
        let accessibility: Bool
        let inputMonitoring: Bool
        let fullDisk: Bool
        let screenRecording: Bool
        let camera: Bool
    }

    typealias PlatformRequest =
        @MainActor (
            ExtensionPermission, @escaping @Sendable () -> Void
        ) -> Bool

    private let readStatus: @Sendable () async throws -> Snapshot
    private let requestPlatform: PlatformRequest
    private let defaults: UserDefaults
    private let publishChange: @MainActor () -> Void
    private let openSettingsURL: @MainActor (URL) -> Bool
    private let recordPrompt: @MainActor () -> Void
    private let delay: @Sendable (Duration) async throws -> Void
    private var stopped = false
    private var generation = 0
    private var refreshVersion = 0
    private var refreshPending = false
    private var refreshWorkerID: UUID?
    private var followUpID: UUID?
    private var grants: [ExtensionPermission: UUID] = [:]
    private var lastRefreshAt = Date.distantPast
    @ObservationIgnored nonisolated(unsafe) private var refreshTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var followUpTask: Task<Void, Never>?
    @ObservationIgnored nonisolated(unsafe) private var ipcTokens: [NSObjectProtocol] = []
    @ObservationIgnored nonisolated(unsafe) private var activeToken: NSObjectProtocol?

    init(
        readStatus: @escaping @Sendable () async throws -> Snapshot = {
            try await PermissionsModel.readNativeStatus()
        },
        requestPlatform: @escaping PlatformRequest = {
            PermissionsModel.requestNative($0, completion: $1)
        },
        defaults: UserDefaults = SharedDefaults.store,
        publishChange: @escaping @MainActor () -> Void = {
            IPC.post(IPC.Name.permissionsRefreshed)
        },
        openSettings: @escaping @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) },
        recordPrompt: @escaping @MainActor () -> Void = { PermissionPromptTracker.record() },
        delay: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.readStatus = readStatus
        self.requestPlatform = requestPlatform
        self.defaults = defaults
        self.publishChange = publishChange
        self.openSettingsURL = openSettings
        self.recordPrompt = recordPrompt
        self.delay = delay
    }

    deinit {
        refreshTask?.cancel()
        followUpTask?.cancel()
        for token in ipcTokens { IPC.stopObserving(token) }
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
    }

    func startIPCBridge() {
        guard ipcTokens.isEmpty else { return }
        stopped = false
        generation &+= 1
        let grantTokens = ExtensionPermission.allCases.compactMap { permission in
            permission.grantRequest.map { request in
                IPC.observe(request) { [weak self] in self?.request(permission) }
            }
        }
        activeToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        ipcTokens =
            [IPC.observe(IPC.Name.requestPermissionsRefresh) { [weak self] in self?.refresh() }]
            + grantTokens
    }

    func shutdown() {
        stopped = true
        generation &+= 1
        refreshVersion &+= 1
        refreshPending = false
        refreshTask?.cancel()
        followUpTask?.cancel()
        for token in ipcTokens { IPC.stopObserving(token) }
        ipcTokens.removeAll()
        if let activeToken { NotificationCenter.default.removeObserver(activeToken) }
        activeToken = nil
    }

    func waitForRefresh() async {
        while let task = refreshTask { await task.value }
    }

    func waitForShutdown() async {
        await waitForRefresh()
        await followUpTask?.value
    }

    var pendingGrantCount: Int { grants.count }

    func request(_ permission: ExtensionPermission) { _ = try? operations.request(permission) }
    func openSettings(for permission: ExtensionPermission) {
        _ = try? operations.openSettings(for: permission)
    }

    private var operations: PermissionOperationCenter {
        PermissionOperationCenter(
            environment: PermissionOperationEnvironment(
                defaults: defaults,
                requestPermission: { [weak self] in self?.performRequest($0) ?? false },
                refreshStatus: { [weak self] in self?.refresh(force: true) },
                openSettings: { [weak self] in self?.openSettingsURL($0) ?? false },
                recordPrompt: { [weak self] in self?.recordPrompt() }))
    }

    private func performRequest(_ permission: ExtensionPermission) -> Bool {
        guard !stopped, grants[permission] == nil, permission.grantRequest != nil else {
            return false
        }
        let id = UUID()
        let generation = generation
        grants[permission] = id
        return requestPlatform(permission) { [weak self] in
            Task { @MainActor [weak self] in
                self?.grantFinished(permission, id: id, generation: generation)
            }
        }
    }

    private func grantFinished(_ permission: ExtensionPermission, id: UUID, generation: Int) {
        guard grants[permission] == id else { return }
        grants[permission] = nil
        guard !stopped, self.generation == generation else { return }
        refreshAfterGrant()
    }

    func refresh(force: Bool = false) {
        guard !stopped else { return }
        guard force || Date().timeIntervalSince(lastRefreshAt) >= 2 else { return }
        lastRefreshAt = Date()
        refreshVersion &+= 1
        refreshPending = true
        kickRefresh()
    }

    private func kickRefresh() {
        guard !stopped, refreshPending else { return }
        guard refreshTask == nil else { return }
        let id = UUID()
        refreshWorkerID = id
        let readStatus = readStatus
        refreshTask = Task { [weak self] in
            defer { self?.refreshFinished(id) }
            while !Task.isCancelled {
                guard let version = self?.nextRefresh() else { return }
                do {
                    let snapshot = try await readStatus()
                    guard !Task.isCancelled else { return }
                    self?.apply(snapshot, version: version)
                } catch {
                    guard !Task.isCancelled else { return }
                    guard let self, self.refreshVersion == version else { continue }
                    self.refreshError = error.localizedDescription
                }
            }
        }
    }

    private func nextRefresh() -> Int? {
        guard !stopped, refreshPending else { return nil }
        refreshPending = false
        return refreshVersion
    }

    private func refreshFinished(_ id: UUID) {
        guard refreshWorkerID == id else { return }
        refreshWorkerID = nil
        refreshTask = nil
        kickRefresh()
    }

    private func apply(_ snapshot: Snapshot, version: Int) {
        guard !stopped, refreshVersion == version else { return }
        notifications = snapshot.notifications
        accessibility = snapshot.accessibility
        inputMonitoring = snapshot.inputMonitoring
        fullDisk = snapshot.fullDisk
        screenRecording = snapshot.screenRecording
        camera = snapshot.camera
        refreshError = nil
        let values = [
            (notifications, AppStorageKeys.Permissions.notificationsGranted),
            (accessibility, AppStorageKeys.Permissions.accessibilityGranted),
            (inputMonitoring, AppStorageKeys.Permissions.inputMonitoringGranted),
            (fullDisk, AppStorageKeys.Permissions.fullDiskGranted),
            (screenRecording, AppStorageKeys.Permissions.screenRecordingGranted),
            (camera, AppStorageKeys.Permissions.cameraGranted),
        ]
        var changed = false
        for (value, key) in values where defaults.object(forKey: key) as? Bool != value {
            defaults.set(value, forKey: key)
            changed = true
        }
        if changed { publishChange() }
    }

    var needsAttention: Bool { PermissionsStatus.current }

    private func refreshAfterGrant() {
        refresh(force: true)
        followUpTask?.cancel()
        let id = UUID()
        let generation = generation
        followUpID = id
        let delay = delay
        followUpTask = Task { [weak self] in
            defer { self?.followUpFinished(id) }
            for duration in [Duration.milliseconds(500), .milliseconds(1500)] {
                do { try await delay(duration) } catch { return }
                guard !Task.isCancelled, let self, !self.stopped,
                    self.generation == generation
                else { return }
                self.refresh(force: true)
            }
        }
    }

    private func followUpFinished(_ id: UUID) {
        guard followUpID == id else { return }
        followUpID = nil
        followUpTask = nil
    }

    private static func requestNative(
        _ permission: ExtensionPermission, completion: @escaping @Sendable () -> Void
    ) -> Bool {
        switch permission {
        case .calendar:
            CalendarPermissionGrant().request(completion)
        case .notifications:
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) {
                _, _ in completion()
            }
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
            completion()
        case .inputMonitoring:
            CGRequestListenEventAccess()
            completion()
        case .screenRecording:
            CGRequestScreenCaptureAccess()
            completion()
        case .camera:
            guard AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined else {
                completion()
                return true
            }
            AVCaptureDevice.requestAccess(for: .video) { _ in completion() }
            return false
        case .fullDisk:
            completion()
        case .applicationAudio, .bluetooth, .automation:
            completion()
            return false
        }
        return true
    }

    nonisolated private static func readNativeStatus() async throws -> Snapshot {
        let native = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return Snapshot(
                notifications: false,
                accessibility: AXIsProcessTrusted(),
                inputMonitoring: CGPreflightListenEventAccess(),
                fullDisk: Self.hasFullDiskAccess(),
                screenRecording: CGPreflightScreenCaptureAccess(),
                camera: AVCaptureDevice.authorizationStatus(for: .video) == .authorized)
        }
        let snapshot = try await withTaskCancellationHandler {
            try await native.value
        } onCancel: {
            native.cancel()
        }
        try Task.checkCancellation()
        let status = await UNUserNotificationCenter.current().notificationSettings()
            .authorizationStatus
        try Task.checkCancellation()
        return Snapshot(
            notifications: status == .authorized || status == .provisional,
            accessibility: snapshot.accessibility, inputMonitoring: snapshot.inputMonitoring,
            fullDisk: snapshot.fullDisk, screenRecording: snapshot.screenRecording,
            camera: snapshot.camera)
    }

    nonisolated static func hasFullDiskAccess() -> Bool {
        let tcc = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db")
        guard let handle = try? FileHandle(forReadingFrom: tcc) else { return false }
        try? handle.close()
        return true
    }
}

@MainActor
private final class CalendarPermissionGrant {
    private let store = EKEventStore()

    func request(_ completion: @escaping @Sendable () -> Void) {
        store.requestFullAccessToEvents { [self] _, _ in
            withExtendedLifetime(self) { completion() }
        }
    }
}
