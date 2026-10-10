import EdithExtensionSupport
import CoreFoundation
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
    var refreshRecording: UsageRefreshRecorder? { refreshRecorder }
    private var backgroundTask: Task<Void, Never>?
    private var backgroundSleepTask: Task<Void, Never>?
    private var backgroundContinuation: AsyncStream<Void>.Continuation?
    private let ambientPolicy: ExtensionAmbientPolicy
    private let allowsBackgroundCollection: @MainActor () -> Bool
    private let clock: @MainActor () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var periodicAdmissions: [String: Date] = [:]
    private let fetchLimits: FetchLimits
    private let collect: Collect
    private let dataDirectory: URL
    private let limitsSession = LimitsRefreshSession()
    private var usageTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var refreshWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var limitsWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var usageID: UUID?
    private var stopped = false

    public init(
        dataDirectory: URL = Repo.dataDir,
        fetchLimits: @escaping FetchLimits = { session in
            await LimitsCollector.refresh(force: true, refreshSession: session, announce: { _ in })
        },
        ambientPolicy: ExtensionAmbientPolicy? = nil,
        allowsBackgroundCollection: @escaping @MainActor () -> Bool = {
            UsageExecutionEnvironment.fixtureHome == nil
        },
        clock: @escaping @MainActor () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }, collect: @escaping Collect
    ) {
        self.ambientPolicy =
            ambientPolicy
            ?? ExtensionAmbientPolicy(jobs: [
                "usage.refresh": ExtensionAmbientCadence(ambient: 900),
                "usage.limits": ExtensionAmbientCadence(ambient: 900, live: 300),
            ])
        self.allowsBackgroundCollection = allowsBackgroundCollection
        self.clock = clock
        self.sleep = sleep
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
                    recorder.record(.failure(error.localizedDescription))
                }
            }
            guard let self, self.usageID == id else { return }
            progress.close()
            self.progress = nil
            self.usageTask = nil
            self.usageID = nil
            self.refreshing = false
            self.finishRefreshWaiters()
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
            self.finishLimitsWaiters()
            UsageEvents.post(UsageEvents.limitsUpdated)
        }
    }

    public func waitForLimitsRefresh() async throws {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard limitsTask != nil, !Task.isCancelled else {
                    continuation.resume(); return
                }
                limitsWaiters[token] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.limitsWaiters.removeValue(forKey: token)?.resume()
            }
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
    }

    func applyAmbientPolicy(context: NSDictionary) throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        try ambientPolicy.apply(context: context)
    }

    func synchronizeAmbientPolicy(context: NSDictionary, explicit: () -> Void) throws {
        let policyOnly: Bool
        if let value = context["ambientPolicyOnly"] {
            guard let number = value as? NSNumber,
                CFGetTypeID(number) == CFBooleanGetTypeID()
            else { throw ExtensionPeerError.invalidRequest }
            policyOnly = number.boolValue
        } else {
            policyOnly = false
        }
        try applyAmbientPolicy(context: context)
        if !policyOnly { explicit() }
    }

    func requestPeriodicCollection(now: Date) throws {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        for job in ["usage.refresh", "usage.limits"] {
            guard let interval = ambientPolicy.interval(for: job),
                now.timeIntervalSince(periodicAdmissions[job] ?? .distantPast) >= interval
            else { continue }
            if job == "usage.refresh" {
                _ = try requestRefresh()
            } else {
                try requestLimitsRefresh()
            }
            periodicAdmissions[job] = now
        }
    }

    func nextPeriodicDelay(now: Date) -> TimeInterval? {
        guard !stopped else { return nil }
        return ["usage.refresh", "usage.limits"].compactMap { job in
            ambientPolicy.interval(for: job).map { interval in
                max(0, interval - now.timeIntervalSince(periodicAdmissions[job] ?? now))
            }
        }.min()
    }

    public func startBackgroundCollection() {
        guard !stopped, backgroundTask == nil, allowsBackgroundCollection() else {
            return
        }
        let (events, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        backgroundContinuation = continuation
        do { try ambientPolicy.start { continuation.yield() } } catch {
            failure = error.localizedDescription
            continuation.finish()
            backgroundContinuation = nil
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
            for await _ in events {
                guard !Task.isCancelled, let self, !self.stopped else { return }
                let previous = backgroundSleepTask
                previous?.cancel()
                await previous?.value
                guard !Task.isCancelled, !stopped else { return }
                let now = clock()
                try? requestPeriodicCollection(now: now)
                guard let delay = nextPeriodicDelay(now: now) else {
                    backgroundSleepTask = nil
                    continue
                }
                let sleep = sleep
                backgroundSleepTask = Task {
                    do { try await sleep(.seconds(delay)) } catch { return }
                    guard !Task.isCancelled else { return }
                    continuation.yield()
                }
            }
        }
        continuation.yield()
    }

    public func cancelRefresh(matching identifier: String? = nil) async {
        if let identifier, usageID?.uuidString != identifier { return }
        let id = usageID
        let task = usageTask
        progress?.close()
        task?.cancel()
        await task?.value
        guard usageID == id else { return }
        usageTask = nil
        usageID = nil
        refreshing = false
        finishRefreshWaiters()
    }

    public func waitForRefresh() async {
        let token = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard usageTask != nil, !Task.isCancelled else {
                    continuation.resume(); return
                }
                refreshWaiters[token] = continuation
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.refreshWaiters.removeValue(forKey: token)?.resume()
            }
        }
    }

    private func finishRefreshWaiters() {
        let pending = refreshWaiters.values
        refreshWaiters.removeAll()
        for continuation in pending { continuation.resume() }
    }

    private func finishLimitsWaiters() {
        let pending = limitsWaiters.values
        limitsWaiters.removeAll()
        for continuation in pending { continuation.resume() }
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
        ambientPolicy.stop()
        backgroundContinuation?.finish()
        backgroundSleepTask?.cancel()
        backgroundTask?.cancel()
        progress?.close()
        usageTask?.cancel()
        limitsTask?.cancel()
        usageID = nil
        refreshing = false
        finishRefreshWaiters()
        finishLimitsWaiters()
    }

    public func shutdown() async {
        beginShutdown()
        await backgroundTask?.value
        await backgroundSleepTask?.value
        backgroundSleepTask = nil
        backgroundContinuation = nil
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
