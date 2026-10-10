import EdithExtensionSupport
import Foundation
import Observation

public enum UsageMachineRefreshPolicy: Int, Codable, Sendable {
    case skip
    case due
    case all
}

@MainActor @Observable
public final class UsageWorkerController {
    public typealias Collect =
        @Sendable (UsageMachineRefreshPolicy, @escaping @Sendable (UsageRefreshEvent) -> Void)
        async throws -> Data
    public typealias FetchLimits = @Sendable (LimitsRefreshSession) async -> LimitsTopicSnapshot
    public private(set) var latestLimits: LimitsTopicSnapshot?
    public private(set) var refreshing = false
    public private(set) var failure: String?
    public private(set) var notice: String?
    private var progress: UsageRefreshProgress?
    private var refreshRecorder: UsageRefreshRecorder?
    var refreshObservation: UsageRefreshObservation? { refreshRecorder?.snapshot }
    private var backgroundTask: Task<Void, Never>?
    private let fetchLimits: FetchLimits
    private let collect: Collect
    private let dataDirectory: URL
    private let limitsSession = LimitsRefreshSession()
    private var usageTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var usageID: UUID?
    private var stopped = false

    public init(
        dataDirectory: URL = Repo.dataDir,
        fetchLimits: @escaping FetchLimits = { session in
            await LimitsCollector.refresh(force: true, refreshSession: session, announce: { _ in })
        }, collect: @escaping Collect
    ) {
        self.dataDirectory = dataDirectory
        self.collect = collect
        self.fetchLimits = fetchLimits
    }

    @discardableResult
    public func requestRefresh(policy: UsageMachineRefreshPolicy = .due) throws -> String {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if let usageID { return usageID.uuidString }
        let id = UUID()
        usageID = id
        refreshing = true
        failure = nil
        UsageEvents.post(UsageEvents.refreshStarted)
        let collect = self.collect
        let directory = dataDirectory
        let progress = UsageRefreshProgress(directory: directory)
        self.progress = progress
        let recorder = UsageRefreshRecorder()
        refreshRecorder = recorder
        usageTask = Task { [weak self] in
            do {
                let collected = try await collect(
                    policy,
                    {
                        progress.record($0); recorder.record($0)
                    })
                try Task.checkCancellation()
                let cache = UsageAttributionCache.load(dataDir: directory)
                let next = await UsageAttributionAdvisor.advise(
                    collected, cache: cache,
                    decider: UsageExecutionEnvironment.fixtureHome == nil
                        ? await UsageJevPeer.current() : nil)
                try Task.checkCancellation()
                if next != cache { try next.save(dataDir: directory) }
                let fresh = UsageAttribution.attributed(collected, cache: next)
                try Task.checkCancellation()
                let write = Task.detached(priority: .utility) {
                    try Task.checkCancellation()
                    guard fresh.count <= 64 * 1_024 * 1_024, UsageHistory.isValidDocument(fresh)
                    else {
                        throw ExtensionPeerError.rejected(
                            "The collected usage document is invalid.")
                    }
                    try UsageDataTransaction.withExclusiveAccess(dataDirectory: directory) {
                        let url = directory.appendingPathComponent("usage.json")
                        let previous = try UsageDataFiles.readRegularFile(
                            at: url, maximumBytes: 64 * 1_024 * 1_024)
                        guard
                            let merged = UsageHistory.mergeRefresh(
                                fresh: fresh, previous: previous),
                            merged.count <= 64 * 1_024 * 1_024, UsageHistory.isValidDocument(merged)
                        else {
                            throw ExtensionPeerError.rejected(
                                "Usage history could not be reconciled.")
                        }
                        try Task.checkCancellation()
                        try UsageDataFiles.write(merged, to: url)
                    }
                }
                try await withTaskCancellationHandler {
                    try await write.value
                } onCancel: {
                    write.cancel()
                }
                try Task.checkCancellation()
                guard let self, !self.stopped, self.usageID == id else { return }
                self.notice = Self.pricingNotice(fresh)
                UsageEvents.post(UsageEvents.usageUpdated)
            } catch {
                if !Task.isCancelled, let self, !self.stopped, self.usageID == id {
                    self.failure = error.localizedDescription
                    progress.record(.failure(error.localizedDescription))
                }
            }
            guard let self, self.usageID == id else { return }
            progress.close()
            self.progress = nil
            self.usageTask = nil
            self.usageID = nil
            self.refreshing = false
            UsageEvents.post(UsageEvents.refreshFinished)
        }
        return id.uuidString
    }

    public func requestLimitsRefresh() throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        guard limitsTask == nil else { return }
        let fetch = fetchLimits
        limitsTask = Task { [weak self, limitsSession] in
            let result = await fetch(limitsSession)
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.latestLimits = result
            self.limitsTask = nil
            UsageEvents.post(UsageEvents.limitsUpdated)
        }
    }

    public func waitForLimitsRefresh() async throws {
        await limitsTask?.value
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
    }

    public func startBackgroundCollection(interval: Duration = .seconds(300)) {
        guard !stopped, backgroundTask == nil, UsageExecutionEnvironment.fixtureHome == nil else {
            return
        }
        let cachedURL = dataDirectory.appendingPathComponent("usage.json")
        backgroundTask = Task { [weak self] in
            let read = Task.detached(priority: .utility) {
                try? UsageDataFiles.readRegularFile(at: cachedURL, maximumBytes: 67_108_864)
            }
            let cached = await withTaskCancellationHandler {
                await read.value
            } onCancel: {
                read.cancel()
            }
            if !Task.isCancelled, let cached, self?.stopped == false {
                self?.notice = Self.pricingNotice(cached)
            }
            while !Task.isCancelled {
                guard let self, !self.stopped else { return }
                _ = try? self.requestRefresh()
                try? self.requestLimitsRefresh()
                do { try await Task.sleep(for: interval) } catch { return }
            }
        }
    }

    public func cancelRefresh() async {
        progress?.close()
        usageTask?.cancel()
        await usageTask?.value
        usageTask = nil
        usageID = nil
        refreshing = false
    }

    public func waitForRefresh() async {
        await usageTask?.value
    }

    public static func pricingNotice(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let pricing = object["pricing"] as? [String: Any],
            let models = pricing["unpricedModels"] as? [String], !models.isEmpty
        else { return nil }
        return
            "Cost estimates are incomplete for \(models.count) unpriced model\(models.count == 1 ? "" : "s"). Token totals include this usage."
    }

    public func settingsChanged() {
        UsageEvents.post(UsageEvents.limitsUpdated)
    }

    public func beginShutdown() {
        stopped = true
        backgroundTask?.cancel()
        progress?.close()
        usageTask?.cancel()
        limitsTask?.cancel()
        usageID = nil
        refreshing = false
    }

    public func shutdown() async {
        beginShutdown()
        await backgroundTask?.value
        await limitsSession.clear()
        await usageTask?.value
        await limitsTask?.value
        usageTask = nil
        limitsTask = nil
        latestLimits = nil
        backgroundTask = nil
        progress = nil
    }
}

@MainActor
public enum UsageWorkerOperations {
    public static weak var controller: UsageWorkerController?
    public static weak var statusLineCommands: UsageStatusLineCommands?
    static var machinesProjection: UsageMachinesProjection?

    public static func forgetMachine(_ machineID: UUID) async throws {
        if let client = UsageUIClient.current {
            _ = try await client.invoke(
                "usage.machines.forget",
                payload: JSONSerialization.data(withJSONObject: [
                    "machineID": machineID.uuidString, "confirm": true,
                ]))
            return
        }
        guard let controller, let machinesProjection else { throw ExtensionPeerError.unavailable }
        await controller.cancelRefresh()
        try Task.checkCancellation()
        try await machinesProjection.forget(machineID: machineID)
    }

    @discardableResult
    public static func requestRefresh(machinePolicy: UsageMachineRefreshPolicy = .due) throws
        -> String
    {
        if let client = UsageUIClient.current {
            client.perform(
                "usage.refresh",
                object: ["machinePolicy": ["skip", "due", "all"][machinePolicy.rawValue]])
            return "remote"
        }
        guard let controller else { throw ExtensionPeerError.unavailable }
        return try controller.requestRefresh(policy: machinePolicy)
    }

    public static func requestLimitsRefresh() throws {
        if let client = UsageUIClient.current { client.perform("usage.limits.refresh"); return }
        guard let controller else { throw ExtensionPeerError.unavailable }
        try controller.requestLimitsRefresh()
    }
}
