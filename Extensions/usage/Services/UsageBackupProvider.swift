import EdithExtensionSupport
import Foundation
import IOKit.ps

@MainActor final class UsageBackupProvider {
    private let directory: URL
    private let cloud: URL
    private let defaults: UserDefaults
    private var work: Task<Bool, Never>?
    private var cancellation: UsageBackupCancellation?
    private var restoreToken: UsageBackupRestoreToken?
    private var stopping = false
    private var ownedCancelled = false
    private var events: UsageBackupEventQueue?
    private var observers: [NSObjectProtocol] = []
    private var bootstrapCancelled = false
    private var observedCloudEnabled = false
    private var needsRestore = false
    private let cloudAvailable: () -> Bool
    private let onBattery: () -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var failure: String?

    init(
        directory: URL, cloud: URL, defaults: UserDefaults,
        cloudAvailable: @escaping () -> Bool = { true }, onBattery: @escaping () -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.directory = directory
        self.cloud = cloud
        self.defaults = defaults
        self.cloudAvailable = cloudAvailable
        self.onBattery = onBattery
        self.sleep = sleep
    }

    private static func isOnBattery() -> Bool {
        guard let sources = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return false }
        return IOPSGetProvidingPowerSourceType(sources).takeUnretainedValue() as String
            == kIOPMBatteryPowerKey
    }

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> UsageBackupProvider
    {
        guard let identifier = environment["EDITH_APPLICATION_IDENTIFIER"],
            let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0),
            let defaults = SharedDefaults.applicationStore(identifier: identifier)
        else { throw ExtensionPeerError.unavailable }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let cloud = try cloudDirectory(identifier: identifier, root: root)
        return UsageBackupProvider(
            directory: root.appendingPathComponent("data"), cloud: cloud, defaults: defaults,
            cloudAvailable: {
                identifier != "com.pulkit.edith"
                    || FileManager.default.fileExists(
                        atPath: cloud.deletingLastPathComponent().deletingLastPathComponent().path)
            },
            onBattery: {
                environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil && Self.isOnBattery()
            })
    }

    static func cloudDirectory(
        identifier: String, root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0),
            root.lastPathComponent == "usage",
            root.deletingLastPathComponent().lastPathComponent == "Data",
            identifier == "com.pulkit.edith" || identifier.hasPrefix("com.pulkit.edith.dev.")
                || identifier.hasPrefix("com.pulkit.edith.tests.")
        else { throw ExtensionPeerError.invalidRequest }
        if identifier == "com.pulkit.edith" {
            return home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Edith/data")
        }
        return root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "iCloud/data")
    }

    func execute(_ command: String, payload: Data) async throws -> Data {
        guard !stopping else { throw ExtensionPeerError.unavailable }
        guard payload.count <= 512 else { throw ExtensionPeerError.invalidRequest }
        if !payload.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                object.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
        }
        switch command {
        case "backup.status":
            return try JSONSerialization.data(withJSONObject: [
                "running": work != nil, "scheduled": events?.scheduled ?? false,
                "pausedOnBattery": events?.pausedOnBattery ?? false,
                "failure": failure as Any? ?? NSNull(),
            ])
        case "backup.cancel":
            await events?.cancel()
            await cancel()
            return Data("{\"cancelled\":true}".utf8)
        case "backup.synchronize":
            await events?.cancel()
            return try await exportCurrent()
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    private var cloudEnabled: Bool {
        !stopping && (defaults.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true)
            && cloudAvailable()
    }
    private var exportEnabled: Bool {
        (defaults.object(forKey: AppStorageKeys.Backup.usage) as? Bool ?? true)
            || (defaults.object(forKey: AppStorageKeys.Backup.limits) as? Bool ?? true)
    }

    func restoreOnEnable() async -> Bool {
        guard !stopping else { return false }
        guard cloudEnabled else { return true }
        return await transfer(usage: true, limits: true, export: false)
    }

    func startScheduling(debounce: Duration = .milliseconds(100), restorePending: Bool = false) {
        guard !stopping, events == nil else { return }
        observedCloudEnabled = cloudEnabled
        needsRestore = restorePending && cloudEnabled
        events = UsageBackupEventQueue(
            debounce: debounce, onBattery: onBattery, sleep: sleep,
            enabled: { [weak self] in
                guard let self else { return false }
                return cloudEnabled && (exportEnabled || needsRestore)
            },
            transfer: { [weak self] in
                guard let self, !stopping else { throw CancellationError() }
                if needsRestore {
                    guard await restoreOnEnable() else { throw ExtensionPeerError.unavailable }
                    try Task.checkCancellation()
                    needsRestore = false
                }
                _ = try await exportCurrent()
            })
        for name in [UsageEvents.usageUpdated, UsageEvents.limitsUpdated] {
            observers.append(
                UsageEvents.observe(name) { [weak self] in self?.preferencesChanged() })
        }
        observers.append(
            IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.preferencesChanged() }
            })
        if !bootstrapCancelled { events?.changed() }
    }

    func preferencesChanged() {
        guard !stopping else { return }
        defaults.synchronize()
        let enabled = cloudEnabled
        if enabled && !observedCloudEnabled { needsRestore = true }
        observedCloudEnabled = enabled
        if !enabled {
            ownedCancelled = true
            restoreToken?.invalidate(); cancellation?.cancel(); work?.cancel()
        }
        events?.changed()
    }

    func shutdown() async {
        stopping = true
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        await events?.shutdown()
        events = nil
        await cancel()
    }

    private func exportCurrent() async throws -> Data {
        guard cloudEnabled, exportEnabled else { return Data("{\"enabled\":false}".utf8) }
        let usage = defaults.object(forKey: AppStorageKeys.Backup.usage) as? Bool ?? true
        let limits = defaults.object(forKey: AppStorageKeys.Backup.limits) as? Bool ?? true
        guard await transfer(usage: usage, limits: limits, export: true) else {
            try Task.checkCancellation()
            throw ExtensionPeerError.rejected(
                "Usage backup could not finish. Retry after iCloud has downloaded the files.")
        }
        return Data("{\"synchronized\":true}".utf8)
    }

    private func cancel() async {
        bootstrapCancelled = true
        ownedCancelled = true
        restoreToken?.invalidate()
        cancellation?.cancel()
        work?.cancel()
        _ = await work?.value
    }

    private func transfer(usage: Bool, limits: Bool, export: Bool) async -> Bool {
        guard !stopping, work == nil else { return false }
        ownedCancelled = false
        let cancellation = UsageBackupCancellation()
        let token = UsageBackupRestoreToken()
        self.cancellation = cancellation
        restoreToken = token
        let directory = directory, cloud = cloud
        let work = Task.detached(priority: .utility) {
            UsageBackupCancellation.$current.withValue(cancellation) {
                for (name, enabled) in [("usage.json", usage), ("limits-history.jsonl", limits)]
                where enabled {
                    let local = directory.appendingPathComponent(name),
                        remote = cloud.appendingPathComponent(name)
                    guard usageBackupCloudFileIsCurrent(remote) else {
                        usageBackupRequestCloudDownload(remote); return false
                    }
                    let completed =
                        name == "usage.json"
                        ? usageBackupTransferUsage(
                            localURL: local, cloudURL: remote, shouldRestore: true,
                            shouldExport: export, restoreToken: token)
                        : usageBackupTransferLimits(
                            localURL: local, cloudURL: remote, shouldRestore: true,
                            shouldExport: export, restoreToken: token)
                    if !completed { return false }
                }
                return !Task.isCancelled
            }
        }
        self.work = work
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            token.invalidate(); cancellation.cancel(); work.cancel()
        }
        defer { deadline.cancel() }
        let completed = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            token.invalidate(); cancellation.cancel(); work.cancel()
        }
        self.work = nil; self.cancellation = nil; restoreToken = nil
        failure =
            completed || ownedCancelled || Task.isCancelled ? nil : "Usage backup could not finish."
        if completed {
            if token.restoredNames.contains("usage.json") {
                UsageEvents.post(UsageEvents.usageUpdated)
            }
            if token.restoredNames.contains("limits-history.jsonl") {
                UsageEvents.post(UsageEvents.limitsUpdated)
            }
        }
        return completed
    }
}

@MainActor final class UsageBackupEventQueue {
    private let enabled: () -> Bool
    private let onBattery: () -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private let transfer: () async throws -> Void
    private let debounce: Duration
    private let retry: Duration
    private var pending = false
    private var stopping = false
    private var cancelling = false
    private var deadline = ContinuousClock.now
    private var task: Task<Void, Never>?
    private(set) var pausedOnBattery = false
    var scheduled: Bool { pending || task != nil }

    init(
        debounce: Duration, retry: Duration = .seconds(3), onBattery: @escaping () -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }, enabled: @escaping () -> Bool,
        transfer: @escaping () async throws -> Void
    ) {
        self.debounce = max(.zero, debounce)
        self.retry = max(.milliseconds(1), retry)
        self.enabled = enabled
        self.onBattery = onBattery
        self.sleep = sleep
        self.transfer = transfer
    }

    func changed() {
        guard !stopping, !cancelling else { return }
        guard enabled() else { pending = false; task?.cancel(); return }
        pending = true
        deadline = ContinuousClock.now.advanced(by: debounce)
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                pausedOnBattery = false
                if pending, !stopping, enabled() { changed() }
            }
            while pending, !stopping, enabled(), !Task.isCancelled {
                if onBattery() {
                    pausedOnBattery = true
                    do { try await sleep(.seconds(60)) } catch { return }
                    continue
                }
                pausedOnBattery = false
                let delay = ContinuousClock.now.duration(to: deadline)
                if delay > .zero {
                    do { try await sleep(delay) } catch { return }
                    continue
                }
                pending = false
                do {
                    try Task.checkCancellation()
                    try await transfer()
                } catch is CancellationError { return } catch {
                    guard !stopping, enabled(), !Task.isCancelled else { return }
                    pending = true
                    deadline = ContinuousClock.now.advanced(by: retry)
                }
            }
        }
    }

    func cancel() async {
        cancelling = true
        pending = false
        let owned = task
        owned?.cancel()
        await owned?.value
        pending = false
        cancelling = false
    }

    func shutdown() async {
        stopping = true
        await cancel()
    }
}
