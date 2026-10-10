import Foundation
import Observation

@MainActor
@Observable
public final class SurfaceSnapshotClient {
    public typealias Execute = @Sendable (String, String, Data) async throws -> Data
    private struct Job: Sendable {
        let providerID: String
        let version: String
        let target: SurfaceTarget
        let task: Task<Data, Error>
    }

    @ObservationIgnored private let activeVersions: @MainActor () -> [String: String]
    @ObservationIgnored private let execute: Execute
    @ObservationIgnored private var jobs: [UUID: Job] = [:]
    @ObservationIgnored private nonisolated(unsafe) var stopObserving: (() -> Void)?
    @ObservationIgnored private var stopped = false
    public private(set) var versions: [String: String]
    public var pendingCount: Int { jobs.count }

    deinit {
        stopObserving?()
        for job in jobs.values { job.task.cancel() }
    }

    public init(
        activeVersions: @escaping @MainActor () -> [String: String],
        execute: @escaping Execute
    ) {
        self.activeVersions = activeVersions
        self.execute = execute
        versions = activeVersions()
    }

    public convenience init(context: SurfaceHostContext) {
        let channel = context.sharedState
        self.init(activeVersions: { context.activeVersions }) { id, command, payload in
            let endpoint = try ExtensionPeerEndpoint(
                namespace: channel.namespace, owner: id,
                directory: channel.root.appendingPathComponent("Commands"))
            return try await endpoint.invoke(command, payload: payload, timeout: 5)
        }
        let observer = channel.observe { [weak self] owner in
            guard owner == "host" else { return }
            MainActor.assumeIsolated { self?.retain(activeVersions: context.activeVersions) }
        }
        stopObserving = { channel.stopObserving(observer) }
    }

    public func shutdown() {
        stopped = true
        stopObserving?(); stopObserving = nil
        retain(activeVersions: [:])
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
        _ = try snapshot.encoded()
        let current = SurfaceCommandService.project(snapshot, tile: tile)
        guard current.providerID == providerID else { throw ExtensionPeerError.invalidRequest }
        if let value {
            guard value.isFinite, (0...1).contains(value),
                ((current.sliders ?? []) + current.rows.flatMap { $0.sliders ?? [] }).contains(
                    where: { $0.id == actionID })
            else { throw ExtensionPeerError.invalidRequest }
        } else {
            guard
                current.controlActions.contains(where: {
                    $0.id == actionID
                })
            else { throw ExtensionPeerError.invalidRequest }
        }
        let request = SurfaceActionRequest(
            snapshot: .init(target: target, tile: tile), actionID: actionID, value: value)
        let payload = try request.encoded(providerID: providerID)
        let data = try await invoke(
            providerID: providerID, target: target, command: "surface.perform", payload: payload)
        return try SurfaceSnapshot.decode(data, providerID: providerID)
    }

    public func retain(activeVersions: [String: String]) {
        let retainedVersions = stopped ? [:] : activeVersions
        versions = retainedVersions
        for (token, job) in jobs
        where retainedVersions[job.providerID] != job.version
            || (job.target == .notch && retainedVersions["notchShelf"] == nil)
        {
            jobs[token] = nil
            job.task.cancel()
        }
    }

    private func invoke(providerID: String, target: SurfaceTarget, command: String, payload: Data)
        async throws -> Data
    {
        guard !stopped else { throw ExtensionPeerError.unavailable }
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
