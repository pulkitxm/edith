import Darwin
import EdithExtensionSupport
import Foundation

@MainActor final class MusicBackupProvider {
    static let restorePendingKey = "restorePending.music"
    private let directory: @MainActor () -> URL
    private let ownedDirectory: URL
    private let cloud: URL
    private let applicationDefaults: UserDefaults
    private let defaults: UserDefaults
    private var work: Task<Void, Error>?
    private var stopping = false
    private var events: MusicBackupEventQueue?
    private var observers: [NSObjectProtocol] = []
    private var observedCloudEnabled = false
    private var needsRestore = false
    private let cloudAvailable: () -> Bool
    private(set) var failure: String?

    init(
        directory: @escaping @MainActor () -> URL, ownedDirectory: URL, cloud: URL,
        applicationDefaults: UserDefaults, defaults: UserDefaults,
        cloudAvailable: @escaping () -> Bool = { true }
    ) {
        self.directory = directory
        self.ownedDirectory = ownedDirectory
        self.cloud = cloud
        self.applicationDefaults = applicationDefaults
        self.defaults = defaults
        self.cloudAvailable = cloudAvailable
    }

    static func live(environment: [String: String] = ProcessInfo.processInfo.environment) throws
        -> MusicBackupProvider
    {
        guard let identifier = environment["EDITH_APPLICATION_IDENTIFIER"],
            let path = environment["EDITH_EXTENSION_DATA_ROOT"], path.hasPrefix("/"),
            !path.utf8.contains(0),
            let applicationDefaults = SharedDefaults.applicationStore(identifier: identifier)
        else { throw ExtensionPeerError.unavailable }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let cloud = try cloudDirectory(identifier: identifier, root: root)
        return MusicBackupProvider(
            directory: { MusicStorage.musicDir },
            ownedDirectory: root.appendingPathComponent("library"), cloud: cloud,
            applicationDefaults: applicationDefaults, defaults: SharedDefaults.store,
            cloudAvailable: {
                identifier != "com.pulkit.edith"
                    || FileManager.default.fileExists(
                        atPath: cloud.deletingLastPathComponent().deletingLastPathComponent().path)
            })
    }

    nonisolated static func cloudDirectory(
        identifier: String, root: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> URL {
        guard root.isFileURL, root.path.hasPrefix("/"), !root.path.utf8.contains(0),
            root.lastPathComponent == "music",
            root.deletingLastPathComponent().lastPathComponent == "Data",
            identifier == "com.pulkit.edith" || identifier.hasPrefix("com.pulkit.edith.dev.")
                || identifier.hasPrefix("com.pulkit.edith.tests.")
        else { throw ExtensionPeerError.invalidRequest }
        if identifier == "com.pulkit.edith" {
            return home.appendingPathComponent(
                "Library/Mobile Documents/com~apple~CloudDocs/Edith/music")
        }
        return root.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(
            "iCloud/music")
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
                "failure": failure as Any? ?? NSNull(),
                "restorePending": defaults.integer(forKey: Self.restorePendingKey),
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
        guard directory().standardizedFileURL == ownedDirectory.standardizedFileURL else {
            return false
        }
        do { try await transfer(export: false); return true } catch { return false }
    }

    private var cloudEnabled: Bool {
        !stopping
            && (applicationDefaults.object(forKey: AppStorageKeys.Backup.icloud) as? Bool ?? true)
            && cloudAvailable()
    }
    private var exportEnabled: Bool { defaults.bool(forKey: AppStorageKeys.Music.backup) }

    func startScheduling(debounce: Duration = .seconds(5), restorePending: Bool = false) {
        guard !stopping, events == nil else { return }
        observedCloudEnabled = cloudEnabled
        needsRestore = restorePending && cloudEnabled
        events = MusicBackupEventQueue(
            debounce: debounce,
            enabled: { [weak self] in
                guard let self else { return false }
                return cloudEnabled && (exportEnabled || needsRestore)
            },
            transfer: { [weak self] in
                guard let self, !stopping else { throw CancellationError() }
                if needsRestore {
                    if directory().standardizedFileURL == ownedDirectory.standardizedFileURL {
                        guard await restoreOnEnable() else { throw ExtensionPeerError.unavailable }
                    }
                    try Task.checkCancellation()
                    needsRestore = false
                }
                _ = try await exportCurrent()
            })
        for notification in [
            Notification.Name(MusicEvents.Name.musicFolderChanged), .musicFolderChangedLocally,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(
                    forName: notification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.preferencesChanged() }
                })
        }
        observers.append(
            IPC.observe(IPC.Name.settingsChanged) { [weak self] in
                MainActor.assumeIsolated { self?.preferencesChanged() }
            })
        events?.changed()
    }

    func preferencesChanged() {
        guard !stopping else { return }
        applicationDefaults.synchronize(); defaults.synchronize()
        let enabled = cloudEnabled
        if enabled && !observedCloudEnabled { needsRestore = true }
        observedCloudEnabled = enabled
        if !enabled { work?.cancel() }
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
        work?.cancel()
        _ = try? await work?.value
    }

    private func transfer(export: Bool) async throws {
        guard !stopping, work == nil else { throw ExtensionPeerError.unavailable }
        let local = directory(), cloud = cloud
        let work = Task {
            let deadline = ContinuousClock.now.advanced(by: .seconds(600))
            while !export {
                try Task.checkCancellation()
                let scan = Task.detached(priority: .utility) {
                    try Self.missingFiles(source: cloud, destination: local)
                }
                let missing = try await withTaskCancellationHandler {
                    try await scan.value
                } onCancel: {
                    scan.cancel()
                }
                defaults.set(missing.count, forKey: Self.restorePendingKey)
                MusicEvents.post(MusicEvents.Name.musicFolderChanged)
                if missing.isEmpty { break }
                let unavailable = missing.filter { !Self.isCurrent($0) }
                for file in unavailable {
                    try? FileManager.default.startDownloadingUbiquitousItem(at: file)
                }
                if unavailable.count < missing.count {
                    try await Self.synchronize(
                        source: cloud, destination: local, arguments: ["--ignore-existing"])
                }
                guard ContinuousClock.now < deadline else { throw ExtensionPeerError.timedOut }
                try await Task.sleep(for: .seconds(3))
            }
            if export, FileManager.default.fileExists(atPath: local.path) {
                try await Self.synchronize(
                    source: local, destination: cloud, arguments: ["--delete"])
                defaults.set(
                    Date().timeIntervalSince1970, forKey: AppStorageKeys.Music.lastBackupAt)
            }
        }
        self.work = work
        defer { self.work = nil }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
            failure = nil
        } catch {
            failure = error is CancellationError ? nil : "Music backup could not finish."
            throw error
        }
    }

    private nonisolated static func synchronize(
        source: URL, destination: URL, arguments: [String]
    ) async throws {
        guard try isDirectory(source) else { return }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        guard try isDirectory(destination) else { throw ExtensionPeerError.invalidRequest }
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: URL(fileURLWithPath: "/usr/bin/rsync"),
                arguments: ["-a", "--no-links", "--exclude=.*.icloud"] + arguments
                    + [source.path + "/", destination.path + "/"],
                environment: CLIToolEnvironment.sanitized(), timeout: 600,
                maximumOutputBytes: 32_768, terminatesProcessGroup: true), onLine: { _ in })
        guard result.terminationStatus == 0 else {
            throw ExtensionPeerError.rejected("Music files could not be transferred.")
        }
    }

    nonisolated static func missingFiles(source: URL, destination: URL) throws -> [URL] {
        guard try isDirectory(source) else { return [] }
        let source = source.standardizedFileURL.resolvingSymlinksInPath()
        let manager = FileManager.default
        guard
            let enumerator = manager.enumerator(
                at: source,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ], options: [.skipsPackageDescendants])
        else { throw ExtensionPeerError.unavailable }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        var files: [URL] = []
        var inspected = 0
        while let file = enumerator.nextObject() as? URL {
            try Task.checkCancellation()
            inspected += 1
            guard inspected <= 100_000, ContinuousClock.now < deadline else {
                throw ExtensionPeerError.rejected("The music library could not be inspected.")
            }
            let values = try file.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            guard values.isRegularFile == true, file.lastPathComponent != ".DS_Store" else {
                continue
            }
            let file = file.standardizedFileURL.resolvingSymlinksInPath()
            guard file.path.hasPrefix(source.path + "/") else {
                throw ExtensionPeerError.invalidRequest
            }
            var name = String(file.path.dropFirst(source.path.count + 1))
            if file.lastPathComponent.hasPrefix("."), file.lastPathComponent.hasSuffix(".icloud") {
                let actual = String(file.lastPathComponent.dropFirst().dropLast(7))
                guard !actual.isEmpty else { continue }
                name = (name as NSString).deletingLastPathComponent
                name = name.isEmpty ? actual : name + "/" + actual
            }
            var metadata = stat()
            if lstat(destination.appendingPathComponent(name).path, &metadata) == 0 { continue }
            guard errno == ENOENT else { throw ExtensionPeerError.unavailable }
            files.append(source.appendingPathComponent(name))
        }
        return files
    }

    private nonisolated static func isDirectory(_ url: URL) throws -> Bool {
        var metadata = stat()
        if lstat(url.path, &metadata) != 0 {
            if errno == ENOENT { return false }
            throw ExtensionPeerError.unavailable
        }
        guard metadata.st_mode & S_IFMT == S_IFDIR else {
            throw ExtensionPeerError.invalidRequest
        }
        return true
    }

    private nonisolated static func isCurrent(_ url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        return values?.isUbiquitousItem != true
            || values?.ubiquitousItemDownloadingStatus == .current
    }
}

@MainActor final class MusicBackupEventQueue {
    private let enabled: () -> Bool
    private let transfer: () async throws -> Void
    private let debounce: Duration
    private let retry: Duration
    private var pending = false
    private var stopping = false
    private var cancelling = false
    private var deadline = ContinuousClock.now
    private var task: Task<Void, Never>?
    var scheduled: Bool { pending || task != nil }

    init(
        debounce: Duration, retry: Duration = .seconds(3), enabled: @escaping () -> Bool,
        transfer: @escaping () async throws -> Void
    ) {
        self.debounce = max(.zero, debounce)
        self.retry = max(.milliseconds(1), retry)
        self.enabled = enabled
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
                if pending, !stopping, enabled() { changed() }
            }
            while pending, !stopping, enabled(), !Task.isCancelled {
                let delay = ContinuousClock.now.duration(to: deadline)
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
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
