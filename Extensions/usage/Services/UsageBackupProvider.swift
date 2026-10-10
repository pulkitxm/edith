import EdithExtensionSupport
import Foundation

@MainActor final class UsageBackupProvider {
    private let directory: URL
    private let cloud: URL
    private let defaults: UserDefaults
    private var work: Task<Bool, Never>?
    private var cancellation: UsageBackupCancellation?
    private var restoreToken: UsageBackupRestoreToken?
    private var stopping = false
    private(set) var failure: String?

    init(directory: URL, cloud: URL, defaults: UserDefaults) {
        self.directory = directory
        self.cloud = cloud
        self.defaults = defaults
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
            directory: root.appendingPathComponent("data"), cloud: cloud, defaults: defaults)
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
        guard payload.count <= 512 else { throw ExtensionPeerError.invalidRequest }
        if !payload.isEmpty {
            guard let object = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any],
                object.isEmpty
            else { throw ExtensionPeerError.invalidRequest }
        }
        switch command {
        case "backup.status":
            return try JSONSerialization.data(withJSONObject: [
                "running": work != nil, "failure": failure as Any? ?? NSNull(),
            ])
        case "backup.cancel":
            await cancel()
            return Data("{\"cancelled\":true}".utf8)
        case "backup.synchronize":
            guard defaults.bool(forKey: AppStorageKeys.Backup.icloud) else {
                return Data("{\"enabled\":false}".utf8)
            }
            let usage = defaults.object(forKey: AppStorageKeys.Backup.usage) as? Bool ?? true
            let limits = defaults.object(forKey: AppStorageKeys.Backup.limits) as? Bool ?? true
            guard await transfer(usage: usage, limits: limits, export: true) else {
                throw ExtensionPeerError.rejected(
                    "Usage backup could not finish. Retry after iCloud has downloaded the files.")
            }
            return Data("{\"synchronized\":true}".utf8)
        default: throw ExtensionPeerError.invalidRequest
        }
    }

    func restoreOnEnable() async -> Bool {
        await transfer(usage: true, limits: true, export: false)
    }

    func shutdown() async { stopping = true; await cancel() }

    private func cancel() async {
        restoreToken?.invalidate()
        cancellation?.cancel()
        work?.cancel()
        _ = await work?.value
    }

    private func transfer(usage: Bool, limits: Bool, export: Bool) async -> Bool {
        guard !stopping, work == nil else { return false }
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
        failure = completed ? nil : "Usage backup could not finish."
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
