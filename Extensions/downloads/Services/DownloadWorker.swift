import EdithExtensionSupport
import EdithExtensionUI
import Foundation

private final class DownloadWorkerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private var bytes = 0
    private var revision = 0
    private var progress: DownloadStatus?

    func append(_ line: String) {
        let line = String(decoding: line.utf8.prefix(4_000), as: UTF8.self)
        lock.withLock {
            lines.append(line)
            bytes += line.utf8.count + 1
            revision += 1
            while bytes > 64_000, !lines.isEmpty { bytes -= lines.removeFirst().utf8.count + 1 }
            if line.contains("[download]") {
                let parsed = YoutubeDownloader.parseProgress(from: line)
                progress = .downloading(
                    progress: parsed.progress, videoIndex: parsed.videoIndex,
                    videoCount: parsed.videoCount)
            }
        }
    }

    var snapshot: (String, DownloadStatus?, Int) {
        lock.withLock { (lines.joined(separator: "\n"), progress, revision) }
    }
}

private struct DownloadSchedulerActivity: Codable {
    var generation: UUID?
    var active: [UUID] = []
    var logs: [String: String] = [:]

    static func file(for queue: URL) -> URL { queue.appendingPathExtension("activity.json") }

    static func read(queue: URL) throws -> Self {
        try PersistentJSONFile.read(Self.self, from: file(for: queue), missing: Self())
    }

    static func write(
        queue: URL, generation: UUID, active: [UUID], logs: [String: String], retained: [UUID]
    ) throws {
        let file = file(for: queue)
        let lease = try PersistentFileLease.acquire(
            at: file.appendingPathExtension("lock"), waits: true)
        try withExtendedLifetime(lease) {
            var value = (try? read(queue: queue)) ?? Self()
            value.generation = generation
            value.active = active
            value.logs.merge(logs) { _, latest in latest }
            value.logs = boundedLogs(value.logs, retained: retained)
            try JSONEncoder().encode(value).write(to: file, options: .atomic)
        }
    }

    static func boundedLogs(_ logs: [String: String], retained: [UUID]) -> [String: String] {
        var bounded: [String: String] = [:]
        var remaining = 256_000
        for id in retained.prefix(32) {
            guard let log = logs[id.uuidString], remaining > 0 else { continue }
            var text = String(decoding: log.utf8.suffix(min(64_000, remaining)), as: UTF8.self)
            while text.utf8.count > min(64_000, remaining) { text.removeFirst() }
            bounded[id.uuidString] = text
            remaining -= text.utf8.count
        }
        return bounded
    }
}

public actor DownloadWorker {
    public static let shared = DownloadWorker()
    private var subscribers: [UUID: AsyncStream<DownloadWorkerSnapshot>.Continuation] = [:]
    public func values() throws -> AsyncStream<DownloadWorkerSnapshot> {
        try start()
        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            subscribers[id] = continuation
            continuation.yield(snapshot())
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }
    private func removeSubscriber(_ id: UUID) { subscribers.removeValue(forKey: id) }

    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult
    public typealias Publish = @Sendable (DownloadWorkerSnapshot) async -> Void

    private let file: URL
    public nonisolated var historyFile: URL { file }
    private let executable: @Sendable () -> URL?
    private let galleryExecutable: @Sendable () -> URL?
    private let isEnabled: @Sendable () -> Bool
    private let runCommand: RunCommand
    private let publish: Publish
    private let completed: @Sendable () async -> Void
    private var records: [DownloadRecord]
    private let loadError: String?
    private var persistenceError: String?
    private var readError: String?
    private var activityReadError: String?
    private var activityPersistenceError: String?
    private struct Flight {
        var token: UUID
        var task: Task<Void, Never>
        var progress: Task<Void, Never>?
        var output: DownloadWorkerOutput
        var publishedRevision: Int
    }

    static let maximumConcurrent = 3
    private var logs: [String: String] = [:]
    private var flights: [UUID: Flight] = [:]
    private var retiredFlights: [UUID: Task<Void, Never>] = [:]
    private var stopTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var started = false
    private var stopping = false
    private let generation = UUID()
    private var revision = 0
    private var snapshotDirty = false
    private var publicationTask: Task<Void, Never>?
    private var observationTask: Task<Void, Never>?
    private var schedulerLease: PersistentFileLease?
    private var estimates: [UUID: Task<CLICommandResult, Error>] = [:]

    public init(
        file: URL = DownloadQueue.file,
        executable: @escaping @Sendable () -> URL? = {
            CLIToolEnvironment.executable(named: "yt-dlp")
        },
        galleryExecutable: @escaping @Sendable () -> URL? = {
            CLIToolEnvironment.executable(named: "gallery-dl")
        },
        isEnabled: @escaping @Sendable () -> Bool = {
            true
        },
        runCommand: @escaping RunCommand = { request, line in
            try await CLICommandRunner.runLocalSeparated(
                request, streamsWhileRunning: true,
                onStandardOutputLine: line, onStandardErrorLine: line)
        },
        publish: @escaping Publish = { _ in }, completed: @escaping @Sendable () async -> Void = {}
    ) {
        self.file = file
        self.executable = executable
        self.galleryExecutable = galleryExecutable
        self.isEnabled = isEnabled
        self.runCommand = runCommand
        self.publish = publish
        self.completed = completed
        do {
            records = try DownloadQueue.read(from: file)
            loadError = nil
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            records = []
            loadError = nil
        } catch {
            records = []
            loadError = "The download queue could not be read: \(error.localizedDescription)"
        }
    }

    deinit {
        for flight in flights.values {
            flight.task.cancel()
            flight.progress?.cancel()
        }
        publicationTask?.cancel()
        observationTask?.cancel()
        for task in estimates.values { task.cancel() }
    }

    public func start() throws {
        if let loadError { throw DownloadsError(loadError) }
        guard !started, !stopping else { return }
        started = true
        startNext()
        observationTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                await refresh()
            }
        }
        notify()
    }

    public func cancelPendingWork() {
        stopping = true
        started = false
        observationTask?.cancel()
        for flight in flights.values {
            flight.task.cancel()
            flight.progress?.cancel()
        }
        for task in retiredFlights.values { task.cancel() }
        for task in estimates.values { task.cancel() }
    }

    public func cancelPendingWorkAndWait() async {
        cancelPendingWork()
        if let drainTask { await drainTask.value; return }
        let task = Task { await finishDrain() }
        drainTask = task
        await task.value
    }

    public func stop() async {
        cancelPendingWork()
        if let stopTask { await stopTask.value; return }
        let task = Task {
            await cancelPendingWorkAndWait()
            schedulerLease = nil
            for continuation in subscribers.values { continuation.finish() }
            subscribers.removeAll()
        }
        stopTask = task
        await task.value
    }

    private func finishDrain() async {
        let observation = observationTask
        let running = Array(flights.keys)
        for id in running { interrupt(id, reason: "Downloads stopped.") }
        let retired = Array(retiredFlights.values)
        let tasks = flights.values.map(\.task)
        let progressTasks = flights.values.compactMap(\.progress)
        let estimates = Array(self.estimates.values)
        for task in estimates { task.cancel() }
        for flight in flights.values {
            flight.task.cancel()
            flight.progress?.cancel()
        }
        await observation?.value
        observationTask = nil
        for task in tasks { await task.value }
        for task in retired { await task.value }
        for task in Array(retiredFlights.values) { await task.value }
        for task in progressTasks { await task.value }
        for task in estimates { _ = await task.result }
        self.estimates.removeAll()
        notify()
        await publicationTask?.value
    }

    public func snapshot() -> DownloadWorkerSnapshot {
        reload()
        revision += 1
        var snapshotRecords = records
        let activity = sharedActivity()
        var snapshotLogs = activity.logs
        for (id, flight) in flights {
            let buffer = flight.output.snapshot
            snapshotLogs[id.uuidString] = buffer.0
            if let index = snapshotRecords.firstIndex(where: { $0.id == id }),
                Self.isRunning(snapshotRecords[index]), let status = buffer.1
            {
                snapshotRecords[index].status = status
            }
        }
        let active = Set(flights.keys).union(activity.active).sorted {
            $0.uuidString < $1.uuidString
        }
        let retained = active + snapshotRecords.map(\.id).filter { !active.contains($0) }
        snapshotLogs = DownloadSchedulerActivity.boundedLogs(snapshotLogs, retained: retained)
        return DownloadWorkerSnapshot(
            records: snapshotRecords, logs: snapshotLogs, enabled: isEnabled(),
            running: !flights.isEmpty, generation: generation, revision: revision,
            problem: loadError ?? readError ?? persistenceError ?? activityReadError
                ?? activityPersistenceError, executable: executable(),
            runningCount: max(flights.count, activity.active.count)
        )
    }

    public func refresh() {
        guard !stopping else { return }
        reload()
        for id in flights.keys where !records.contains(where: { $0.id == id && Self.isRunning($0) })
        {
            flights[id]?.task.cancel()
        }
        if !isEnabled() {
            for id in Array(flights.keys) {
                interrupt(id, reason: "Downloads are disabled.")
            }
        }
        startNext()
        notify()
    }

    public func mutate(_ request: DownloadsMutation) throws -> DownloadsMutationResult {
        guard !stopping else { throw DownloadsError("Downloads are shutting down.") }
        if let loadError { throw DownloadsError(loadError) }
        let previousLogs = logs
        var cancelIDs = Set<UUID>()
        var changed = 0
        var added: [DownloadRecord] = []
        do {
            let updated = try DownloadQueue.update(file: file) { records in
                switch request {
                case let .enqueue(urls, prefix, kind, outputDirectory, browser):
                    guard urls.count <= 100, !urls.isEmpty,
                        records.count(where: { !$0.isFinished }) + urls.count <= 128,
                        urls.allSatisfy(MediaDownloadInput.isValid),
                        prefix.utf8.count <= 200, !prefix.contains("/"), !prefix.contains("\\"),
                        !prefix.contains(where: { $0.isNewline }),
                        outputDirectory.isFileURL
                    else { throw DownloadsError("The download request is invalid.") }
                    try FileManager.default.createDirectory(
                        at: outputDirectory, withIntermediateDirectories: true)
                    let template = DownloadQueue.outputTemplate(
                        prefix: prefix, directory: outputDirectory)
                    added = urls.map {
                        DownloadRecord(
                            url: $0, status: .queued, outputFilename: template, createdAt: Date(),
                            kind: kind, browser: browser)
                    }
                    records.insert(contentsOf: added, at: 0)
                    changed = added.count
                case let .retry(id, all):
                    for index in records.indices
                    where (all || records[index].id == id) && records[index].canRetry {
                        guard flights[records[index].id] == nil else { continue }
                        records[index].status = .queued
                        changed += 1
                    }
                case let .cancel(id, includeQueued, reason):
                    for index in records.indices where id == nil || records[index].id == id {
                        guard !records[index].isFinished,
                            includeQueued || records[index].status != .queued
                        else { continue }
                        records[index].status = .interrupted(String(reason.prefix(200)))
                        changed += 1
                        if flights[records[index].id] != nil { cancelIDs.insert(records[index].id) }
                    }
                case let .remove(id):
                    changed = records.count { $0.id == id }
                    records.removeAll { $0.id == id }
                    logs[id.uuidString] = nil
                    if flights[id] != nil { cancelIDs.insert(id) }
                case let .clear(includeActive):
                    let removed = records.filter { includeActive || $0.isFinished }
                    let ids = Set(removed.map(\.id))
                    records.removeAll { ids.contains($0.id) }
                    for id in ids { logs[id.uuidString] = nil }
                    cancelIDs.formUnion(ids.intersection(flights.keys))
                    changed = removed.count
                }
            }
            records = updated.0
            persistenceError = nil
        } catch {
            logs = previousLogs
            persistenceError =
                "The download queue could not be saved: \(error.localizedDescription)"
            throw error
        }
        for id in cancelIDs { flights[id]?.task.cancel() }
        let result = DownloadsMutationResult(changed: changed, records: records, added: added)
        startNext()
        notify()
        return result
    }

    public func estimate(_ url: URL) async throws -> DownloadEstimate? {
        guard !stopping else { throw DownloadsError("Downloads are shutting down.") }
        guard MediaDownloadInput.isValid(url) else {
            throw DownloadsError("Enter a valid download URL.")
        }
        guard let executable = executable() else { throw DownloadToolOperationError.missing }
        guard estimates.count < 8 else { throw DownloadsError("The estimate queue is full.") }
        let id = UUID()
        let runCommand = runCommand
        let task = Task {
            try await runCommand(
                CLICommandRequest(
                    executableURL: executable,
                    arguments: [
                        "--ignore-config", "--no-update", "--no-playlist", "--skip-download", "-J",
                        "--", url.absoluteString,
                    ],
                    environment: CLIToolEnvironment.sanitized(), timeout: 30,
                    maximumOutputBytes: 2 << 20, discardsStandardError: true,
                    terminatesProcessGroup: true), { _ in })
        }
        estimates[id] = task
        defer { estimates[id] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        return result.terminationStatus == 0
            ? DownloadSizeParser.estimate(fromJSON: result.standardOutputData) : nil
    }

    private func startNext() {
        guard started, !stopping else { return }
        if !isEnabled() || executable() == nil {
            if flights.isEmpty { schedulerLease = nil }
            return
        }
        do {
            if schedulerLease == nil {
                guard
                    let lease = try PersistentFileLease.acquire(
                        at: file.appendingPathExtension("scheduler.lock"))
                else { return }
                schedulerLease = lease
                logs.removeAll()
                try update { records in
                    for index in records.indices {
                        switch records[index].status {
                        case .resolving, .downloading:
                            records[index].status = .interrupted("Downloads restarted.")
                        default: break
                        }
                    }
                }
            }
        } catch {
            schedulerLease = nil
            readError = "The download queue could not be read: \(error.localizedDescription)"
            return
        }
        while startOne() {}
    }

    private func startOne() -> Bool {
        guard started, !stopping, let lease = schedulerLease,
            flights.count < Self.maximumConcurrent, isEnabled(), let executable = executable()
        else { return false }
        var selected: DownloadRecord?
        do {
            try update { records in
                let queued = records.indices.filter {
                    records[$0].status == .queued && flights[records[$0].id] == nil
                }
                guard let index = queued.min(by: { records[$0].createdAt < records[$1].createdAt })
                else { return }
                selected = records[index]
                records[index].status = .resolving
            }
        } catch {
            notify()
            return false
        }
        guard let record = selected else { return false }
        let buffer = DownloadWorkerOutput()
        let request = Self.request(record, executable: executable)
        let gallery = galleryExecutable()
        let runCommand = runCommand
        let file = file
        let task = Task.detached(priority: .utility) { [weak self] in
            defer { withExtendedLifetime(lease) {} }
            do {
                try Task.checkCancellation()
                guard
                    try DownloadQueue.read(from: file).contains(where: {
                        $0.id == record.id && Self.isRunning($0)
                    })
                else { throw CancellationError() }
                let result: CLICommandResult
                if record.kind == .images || record.kind == .post {
                    guard let gallery else {
                        throw DownloadsError(
                            "Install gallery-dl in Downloads extension settings to save posts and images."
                        )
                    }
                    let extracted = try await runCommand(
                        MediaDownloadRequest.gallery(record, executable: gallery)
                    ) { buffer.append($0) }
                    try Task.checkCancellation()
                    if record.kind == .post, Self.resultPaths(extracted, record: record).isEmpty {
                        buffer.append("Trying yt-dlp for video media...")
                        result = try await runCommand(request) { buffer.append($0) }
                    } else {
                        result = extracted
                    }
                } else {
                    result = try await runCommand(request) { buffer.append($0) }
                }
                await self?.finish(record.id, result: .success(result))
            } catch {
                await self?.finish(record.id, result: .failure(error))
            }
        }
        let progress = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                await tick()
            }
        }
        flights[record.id] = Flight(
            token: UUID(), task: task, progress: progress, output: buffer, publishedRevision: 0)
        notify()
        return true
    }

    private func tick() {
        if !isEnabled() {
            for id in Array(flights.keys) { interrupt(id, reason: "Downloads are disabled.") }
        }
        var progress: [UUID: DownloadStatus] = [:]
        var changed = false
        for id in Array(flights.keys) {
            guard var flight = flights[id] else { continue }
            let output = flight.output.snapshot
            let revision = output.2
            guard revision != flight.publishedRevision else { continue }
            flight.publishedRevision = revision
            flights[id] = flight
            if let status = output.1 { progress[id] = status }
            changed = true
        }
        if !progress.isEmpty {
            try? update { records in
                for index in records.indices where Self.isRunning(records[index]) {
                    if let status = progress[records[index].id] { records[index].status = status }
                }
            }
        }
        if changed { notify() }
    }

    private func interrupt(_ id: UUID, reason: String) {
        guard flights[id] != nil else { return }
        try? update { records in
            guard let index = records.firstIndex(where: { $0.id == id }),
                Self.isRunning(records[index])
            else { return }
            records[index].status = .interrupted(reason)
        }
        flights[id]?.task.cancel()
        notify()
    }

    private func finish(_ id: UUID, result: Result<CLICommandResult, Error>) async {
        guard let flight = flights.removeValue(forKey: id) else { return }
        flight.progress?.cancel()
        retiredFlights[flight.token] = Task { [self, flight] in
            await flight.task.value
            await flight.progress?.value
            retiredFlights[flight.token] = nil
        }
        logs[id.uuidString] = flight.output.snapshot.0
        var succeeded = false
        try? update { records in
            if let index = records.firstIndex(where: { $0.id == id }),
                Self.isRunning(records[index])
            {
                switch result {
                case .success(let result):
                    let paths = Self.resultPaths(result, record: records[index])
                    records[index].resultPaths = paths.isEmpty ? nil : paths
                    if result.terminationStatus == 0, !paths.isEmpty {
                        records[index].status = .done(
                            paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                        )
                        records[index].resultPaths = paths
                        succeeded = true
                    } else {
                        let message = String(result.standardError.suffix(2_000)).trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        records[index].status = .error(
                            message.isEmpty
                                ? "No completed media found. Check the post URL, update the download tools, or select a signed-in browser for login-required posts."
                                : message)
                    }
                case .failure(let error):
                    records[index].status =
                        error is CancellationError
                        ? .interrupted("Cancelled") : .error(error.localizedDescription)
                }
            }
            let retained = Set(records.filter(\.isFinished).prefix(256).map(\.id))
            records.removeAll { $0.isFinished && !retained.contains($0.id) }
        }
        let keepLogs = Set(records.prefix(32).map { $0.id.uuidString })
        logs = logs.filter { keepLogs.contains($0.key) }
        notify()
        startNext()
        if succeeded { await completed() }
    }

    private static func isRunning(_ record: DownloadRecord) -> Bool {
        switch record.status {
        case .resolving, .downloading: true
        default: false
        }
    }

    private func reload() {
        do {
            records = try DownloadQueue.read(from: file)
            readError = nil
        } catch {
            readError = "The download queue could not be read: \(error.localizedDescription)"
        }
    }

    private func update(_ mutation: (inout [DownloadRecord]) throws -> Void) throws {
        do {
            records = try DownloadQueue.update(file: file, mutation).0
            persistenceError = nil
        } catch {
            persistenceError =
                "The download queue could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    private func sharedActivity() -> DownloadSchedulerActivity {
        do {
            let probe =
                schedulerLease == nil
                ? try PersistentFileLease.acquire(at: file.appendingPathExtension("scheduler.lock"))
                : nil
            return try withExtendedLifetime(probe) {
                var activity = try DownloadSchedulerActivity.read(queue: file)
                if schedulerLease == nil, probe != nil { activity.active = [] }
                let retained = Set(records.map { $0.id.uuidString })
                activity.logs = activity.logs.filter { retained.contains($0.key) }
                activityReadError = nil
                return activity
            }
        } catch {
            activityReadError = "Download activity could not be read: \(error.localizedDescription)"
            return DownloadSchedulerActivity()
        }
    }

    private func persistActivity() {
        guard schedulerLease != nil else { return }
        var current = logs
        for (id, flight) in flights { current[id.uuidString] = flight.output.snapshot.0 }
        let active = flights.keys.sorted { $0.uuidString < $1.uuidString }
        let retained = active + records.map(\.id).filter { !flights.keys.contains($0) }
        do {
            try DownloadSchedulerActivity.write(
                queue: file, generation: generation, active: active, logs: current,
                retained: retained)
            activityPersistenceError = nil
        } catch {
            activityPersistenceError =
                "Download activity could not be saved: \(error.localizedDescription)"
        }
    }

    private func notify() {
        persistActivity()
        snapshotDirty = true
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in await self?.publishPending() }
    }

    private func publishPending() async {
        while snapshotDirty {
            snapshotDirty = false
            let current = snapshot()
            for continuation in subscribers.values { continuation.yield(current) }
            await publish(current)
        }
        publicationTask = nil
        if snapshotDirty {
            publicationTask = Task { [weak self] in await self?.publishPending() }
        }
    }

    public static func request(_ record: DownloadRecord, executable: URL) -> CLICommandRequest {
        let format =
            record.kind != .audio && record.kind != nil
            ? ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
            : ["-f", "ba/b", "-x", "--audio-format", "m4a", "--keep-video"]
        return CLICommandRequest(
            executableURL: executable,
            arguments: [
                "--ignore-config", "--no-update", "--no-playlist", "--no-quiet", "--no-overwrites",
                "--windows-filenames", "--playlist-end", "100",
            ] + format
                + (record.browser.map { ["--cookies-from-browser", $0.rawValue] } ?? []) + [
                    "--embed-thumbnail", "--convert-thumbnails", "jpg", "--progress", "--newline",
                    "-o", record.outputFilename ?? DownloadQueue.outputTemplate(prefix: ""),
                    "--print", "after_move:filepath", "--", record.url.absoluteString,
                ], environment: CLIToolEnvironment.sanitized(), timeout: 7_200,
            maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
    }

    public static func resultPaths(_ result: CLICommandResult, record: DownloadRecord) -> [String] {
        var seen = Set<String>()
        let directory =
            URL(fileURLWithPath: record.outputFilename ?? DownloadQueue.outputTemplate(prefix: ""))
            .deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return result.standardOutput.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(directory),
                (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                seen.insert(url.path).inserted
            else { return nil }
            return url.path
        }
    }
}
