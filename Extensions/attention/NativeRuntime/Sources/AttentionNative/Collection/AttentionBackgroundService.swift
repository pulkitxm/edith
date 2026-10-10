@_implementationOnly import EdithExtensionSupport_attention_native
@_implementationOnly import EdithExtensionUI_attention_native
import Foundation

struct AttentionRuntimeSnapshot: Codable, Sendable {
    let importedEvents: Int
    let browserListening: Bool
    let port: UInt16?
    let lastBackupAt: Date?
    var schedulingFailure: String? = nil
}

actor AttentionBackgroundService {
    private let events: AttentionEventStore
    private let repository: AttentionRepository
    nonisolated var dataRepository: AttentionRepository { repository }
    private let tracking: AttentionTrackingRuntime
    private let collectsSystemActivity: Bool
    private let cloudDirectory: URL
    private nonisolated(unsafe) let defaults: UserDefaults
    private let cloudAvailable: @Sendable () -> Bool
    private var server: AttentionIngestionServer?
    private var serverSettings: AttentionSettings?
    private var observation: NSObjectProtocol?
    private let notificationCenter: NotificationCenter
    private var lastBackupAt: Date?
    private var backupTask: Task<Void, Error>?
    private var restoreTask: Task<Void, Error>?
    private var maintenanceTask: Task<Void, Never>?
    private var maintenanceContinuation: AsyncStream<Void>.Continuation?
    private let ambientPolicy: ExtensionAmbientPolicy?
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (Duration) async throws -> Void
    private var lastPeriodicIngest: Date?
    private var settingsRefreshPending = false
    private var refreshTask: Task<Void, Never>?
    private var summaryTasks: [AttentionSummaryCacheKey: AttentionSummaryFlight] = [:]
    private var summaryCache: [AttentionSummaryCacheEntry] = []
    private var stopped = false
    private var schedulingFailure: String?
    private var agentRecorder = AttentionAgentRecorder()
    private let decider: @Sendable () async -> JevDeciding?
    private var categorizeTask: Task<AttentionCategorizeReport, Error>?
    private var lastCategorizedAt: Date?

    init(
        store: AttentionDatabase, root: URL = AttentionPaths.root,
        cloudDirectory: URL = AttentionCloudStorage.directory,
        defaults: UserDefaults = SharedDefaults.store,
        cloudAvailable: @escaping @Sendable () -> Bool = { AttentionCloudStorage.available },
        collectsSystemActivity: Bool = true,
        ambientPolicy: ExtensionAmbientPolicy? = nil,
        notificationCenter: NotificationCenter = .default,
        clock: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        decider: @escaping @Sendable () async -> JevDeciding? = {
            await AttentionJevPeer.configured()
        }
    ) {
        self.notificationCenter = notificationCenter
        self.ambientPolicy = ambientPolicy
        self.clock = clock
        self.sleep = sleep
        self.decider = decider
        self.collectsSystemActivity = collectsSystemActivity
        let events = AttentionEventStore(store: store)
        self.events = events
        let repository = AttentionRepository(root: root, eventSink: events)
        self.repository = repository
        tracking = AttentionTrackingRuntime(repository: repository) { try events.deliver($0) }
        self.cloudDirectory = cloudDirectory
        self.defaults = defaults
        self.cloudAvailable = cloudAvailable
    }

    deinit {
        categorizeTask?.cancel()
        backupTask?.cancel()
        restoreTask?.cancel()
        refreshTask?.cancel()
        maintenanceTask?.cancel()
        for flight in summaryTasks.values { flight.task.cancel() }
        server?.stop()
        if let observation { notificationCenter.removeObserver(observation) }
    }

    func start() async {
        guard !stopped, refreshTask == nil else { return }
        schedulingFailure = nil
        let (stream, continuation) = AsyncStream<Void>.makeStream(
            bufferingPolicy: .bufferingNewest(1))
        maintenanceContinuation = continuation
        observation = notificationCenter.addObserver(
            forName: Notification.Name(IPC.Name.settingsChanged), object: nil, queue: .main
        ) { [weak self] _ in
            Task { await self?.requestSettingsRefresh() }
        }
        do { try await ambientPolicy?.start { continuation.yield() } } catch {
            schedulingFailure = error.localizedDescription
            continuation.finish()
            maintenanceContinuation = nil
        }
        do { try await synchronizeTracking(settings: repository.loadSettings()) } catch {
            NSLog("Attention tracking setup failed: %@", error.localizedDescription)
        }
        guard !stopped, schedulingFailure == nil else { return }
        refreshTask = Task { [weak self] in
            for await _ in stream {
                guard !Task.isCancelled, let self else { return }
                await self.refreshMaintenance(continuation: continuation)
            }
        }
        continuation.yield()
    }

    private func refreshMaintenance(continuation: AsyncStream<Void>.Continuation) async {
        guard !stopped, !Task.isCancelled else { return }
        do {
            if settingsRefreshPending {
                settingsRefreshPending = false
                _ = try await run(now: clock())
            } else {
                try await runPeriodicMaintenance(now: clock())
            }
        } catch is CancellationError {
            return
        } catch {
            NSLog("Attention refresh failed: %@", error.localizedDescription)
        }
        await scheduleMaintenance(continuation: continuation)
    }

    private func requestSettingsRefresh() {
        guard !stopped else { return }
        settingsRefreshPending = true
        maintenanceContinuation?.yield()
    }

    func runPeriodicMaintenance(now: Date) async throws {
        guard !stopped else { throw CancellationError() }
        let interval = await ingestInterval()
        if let interval,
            now.timeIntervalSince(lastPeriodicIngest ?? .distantPast) >= interval
        {
            lastPeriodicIngest = now
            _ = try await run(now: now)
        } else {
            try await backupWhenDue(now: now)
        }
    }

    private func ingestInterval() async -> TimeInterval? {
        if let ambientPolicy { return await ambientPolicy.interval(for: "attention.ingest") }
        return 900
    }

    func nextMaintenanceDelay(now: Date) async -> TimeInterval? {
        guard !stopped else { return nil }
        var delays: [TimeInterval] = []
        if let interval = await ingestInterval() {
            delays.append(max(0, interval - now.timeIntervalSince(lastPeriodicIngest ?? now)))
        }
        if backupEligible(settings: repository.loadSettings()) {
            delays.append(max(60, 900 - now.timeIntervalSince(lastBackupAt ?? .distantPast)))
        }
        return delays.min()
    }

    private func scheduleMaintenance(
        continuation: AsyncStream<Void>.Continuation
    ) async {
        let previous = maintenanceTask
        maintenanceTask = nil
        previous?.cancel()
        await previous?.value
        guard !stopped, !Task.isCancelled,
            let delay = await nextMaintenanceDelay(now: clock())
        else { return }
        let sleep = sleep
        maintenanceTask = Task {
            do { try await sleep(.seconds(delay)) } catch { return }
            guard !Task.isCancelled else { return }
            continuation.yield()
        }
    }

    func runtimeStatus() throws -> AttentionRuntimeSnapshot {
        guard !stopped else { throw CancellationError() }
        return AttentionRuntimeSnapshot(
            importedEvents: 0, browserListening: server?.state == .ready,
            port: server?.boundPort, lastBackupAt: lastBackupAt,
            schedulingFailure: schedulingFailure)
    }

    func run(now: Date = Date()) async throws -> Data? {
        guard !stopped else { throw CancellationError() }
        guard restoreTask == nil else { return nil }
        let report = try await importSpoolWhenAvailable(now: now)
        let settings = repository.loadSettings()
        try await synchronizeTracking(settings: settings)
        if collectsSystemActivity, settings.isEnabled, settings.jevCategorizationEnabled,
            categorizeTask == nil,
            now.timeIntervalSince(lastCategorizedAt ?? .distantPast) >= 1_800
        {
            lastCategorizedAt = now
            Task { _ = try? await self.categorize() }
        }
        try await backupWhenDue(now: now)
        return try AttentionPayload.encode(
            AttentionRuntimeSnapshot(
                importedEvents: report.events, browserListening: server?.state == .ready,
                port: server?.boundPort, lastBackupAt: lastBackupAt,
                schedulingFailure: schedulingFailure))
    }

    private func synchronizeTracking(settings: AttentionSettings) async throws {
        var trackingSettings = settings
        trackingSettings.isEnabled = collectsSystemActivity && settings.isEnabled
        await tracking.sync(trackingSettings)
        guard !stopped else { throw CancellationError() }
        if collectsSystemActivity && settings.isEnabled
            && settings.browserTrackingEnabled
        {
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
    }

    private func backupEligible(settings: AttentionSettings) -> Bool {
        collectsSystemActivity && settings.iCloudBackupEnabled && cloudAvailable()
    }

    private func backupWhenDue(now: Date) async throws {
        guard !stopped, restoreTask == nil else { return }
        if backupEligible(settings: repository.loadSettings()),
            now.timeIntervalSince(lastBackupAt ?? .distantPast) >= 900
        {
            try await backup(now: now)
        }
    }

    func stop() async {
        stopped = true
        maintenanceContinuation?.finish()
        maintenanceContinuation = nil
        await ambientPolicy?.stop()
        let categorizing = categorizeTask
        categorizeTask = nil
        categorizing?.cancel()
        await tracking.stop()
        _ = await categorizing?.result
        let backup = backupTask
        let restore = restoreTask
        let maintenance = maintenanceTask
        maintenanceTask = nil
        maintenance?.cancel()
        let refresh = refreshTask
        let summaries = summaryTasks.values.map(\.task)
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
        if let observation { notificationCenter.removeObserver(observation) }
        observation = nil
        _ = try? await backup?.value
        _ = try? await restore?.value
        await refresh?.value
        await maintenance?.value
        for task in summaries { _ = await task.result }
    }

    func deliver(_ request: AttentionDeliveryRequest) throws {
        guard !stopped else { throw CancellationError() }
        try events.deliver(request)
    }

    func deliveryHealth() async throws -> AttentionDeliveryHealth {
        guard !stopped else { throw CancellationError() }
        let spool = AttentionDeliverySpool(
            file: repository.directory.appendingPathComponent("delivery-spool.json"))
        return try await spool.health()
    }

    func categorize(now: Date = Date()) async throws -> AttentionCategorizeReport {
        guard !stopped else { throw CancellationError() }
        if let categorizeTask { return try await categorizeTask.value }
        let settings = repository.loadSettings()
        guard settings.jevCategorizationEnabled, let decider = await decider() else {
            return AttentionCategorizeReport(available: false)
        }
        try importSpool()
        let events = events
        let repository = repository
        let task = Task.detached(priority: .utility) { () throws -> AttentionCategorizeReport in
            let from = now.addingTimeInterval(-7 * 86_400)
            let classifications = repository.loadClassifications()
            let summary = AttentionAnalyzer().summary(
                events: try events.events(from: from, to: now), settings: settings,
                classifications: classifications, from: from, to: now)
            let (next, report) = await AttentionJevCategorizer(
                describeApp: { AttentionAppDescriptor.describe(bundleID: $0) }
            ).run(
                summary: summary, settings: settings, classifications: classifications,
                decider: decider, now: now)
            try Task.checkCancellation()
            try repository.updateClassifications { current in
                current.entities.merge(next.entities) { _, latest in latest }
                current.titles.merge(next.titles) { _, latest in latest }
            }
            return report
        }
        categorizeTask = task
        defer {
            categorizeTask = nil
            lastCategorizedAt = now
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    nonisolated func tracksAgents() -> Bool {
        let settings = repository.loadSettings()
        return true && settings.isEnabled
            && settings.agentTrackingEnabled
    }

    func recordAgents(_ hosts: [AttentionAgentHost], now: Date = Date()) async throws {
        guard !stopped else { return }
        let settings = repository.loadSettings()
        guard true, settings.isEnabled,
            settings.agentTrackingEnabled
        else {
            agentRecorder = AttentionAgentRecorder()
            return
        }
        var observed = agentRecorder.observe(hosts, now: now)
        guard !observed.isEmpty else { return }
        if !settings.windowTitlesEnabled {
            for index in observed.indices { observed[index].windowTitle = nil }
        }
        try await events.record(AttentionBatch(events: observed), now: now)
    }

    nonisolated func updateContext(_ context: AttentionAppContext) {
        AttentionContextBoard.shared.update(context)
    }

    func record(_ batch: AttentionBatch) async throws {
        try importSpool()
        try await events.record(batch, now: Date())
    }

    func range(_ request: AttentionRangeRequest) throws -> AttentionRangeResponse {
        try importSpool()
        return AttentionRangeResponse(events: try events.events(from: request.from, to: request.to))
    }

    func hasEvents() throws -> Bool {
        try importSpool()
        return try events.hasEvents()
    }

    func summary(_ request: AttentionSummaryRequest, now: Date = Date()) async throws
        -> AttentionPageSnapshot
    {
        guard !stopped else { throw CancellationError() }
        try importSpool()
        let request = try request.coveringAllTime(
            since: request.allTime ? events.firstEventDate() : nil)
        let settings = request.settings ?? repository.loadSettings()
        let key = try summaryKey(request, settings: settings)
        let live = request.to > now.addingTimeInterval(-120)
        if let index = summaryCache.firstIndex(where: { entry in
            entry.key == key
                && (live
                    ? now.timeIntervalSince(entry.computedAt) <= 10
                        && entry.to >= request.to.addingTimeInterval(-15)
                    : entry.to == request.to)
        }) {
            let entry = summaryCache.remove(at: index)
            summaryCache.insert(entry, at: 0)
            return entry.snapshot.trimmed(to: request.parts)
        }
        if let flight = summaryTasks[key] {
            return try await flight.task.value.trimmed(to: request.parts)
        }
        if summaryTasks.count >= 3,
            let oldest = summaryTasks.min(by: { $0.value.startedAt < $1.value.startedAt })
        {
            oldest.value.task.cancel()
            summaryTasks[oldest.key] = nil
        }
        let events = events
        let repository = repository
        let full = AttentionSummaryRequest(
            from: request.from, to: request.to, settings: settings,
            comparePeriod: request.comparePeriod, window: request.window)
        let task = Task.detached(priority: .userInitiated) { () throws -> AttentionPageSnapshot in
            try Task.checkCancellation()
            let previous = try full.previousInterval.map {
                try events.events(from: $0.start, to: $0.end)
            }
            try Task.checkCancellation()
            let result = try AttentionPageSnapshot(
                request: full, repository: repository,
                all: events.events(from: full.from, to: full.to), previous: previous,
                hasStoredEvents: events.hasEvents())
            try Task.checkCancellation()
            return result
        }
        let id = UUID()
        summaryTasks[key] = AttentionSummaryFlight(id: id, task: task, startedAt: now)
        defer { if summaryTasks[key]?.id == id { summaryTasks[key] = nil } }
        let snapshot = try await task.value
        summaryCache.removeAll { $0.key == key }
        summaryCache.insert(
            AttentionSummaryCacheEntry(
                key: key, to: request.to, computedAt: Date(), snapshot: snapshot),
            at: 0)
        if summaryCache.count > 6 { summaryCache.removeLast(summaryCache.count - 6) }
        return snapshot.trimmed(to: request.parts)
    }

    private static let summaryKeyEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private func summaryKey(_ request: AttentionSummaryRequest, settings: AttentionSettings)
        throws -> AttentionSummaryCacheKey
    {
        var settings = settings
        settings.serverToken = ""
        settings.serverPort = 0
        let classifications = try Self.summaryKeyEncoder.encode(repository.loadClassifications())
        let identity = try Self.summaryKeyEncoder.encode(
            AttentionSummaryIdentity(
                from: request.from, window: request.window, comparePeriod: request.comparePeriod,
                settings: settings))
        return AttentionSummaryCacheKey(identity: identity, classifications: classifications)
    }

    @discardableResult
    func importSpool() throws -> AttentionImportReport {
        guard !stopped else { throw CancellationError() }
        return try events.importLegacyFiles(directory: repository.eventsDirectory)
    }

    private func importSpoolWhenAvailable(now: Date) async throws -> AttentionImportReport {
        for attempt in 0..<5 {
            guard !stopped else { throw CancellationError() }
            guard restoreTask == nil else {
                throw AttentionServiceError(.unavailable, "Attention is restoring an archive.")
            }
            try Task.checkCancellation()
            do {
                return try events.importLegacyFiles(directory: repository.eventsDirectory, now: now)
            } catch let error as CocoaError where error.code == .fileLocking && attempt < 4 {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        throw CocoaError(.fileLocking)
    }

    func backup(now: Date = Date()) async throws {
        guard !stopped else { throw CancellationError() }
        guard restoreTask == nil else {
            throw AttentionServiceError(.unavailable, "Attention is restoring an archive.")
        }
        if let backupTask {
            try await backupTask.value
            return
        }
        guard cloudAvailable() else {
            throw AttentionServiceError("iCloud Drive is unavailable.")
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

    func restore() async throws {
        guard !stopped else { throw CancellationError() }
        if let restoreTask { return try await restoreTask.value }
        guard backupTask == nil else {
            throw AttentionServiceError(.unavailable, "Attention is creating an archive.")
        }
        guard cloudAvailable() else { throw AttentionServiceError("iCloud Drive is unavailable.") }
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
                _ = try AttentionPayload.decode(AttentionSettings.self, from: data)
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

struct AttentionSummaryFlight {
    let id: UUID
    let task: Task<AttentionPageSnapshot, Error>
    let startedAt: Date
}

struct AttentionSummaryCacheEntry {
    let key: AttentionSummaryCacheKey
    let to: Date
    let computedAt: Date
    let snapshot: AttentionPageSnapshot
}

struct AttentionSummaryCacheKey: Hashable {
    let identity: Data
    let classifications: Data
}

private struct AttentionSummaryIdentity: Encodable {
    let from: Date
    let window: AttentionTimeWindow
    let comparePeriod: TimeInterval?
    let settings: AttentionSettings
}
