import EdithKit
import Foundation

public struct StorageInspectionTarget: Sendable {
    public let id: String
    public let title: String
    public let url: URL

    public init(id: String, title: String, url: URL) {
        self.id = id
        self.title = title
        self.url = url
    }

    public static var defaults: [StorageInspectionTarget] {
        [
            Self(
                id: "store", title: "Store",
                url: AppData.supportDir.appendingPathComponent("edith.sqlite")),
            Self(id: "machines", title: "Machines", url: DataRoot.machines),
            Self(id: "clipboard", title: "Clipboard", url: DataRoot.clipboard),
            Self(id: "seo", title: "Site audits", url: DataRoot.siteAudit),
            Self(id: "usage", title: "Usage files", url: DataRoot.usage),
            Self(id: "music", title: "Music", url: Repo.musicDir),
            Self(id: "caches", title: "Caches", url: DataRoot.caches),
            Self(id: "logs", title: "Logs", url: DataRoot.logs),
        ]
    }
}

public actor StorageInspectionWorkflow {
    private let targets: [StorageInspectionTarget]
    private let cloudDirectory: URL
    private let maximumEntries: Int
    private let maximumDuration: TimeInterval
    private var work: Task<StorageInspectionSnapshot, Error>?
    private var workID: UUID?
    private var cached: StorageInspectionSnapshot?

    public init(
        targets: [StorageInspectionTarget] = StorageInspectionTarget.defaults,
        cloudDirectory: URL = AppData.cloudDir, maximumEntries: Int = 100_000,
        maximumDuration: TimeInterval = 15
    ) {
        self.targets = targets
        self.cloudDirectory = cloudDirectory
        self.maximumEntries = max(1, min(100_000, maximumEntries))
        self.maximumDuration = maximumDuration.isFinite ? max(0.01, min(30, maximumDuration)) : 15
    }

    deinit { work?.cancel() }

    public func register(on tasks: AgentTaskService) async {
        await tasks.register(operation: StorageInspectionClient.operation) { payload, context in
            let force = try AgentPayload.decode(Bool.self, from: payload)
            return try AgentPayload.encode(
                await self.inspect(force: force, report: { context.report($0) }))
        }
    }

    public func inspect(
        force: Bool = false, report: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws
        -> StorageInspectionSnapshot
    {
        if !force, let cached, Date().timeIntervalSince(cached.collectedAt) < 2 { return cached }
        let flight: Task<StorageInspectionSnapshot, Error>
        let identifier: UUID
        if let work, let workID {
            flight = work
            identifier = workID
        } else {
            identifier = UUID()
            let targets = targets
            let cloud = cloudDirectory
            let limit = maximumEntries
            let duration = maximumDuration
            flight = Task.detached(priority: .utility) {
                let reader = StorageInspectionReader(maximumEntries: limit, duration: duration)
                return try reader.inspect(targets: targets, cloud: cloud, report: report)
            }
            work = flight
            workID = identifier
        }
        defer { if workID == identifier { work = nil; workID = nil } }
        let result = try await withTaskCancellationHandler {
            try await flight.value
        } onCancel: {
            flight.cancel()
        }
        try Task.checkCancellation()
        cached = result
        return result
    }
}

private final class StorageInspectionReader {
    private let maximumEntries: Int
    private let deadline: ContinuousClock.Instant
    private var visited = 0
    private var issues: [String] = []
    private let fileManager = FileManager.default
    private let keys: Set<URLResourceKey> = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
    ]

    init(maximumEntries: Int, duration: TimeInterval) {
        self.maximumEntries = maximumEntries
        deadline = ContinuousClock.now.advanced(by: .seconds(duration))
    }

    func inspect(
        targets: [StorageInspectionTarget], cloud: URL,
        report: @Sendable (String) -> Void
    ) throws -> StorageInspectionSnapshot {
        var footprints: [BackupFootprint] = []
        for target in targets {
            try Task.checkCancellation()
            report("Inspecting \(target.title)")
            let bytes = try size(target.url)
            footprints.append(
                BackupFootprint(
                    id: target.id, title: target.title, url: target.url, bytes: bytes,
                    exists: fileManager.fileExists(atPath: target.url.path)))
        }
        var restore: [StorageRestoreEntry] = []
        if fileManager.fileExists(atPath: cloud.path) {
            report("Inspecting backup files")
            do {
                var entries: [URL] = []
                guard
                    let children = fileManager.enumerator(
                        at: cloud, includingPropertiesForKeys: Array(keys),
                        options: [.skipsHiddenFiles])
                else { throw AgentError(.failed, "The backup directory could not be read.") }
                for case let child as URL in children {
                    try Task.checkCancellation()
                    children.skipDescendants()
                    entries.append(child)
                    if entries.count > 256 { break }
                }
                for entry in entries.prefix(256).sorted(by: {
                    $0.lastPathComponent < $1.lastPathComponent
                }) {
                    try Task.checkCancellation()
                    restore.append(
                        StorageRestoreEntry(name: entry.lastPathComponent, bytes: try size(entry)))
                }
                if entries.count > 256 { issue("Only the first 256 backup entries are shown.") }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issue("The backup directory could not be read.")
            }
        }
        return StorageInspectionSnapshot(
            footprints: footprints, restoreEntries: restore, issues: issues)
    }

    private func size(_ source: URL) throws -> Int64 {
        try Task.checkCancellation()
        guard fileManager.fileExists(atPath: source.path) else { return 0 }
        let source = source.resolvingSymlinksInPath()
        let values: URLResourceValues
        do { values = try source.resourceValues(forKeys: keys) } catch {
            issue("Some storage entries could not be read; sizes are partial.")
            return 0
        }
        if values.isRegularFile == true { return Int64(values.fileSize ?? 0) }
        guard values.isDirectory == true else { return 0 }
        guard
            let files = fileManager.enumerator(
                at: source, includingPropertiesForKeys: Array(keys), options: [],
                errorHandler: { [self] _, _ in
                    issue("Some storage entries could not be read; sizes are partial.")
                    return true
                })
        else {
            issue("Some storage directories could not be read; sizes are partial.")
            return 0
        }
        var total: Int64 = 0
        for case let file as URL in files {
            try Task.checkCancellation()
            guard visited < maximumEntries, ContinuousClock.now < deadline else {
                issue(
                    "The inspection limit was reached; sizes are partial. Open a folder to inspect it further."
                )
                break
            }
            visited += 1
            do {
                let values = try file.resourceValues(forKeys: keys)
                if values.isSymbolicLink == true { files.skipDescendants(); continue }
                guard values.isRegularFile == true else { continue }
                let (sum, overflow) = total.addingReportingOverflow(
                    Int64(max(0, values.fileSize ?? 0)))
                if overflow {
                    issue("The storage total exceeds the supported size range.")
                    return Int64.max
                }
                total = sum
            } catch {
                issue("Some storage entries could not be read; sizes are partial.")
            }
        }
        return total
    }

    private func issue(_ message: String) {
        if !issues.contains(message) { issues.append(message) }
    }
}
