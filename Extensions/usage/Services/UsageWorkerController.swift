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
    public typealias Collect = @Sendable (UsageMachineRefreshPolicy) async throws -> Data
    public private(set) var latestLimits: LimitsTopicSnapshot?
    public private(set) var refreshing = false
    public private(set) var failure: String?
    private let collect: Collect
    private let dataDirectory: URL
    private let limitsSession = LimitsRefreshSession()
    private var usageTask: Task<Void, Never>?
    private var limitsTask: Task<Void, Never>?
    private var usageID: UUID?
    private var stopped = false

    public init(dataDirectory: URL = Repo.dataDir, collect: @escaping Collect) {
        self.dataDirectory = dataDirectory
        self.collect = collect
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
        usageTask = Task { [weak self] in
            do {
                let fresh = try await collect(policy)
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
                UsageEvents.post(UsageEvents.usageUpdated)
            } catch {
                if !Task.isCancelled, let self, !self.stopped, self.usageID == id {
                    self.failure = error.localizedDescription
                }
            }
            guard let self, self.usageID == id else { return }
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
        limitsTask = Task { [weak self, limitsSession] in
            let result = await LimitsCollector.refresh(
                force: true, refreshSession: limitsSession, announce: { _ in })
            guard !Task.isCancelled, let self, !self.stopped else { return }
            self.latestLimits = result
            self.limitsTask = nil
            UsageEvents.post(UsageEvents.limitsUpdated)
        }
    }

    public func settingsChanged() {
        UsageEvents.post(UsageEvents.limitsUpdated)
    }

    public func shutdown() async {
        stopped = true
        usageTask?.cancel()
        limitsTask?.cancel()
        usageID = nil
        refreshing = false
        await limitsSession.clear()
        await usageTask?.value
        await limitsTask?.value
        usageTask = nil
        limitsTask = nil
        latestLimits = nil
    }
}

@MainActor
public enum UsageWorkerOperations {
    public static weak var controller: UsageWorkerController?

    @discardableResult
    public static func requestRefresh(machinePolicy: UsageMachineRefreshPolicy = .due) throws
        -> String
    {
        guard let controller else { throw ExtensionPeerError.unavailable }
        return try controller.requestRefresh(policy: machinePolicy)
    }

    public static func requestLimitsRefresh() throws {
        guard let controller else { throw ExtensionPeerError.unavailable }
        try controller.requestLimitsRefresh()
    }
}
