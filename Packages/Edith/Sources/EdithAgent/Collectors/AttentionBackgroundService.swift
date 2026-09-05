import EdithKit
import Foundation

public struct AttentionRuntimeSnapshot: Codable, Sendable {
    public let importedEvents: Int
    public let browserListening: Bool
    public let port: UInt16?
    public let lastBackupAt: Date?
}

public actor AttentionBackgroundService {
    private let events: AttentionEventStore
    private let repository: AttentionRepository
    private let cloudDirectory: URL
    private let defaults: UserDefaults
    private let cloudAvailable: @Sendable () -> Bool
    private var server: AttentionIngestionServer?
    private var serverSettings: AttentionSettings?
    private var observation: NSObjectProtocol?
    private var lastBackupAt: Date?
    private var backupTask: Task<Void, Error>?
    private var restoreTask: Task<Void, Error>?
    private var refreshTask: Task<Void, Never>?
    private var summaryTasks: [UUID: Task<AttentionPageSnapshot, Error>] = [:]
    private var stopped = false

    public init(
        store: AgentStore, root: URL = AttentionPaths.root,
        cloudDirectory: URL = AppData.cloudDir.appendingPathComponent("Attention"),
        defaults: UserDefaults = SharedDefaults.store,
        cloudAvailable: @escaping @Sendable () -> Bool = { AppData.cloudAvailable }
    ) {
        let events = AttentionEventStore(store: store)
        self.events = events
        repository = AttentionRepository(root: root, eventSink: events)
        self.cloudDirectory = cloudDirectory
        self.defaults = defaults
        self.cloudAvailable = cloudAvailable
    }

    deinit {
        backupTask?.cancel()
        restoreTask?.cancel()
        refreshTask?.cancel()
        for task in summaryTasks.values { task.cancel() }
        server?.stop()
        if let observation { IPC.stopObserving(observation) }
    }

    public func start() {
        guard !stopped, refreshTask == nil else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        observation = IPC.observe(IPC.Name.settingsChanged) { continuation.yield() }
        refreshTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled else { return }
                do { _ = try await self?.run() } catch is CancellationError {
                    return
                } catch {
                    AgentLog.logger.error(
                        "attention refresh failed: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        continuation.yield()
    }

    public func run(now: Date = Date()) async throws -> Data? {
        guard !stopped else { throw CancellationError() }
        guard restoreTask == nil else { return nil }
        let report = try events.importLegacyFiles(directory: repository.eventsDirectory, now: now)
        let settings = repository.loadSettings()
        let enabled = defaults.bool(forKey: AppStorageKeys.Tabs.attentionEnabled)
        if enabled && settings.isEnabled && settings.browserTrackingEnabled {
            if serverSettings != settings || server?.state == .stopped || server == nil {
                server?.stop()
                let next = AttentionIngestionServer(repository: repository, settings: settings)
                try next.start()
                server = next
                serverSettings = settings
            } else if case .failed = server?.state {
                server?.stop()
                server = nil
                serverSettings = nil
            }
        } else {
            server?.stop()
            server = nil
            serverSettings = nil
        }
        if settings.iCloudBackupEnabled, cloudAvailable(),
            now.timeIntervalSince(lastBackupAt ?? .distantPast) >= 900
        {
            try await backup(now: now)
        }
        return try AgentPayload.encode(
            AttentionRuntimeSnapshot(
                importedEvents: report.events, browserListening: server?.state == .ready,
                port: server?.boundPort, lastBackupAt: lastBackupAt))
    }

    public func stop() async {
        stopped = true
        let backup = backupTask
        let restore = restoreTask
        let refresh = refreshTask
        let summaries = Array(summaryTasks.values)
        backupTask = nil
        restoreTask = nil
        refreshTask = nil
        summaryTasks.removeAll()
        backup?.cancel()
        restore?.cancel()
        refresh?.cancel()
        for task in summaries { task.cancel() }
        server?.stop()
        server = nil
        serverSettings = nil
        if let observation { IPC.stopObserving(observation) }
        observation = nil
        _ = try? await backup?.value
        _ = try? await restore?.value
        await refresh?.value
        for task in summaries { _ = await task.result }
    }

    public func record(_ batch: AttentionBatch) throws {
        try importSpool()
        try events.record(batch)
    }

    public func range(_ request: AttentionRangeRequest) throws -> AttentionRangeResponse {
        try importSpool()
        return AttentionRangeResponse(events: try events.events(from: request.from, to: request.to))
    }

    public func hasEvents() throws -> Bool {
        try importSpool()
        return try events.hasEvents()
    }

    public func summary(_ request: AttentionSummaryRequest) async throws -> AttentionPageSnapshot {
        guard !stopped else { throw CancellationError() }
        guard summaryTasks.count < 2 else {
            throw AgentError(
                .unavailable, "Attention is processing two summaries. Try again shortly.")
        }
        try importSpool()
        let events = events
        let repository = repository
        let id = UUID()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try AttentionPageSnapshot(
                request: request, repository: repository,
                all: events.events(from: request.from, to: request.to),
                hasStoredEvents: events.hasEvents())
            try Task.checkCancellation()
            return result
        }
        summaryTasks[id] = task
        defer { summaryTasks[id] = nil }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    @discardableResult
    public func importSpool() throws -> AttentionImportReport {
        guard !stopped else { throw CancellationError() }
        return try events.importLegacyFiles(directory: repository.eventsDirectory)
    }

    public func backup(now: Date = Date()) async throws {
        guard !stopped else { throw CancellationError() }
        guard restoreTask == nil else {
            throw AgentError(.unavailable, "Attention is restoring an archive.")
        }
        if let backupTask {
            try await backupTask.value
            return
        }
        guard cloudAvailable() else {
            throw AgentStoreError("iCloud Drive is unavailable.")
        }
        try importSpool()
        let events = events
        let directory = repository.directory
        let cloudDirectory = cloudDirectory
        let task = Task.detached(priority: .utility) {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("attention-backup-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try Task.checkCancellation()
            try AttentionCloudBackup(localDirectory: directory, cloudDirectory: staging)
                .backup(now: now)
            try events.exportEvents(to: staging.appendingPathComponent("events"), now: now)
            try Task.checkCancellation()
            try AttentionCloudBackup(localDirectory: staging, cloudDirectory: cloudDirectory)
                .backup(now: now)
        }
        backupTask = task
        defer { backupTask = nil }
        do {
            try await task.value
            lastBackupAt = now
        } catch {
            task.cancel()
            throw error
        }
    }

    public func restore() async throws {
        guard !stopped else { throw CancellationError() }
        if let restoreTask { return try await restoreTask.value }
        guard backupTask == nil else {
            throw AgentError(.unavailable, "Attention is creating an archive.")
        }
        guard cloudAvailable() else { throw AgentStoreError("iCloud Drive is unavailable.") }
        guard try !hasEvents() else { throw AttentionCloudBackupError.localStoreNotEmpty }
        server?.stop()
        server = nil
        serverSettings = nil
        let events = events
        let directory = repository.directory
        let cloudDirectory = cloudDirectory
        let task = Task.detached(priority: .utility) {
            let staging = FileManager.default.temporaryDirectory
                .appendingPathComponent("attention-restore-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try AttentionCloudBackup(localDirectory: staging, cloudDirectory: cloudDirectory)
                .restoreWhenLocalStoreIsEmpty()
            let stagedEvents = staging.appendingPathComponent(".events")
            let originalEvents = staging.appendingPathComponent("events")
            if FileManager.default.fileExists(atPath: originalEvents.path) {
                try FileManager.default.moveItem(at: originalEvents, to: stagedEvents)
            } else {
                try FileManager.default.createDirectory(
                    at: stagedEvents, withIntermediateDirectories: true)
            }
            let settings = staging.appendingPathComponent("settings.json")
            if let data = try UsageDataFiles.readRegularFile(at: settings, maximumBytes: 1_048_576)
            {
                _ = try AgentPayload.decode(AttentionSettings.self, from: data)
            }
            let publication = try AttentionArchivePublication(
                source: staging, destination: directory)
            do {
                try events.restoreEvents(from: stagedEvents) { try publication.publish() }
                publication.finish()
            } catch {
                try publication.rollback()
                throw error
            }
        }
        restoreTask = task
        defer {
            restoreTask = nil
            IPC.post(IPC.Name.settingsChanged)
        }
        try await task.value
    }
}

public enum AttentionBackgroundOperations {
    public static func register(on runtime: AgentRuntime, service: AttentionBackgroundService) async
    {
        await runtime.registerShutdown(id: "attention") { await service.stop() }
        await service.start()
        await runtime.register(operation: AttentionOperation.record) { payload in
            let batch = try AgentPayload.decode(AttentionBatch.self, from: payload)
            try await service.record(batch)
            return try AgentPayload.encode(["recorded": batch.events.count])
        }
        await runtime.register(operation: AttentionOperation.range) { payload in
            let request = try AgentPayload.decode(AttentionRangeRequest.self, from: payload)
            return try await AgentPayload.encode(service.range(request))
        }
        await runtime.register(operation: AttentionOperation.hasEvents) { _ in
            try await AgentPayload.encode(service.hasEvents())
        }
        await runtime.register(operation: AttentionOperation.importLegacy) { _ in
            try await AgentPayload.encode(service.importSpool())
        }
        await runtime.register(operation: AttentionOperation.summary) { payload in
            let request = try AgentPayload.decode(AttentionSummaryRequest.self, from: payload)
            return try await AgentPayload.encode(service.summary(request))
        }
        await runtime.register(operation: AttentionOperation.backup) { _ in
            try await service.backup()
            return Data()
        }
        await runtime.register(operation: AttentionOperation.restore) { _ in
            try await service.restore()
            return Data()
        }
    }
}
