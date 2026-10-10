import Darwin
import EdithExtensionSupport
import Foundation
import IOKit.ps

@MainActor final class ClipboardBackupProvider {
    private let archive: ClipboardArchive
    private let cloud: URL
    private let applicationDefaults: UserDefaults
    private let defaults: UserDefaults
    private var work: Task<Void, Error>?
    private var cancellation: ClipboardBackupCancellation?
    private var stopping = false
    private var events: ClipboardBackupEventQueue?
    private var observers: [NSObjectProtocol] = []
    private var bootstrapCancelled = false
    private var observedCloudEnabled = false
    private var needsRestore = false
    private let cloudAvailable: () -> Bool
    private let onBattery: () -> Bool
    private let sleep: @Sendable (Duration) async throws -> Void
    private(set) var failure: String?

    init(
        archive: ClipboardArchive, cloud: URL, applicationDefaults: UserDefaults,
        defaults: UserDefaults, cloudAvailable: @escaping () -> Bool = { true },
        onBattery: @escaping () -> Bool,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
    ) {
        self.archive = archive
        self.cloud = cloud
        self.applicationDefaults = applicationDefaults
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
        -> ClipboardBackupProvider
    {
        guard let identifier = environment["EDITH_APPLICATION_IDENTIFIER"],
            let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0),
            let applicationDefaults = SharedDefaults.applicationStore(identifier: identifier)
        else { throw ExtensionPeerError.unavailable }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let cloud = try cloudDirectory(identifier: identifier, root: root)
        return ClipboardBackupProvider(
            archive: ClipboardArchive(root: root.appendingPathComponent("clipboard")),
            cloud: cloud,
            applicationDefaults: applicationDefaults, defaults: SharedDefaults.store,
            cloudAvailable: {
                identifier != "com.pulkit.edith"
                    || FileManager.default.fileExists(
                        atPath: cloud.deletingLastPathComponent().deletingLastPathComponent().path)
            },
            onBattery: {
                environment["EDITH_EXTENSION_FIXTURE_HOME"] == nil && Self.isOnBattery()
            })
    }

    nonisolated static func cloudDirectory(
        identifier: String, root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0),
            root.lastPathComponent == "clipboard",
            root.deletingLastPathComponent().lastPathComponent == "Data",
            identifier == "com.pulkit.edith" || identifier.hasPrefix("com.pulkit.edith.dev.")
                || identifier.hasPrefix("com.pulkit.edith.tests.")
        else { throw ExtensionPeerError.invalidRequest }
        if identifier == "com.pulkit.edith" {
            return home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Edith/clipboard")
        }
        return root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "iCloud/clipboard")
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

    func restoreOnEnable() async -> Bool {
        guard !stopping else { return false }
        guard cloudEnabled else { return true }
        do { try await transfer(export: false); return true } catch { return false }
    }

    private var cloudEnabled: Bool {
        !stopping
            && (applicationDefaults.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true)
            && cloudAvailable()
    }
    private var exportEnabled: Bool { defaults.bool(forKey: AppStorageKeys.Clipboard.backup) }

    func startScheduling(debounce: Duration = .seconds(5), restorePending: Bool = false) {
        guard !stopping, events == nil else { return }
        observedCloudEnabled = cloudEnabled
        needsRestore = restorePending && cloudEnabled
        events = ClipboardBackupEventQueue(
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
        observers.append(
            NotificationCenter.default.addObserver(
                forName: Notification.Name(IPC.Name.clipboardChanged), object: nil, queue: .main
            ) { [weak self] notification in
                guard notification.userInfo?["backup"] as? Bool != false else { return }
                MainActor.assumeIsolated { self?.preferencesChanged() }
            })
        observers.append(
            IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.preferencesChanged() }
            })
        if !bootstrapCancelled { events?.changed() }
    }

    func preferencesChanged() {
        guard !stopping else { return }
        applicationDefaults.synchronize(); defaults.synchronize()
        let enabled = cloudEnabled
        if enabled && !observedCloudEnabled { needsRestore = true }
        observedCloudEnabled = enabled
        if !enabled { cancellation?.cancel(); work?.cancel() }
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
        try await transfer(export: true)
        return Data("{\"synchronized\":true}".utf8)
    }

    private func cancel() async {
        bootstrapCancelled = true
        cancellation?.cancel()
        work?.cancel()
        _ = try? await work?.value
    }

    private func transfer(export: Bool) async throws {
        guard !stopping, work == nil else { throw ExtensionPeerError.unavailable }
        let archive = archive, cloud = cloud
        let cancellation = ClipboardBackupCancellation()
        self.cancellation = cancellation
        let work = Task {
            if export {
                let staging = FileManager.default.temporaryDirectory.appendingPathComponent(
                    "clipboard-backup-export-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: staging) }
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let preparation = Task.detached(priority: .utility) {
                    try archive.stageExport(to: staging)
                }
                try await withTaskCancellationHandler {
                    try await preparation.value
                } onCancel: {
                    preparation.cancel()
                }
                try Task.checkCancellation()
                try await Self.exportSnapshot(staging: staging, cloud: cloud)
                defaults.set(
                    Date().timeIntervalSince1970, forKey: AppStorageKeys.Clipboard.lastBackupAt)
            } else {
                let deadline = ContinuousClock.now.advanced(by: .seconds(600))
                while true {
                    try Task.checkCancellation()
                    let restore = Task.detached(priority: .utility) {
                        try Self.restore(archive: archive, cloud: cloud, cancellation: cancellation)
                    }
                    let completed = try await withTaskCancellationHandler {
                        try await restore.value
                    } onCancel: {
                        cancellation.cancel(); restore.cancel()
                    }
                    if completed { break }
                    guard ContinuousClock.now < deadline else { throw ExtensionPeerError.timedOut }
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
        self.work = work
        defer { self.work = nil; self.cancellation = nil }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                cancellation.cancel(); work.cancel()
            }
            failure = nil
        } catch {
            failure = error is CancellationError ? nil : "Clipboard backup could not finish."
            throw error
        }
    }

    nonisolated static func exportSnapshot(staging: URL, cloud: URL) async throws {
        try checkDirectory(staging, create: false)
        try checkDirectory(cloud, create: true)
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/rsync"),
                arguments: [
                    "-a", "--delete", "--checksum", "--no-links", staging.path + "/",
                    cloud.path + "/",
                ],
                environment: CLIToolEnvironment.sanitized(), timeout: 600,
                maximumOutputBytes: 32_768, terminatesProcessGroup: true), onLine: { _ in })
        guard result.terminationStatus == 0 else { throw ExtensionPeerError.unavailable }
    }

    private nonisolated static func restore(
        archive: ClipboardArchive, cloud: URL, cancellation: ClipboardBackupCancellation
    ) throws -> Bool {
        var metadata = stat()
        if lstat(cloud.path, &metadata) != 0 {
            guard errno == ENOENT else { throw ExtensionPeerError.unavailable }
            return true
        }
        try checkDirectory(cloud, create: false)
        let coordinator = NSFileCoordinator()
        try cancellation.register(coordinator)
        defer { cancellation.remove(coordinator) }
        var coordinationError: NSError?
        var transferError: Error?
        var completed = false
        coordinator.coordinate(
            readingItemAt: cloud, options: .withoutChanges,
            writingItemAt: archive.root, options: .forMerging, error: &coordinationError
        ) { source, _ in
            do {
                try Task.checkCancellation()
                let index = source.appendingPathComponent("index.jsonl")
                guard isCurrent(index) else {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: index)
                    return
                }
                guard
                    let data = try ClipboardFiles.readRegularFile(
                        at: index, maximumBytes: ClipboardArchive.maximumIndexBytes)
                else { completed = true; return }
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let lines = data.split(separator: 10)
                guard lines.count <= 8192 else { throw ExtensionPeerError.invalidRequest }
                let entries = try lines.map {
                    try decoder.decode(ClipboardEntry.self, from: Data($0))
                }
                if !entries.isEmpty {
                    try checkDirectory(source.appendingPathComponent("blobs"), create: false)
                }
                var pending = false
                for entry in entries {
                    try Task.checkCancellation()
                    guard entry.sha256.utf8.count == 64,
                        entry.sha256.utf8.allSatisfy({
                            (48...57).contains($0) || (97...102).contains($0)
                        }),
                        !entry.ext.isEmpty, entry.ext.utf8.count <= 32,
                        entry.ext.utf8.allSatisfy({
                            (48...57).contains($0) || (65...90).contains($0)
                                || (97...122).contains($0)
                        })
                    else { throw ExtensionPeerError.invalidRequest }
                    let name = entry.sha256 + "." + entry.ext
                    let blob = source.appendingPathComponent("blobs/" + name)
                    if !isCurrent(blob) {
                        try? FileManager.default.startDownloadingUbiquitousItem(at: blob)
                        pending = true
                        continue
                    }
                    try archive.restoreBlob(from: blob, name: name)
                }
                guard !pending else { return }
                try Task.checkCancellation()
                let previous = try ClipboardFiles.readRegularFile(
                    at: archive.root.appendingPathComponent("index.jsonl"),
                    maximumBytes: ClipboardArchive.maximumIndexBytes)
                try archive.mergeAvailableCloudEntries(from: index)
                if try previous
                    != ClipboardFiles.readRegularFile(
                        at: archive.root.appendingPathComponent("index.jsonl"),
                        maximumBytes: ClipboardArchive.maximumIndexBytes)
                {
                    IPC.post(IPC.Name.clipboardChanged, userInfo: ["backup": false])
                }
                completed = true
            } catch { transferError = error }
        }
        if let coordinationError { throw coordinationError }
        if let transferError { throw transferError }
        try Task.checkCancellation()
        return completed
    }

    private nonisolated static func isCurrent(_ url: URL) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            return !FileManager.default.fileExists(
                atPath: url.deletingLastPathComponent().appendingPathComponent(
                    "." + url.lastPathComponent + ".icloud"
                ).path)
        }
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        return values?.isUbiquitousItem != true
            || values?.ubiquitousItemDownloadingStatus == .current
    }

    private nonisolated static func checkDirectory(_ url: URL, create: Bool) throws {
        if create {
            try FileManager.default.createDirectory(
                at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

private final class ClipboardBackupCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var coordinators: [ObjectIdentifier: NSFileCoordinator] = [:]
    private var cancelled = false

    func register(_ coordinator: NSFileCoordinator) throws {
        try lock.withLock {
            guard !cancelled else { throw CancellationError() }
            coordinators[ObjectIdentifier(coordinator)] = coordinator
        }
    }

    func remove(_ coordinator: NSFileCoordinator) {
        _ = lock.withLock { coordinators.removeValue(forKey: ObjectIdentifier(coordinator)) }
    }

    func cancel() {
        let pending = lock.withLock {
            cancelled = true
            return Array(coordinators.values)
        }
        for coordinator in pending { coordinator.cancel() }
    }
}

@MainActor final class ClipboardBackupEventQueue {
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
