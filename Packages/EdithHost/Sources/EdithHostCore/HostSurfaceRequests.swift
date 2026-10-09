import EdithExtensionSupport
import Foundation

@MainActor
public final class HostSurfaceRequests {
    public typealias Execute = @Sendable (String, String, Data) async throws -> Data
    private struct Job {
        let providerID: String
        let version: String
        let target: SurfaceTarget
        let task: Task<Data, Error>
    }

    private let activeVersions: @MainActor () -> [String: String]
    private let execute: Execute
    private var jobs: [UUID: Job] = [:]
    public var pendingCount: Int { jobs.count }

    public init(
        activeVersions: @escaping @MainActor () -> [String: String],
        execute: @escaping Execute
    ) {
        self.activeVersions = activeVersions
        self.execute = execute
    }

    public func snapshot(providerID: String, target: SurfaceTarget, tile: SurfaceTile) async throws
        -> SurfaceSnapshot
    {
        let request = SurfaceSnapshotRequest(target: target, tile: tile)
        let payload = try request.encoded(providerID: providerID)
        let data = try await invoke(
            providerID: providerID, target: target, command: "surface.snapshot", payload: payload)
        return try SurfaceSnapshot.decode(data, providerID: providerID)
    }

    public func perform(
        providerID: String, target: SurfaceTarget, tile: SurfaceTile, snapshot: SurfaceSnapshot,
        actionID: String, value: Double? = nil
    ) async throws -> SurfaceSnapshot {
        guard snapshot.providerID == providerID,
            (snapshot.actions + snapshot.rows.flatMap(\.actions)).contains(where: {
                $0.id == actionID
            })
        else { throw ExtensionPeerError.invalidRequest }
        let request = SurfaceActionRequest(
            snapshot: .init(target: target, tile: tile), actionID: actionID, value: value)
        let payload = try request.encoded(providerID: providerID)
        let data = try await invoke(
            providerID: providerID, target: target, command: "surface.perform", payload: payload)
        return try SurfaceSnapshot.decode(data, providerID: providerID)
    }

    public func retain(activeVersions: [String: String]) {
        for (token, job) in jobs
        where activeVersions[job.providerID] != job.version
            || (job.target == .notch && activeVersions["notchShelf"] == nil)
        {
            jobs[token] = nil
            job.task.cancel()
        }
    }

    private func invoke(providerID: String, target: SurfaceTarget, command: String, payload: Data)
        async throws -> Data
    {
        let active = activeVersions()
        guard let version = active[providerID], target != .notch || active["notchShelf"] != nil
        else {
            throw ExtensionPeerError.unavailable
        }
        guard jobs.count < 32 else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        let token = UUID()
        let task = Task { [execute] in try await execute(providerID, command, payload) }
        jobs[token] = Job(providerID: providerID, version: version, target: target, task: task)
        defer { jobs[token] = nil }
        let data = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard jobs[token] != nil, activeVersions()[providerID] == version,
            target != .notch || activeVersions()["notchShelf"] != nil,
            !task.isCancelled
        else { throw CancellationError() }
        return data
    }
}
