import Darwin
import EdithKit
import Foundation

public actor StorageInspectionWorkflow {
    private let cloudDirectory: URL
    private let maximumEntries: Int
    private let maximumDuration: TimeInterval
    private var work: Task<StorageInspectionSnapshot, Error>?
    private var workID: UUID?
    private var cached: StorageInspectionSnapshot?

    public init(
        cloudDirectory: URL = AppData.cloudDir, maximumEntries: Int = 100_000,
        maximumDuration: TimeInterval = 15
    ) {
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
            let cloud = cloudDirectory
            let limit = maximumEntries
            let duration = maximumDuration
            let cancellation = WorkCancellation()
            flight = Task.detached(priority: .utility) {
                try await withTaskCancellationHandler {
                    try await BlockingWork.perform {
                        try StorageInspectionReader.inspect(
                            cloud: cloud, maximumEntries: limit, duration: duration,
                            isCancelled: { cancellation.isCancelled }, report: report)
                    }
                } onCancel: {
                    cancellation.cancel()
                }
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

private enum StorageInspectionReader {
    static let shownEntries = 256

    static func inspect(
        cloud: URL, maximumEntries: Int, duration: TimeInterval,
        isCancelled: @escaping @Sendable () -> Bool, report: @Sendable (String) -> Void
    ) throws -> StorageInspectionSnapshot {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: cloud.path) else {
            return StorageInspectionSnapshot(restoreEntries: [], issues: [])
        }
        report("Inspecting backup files")
        if isCancelled() { throw CancellationError() }
        let root = canonicalURL(cloud)
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ).map(\.lastPathComponent).sorted()
        } catch {
            return StorageInspectionSnapshot(
                restoreEntries: [], issues: ["The backup directory could not be read."])
        }
        let shown = Array(names.prefix(shownEntries))
        let scopes = shown.enumerated().map {
            StorageScope(id: String($0.offset), root: root.appendingPathComponent($0.element))
        }
        let measurement = try StorageAccounting.scan(
            scopes: scopes, maximumEntries: maximumEntries, duration: .seconds(duration),
            isCancelled: isCancelled)
        var issues = measurement.issues
        if names.count > shownEntries {
            issues.append("Only the first \(shownEntries) backup entries are shown.")
        }
        return StorageInspectionSnapshot(
            restoreEntries: zip(shown, scopes).map {
                StorageRestoreEntry(name: $0, bytes: measurement.bytes[$1.id]?.logical ?? 0)
            },
            issues: issues)
    }

    private static func canonicalURL(_ url: URL) -> URL {
        guard let path = realpath(url.path, nil) else { return url.standardizedFileURL }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }
}
