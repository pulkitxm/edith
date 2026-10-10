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
    private struct Flight {
        var task: Task<Void, Never>
        var progress: Task<Void, Never>?
        var output: DownloadWorkerOutput
        var publishedRevision: Int
    }

    static let maximumConcurrent = 3
    private var logs: [String: String] = [:]
    private var flights: [UUID: Flight] = [:]
    private var started = false
    private var stopping = false
    private let generation = UUID()
    private var revision = 0
    private var snapshotDirty = false
    private var publicationTask: Task<Void, Never>?
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
            records = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: file))
                .sorted {
                    if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                    return $0.id.uuidString < $1.id.uuidString
                }
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
        for task in estimates.values { task.cancel() }
    }

    public func start() throws {
        if let loadError { throw DownloadsError(loadError) }
        guard !started, !stopping else { return }
        started = true
        var changed = false
        for index in records.indices {
            switch records[index].status {
            case .resolving, .downloading:
                records[index].status = .interrupted("Downloads restarted.")
                changed = true
            default: break
            }
        }
        if changed { try save() }
        startNext()
        notify()
    }

    public func stop() async {
        stopping = true
        started = false
        let running = Array(flights.keys)
        for id in running { interrupt(id, reason: "Downloads stopped.") }
        let tasks = flights.values.map(\.task)
        let progressTasks = flights.values.compactMap(\.progress)
        let estimates = Array(self.estimates.values)
        for task in estimates { task.cancel() }
        for flight in flights.values {
            flight.task.cancel()
            flight.progress?.cancel()
        }
        for task in tasks { await task.value }
        for task in progressTasks { await task.value }
        for task in estimates { _ = await task.result }
        self.estimates.removeAll()
        notify()
        await publicationTask?.value
        for continuation in subscribers.values { continuation.finish() }
        subscribers.removeAll()
    }

    public func snapshot() -> DownloadWorkerSnapshot {
        revision += 1
        var snapshotRecords = records
        var snapshotLogs = logs
        for (id, flight) in flights {
            let buffer = flight.output.snapshot
            snapshotLogs[id.uuidString] = buffer.0
            if let index = snapshotRecords.firstIndex(where: { $0.id == id }),
                !snapshotRecords[index].isFinished, let status = buffer.1
            {
                snapshotRecords[index].status = status
            }
        }
        return DownloadWorkerSnapshot(
            records: snapshotRecords, logs: snapshotLogs, enabled: isEnabled(),
            running: !flights.isEmpty, generation: generation, revision: revision,
            problem: loadError ?? persistenceError, executable: executable()
        )
    }

    public func refresh() {
        guard !stopping else { return }
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
        let previousRecords = records
        let previousLogs = logs
        var cancelIDs = Set<UUID>()
        var changed = 0
        var added: [DownloadRecord] = []
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
            let template = DownloadQueue.outputTemplate(prefix: prefix, directory: outputDirectory)
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
                guard !records[index].isFinished, includeQueued || records[index].status != .queued
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
        do {
            if changed > 0 { try save() }
        } catch {
            records = previousRecords
            logs = previousLogs
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
        while startOne() {}
    }

    private func startOne() -> Bool {
        guard started, !stopping, flights.count < Self.maximumConcurrent, isEnabled(),
            let executable = executable()
        else { return false }
        let queued = records.indices.filter { records[$0].status == .queued }
        guard let index = queued.min(by: { records[$0].createdAt < records[$1].createdAt }) else {
            return false
        }
        let record = records[index]
        records[index].status = .resolving
        do { try save() } catch {
            records[index].status = .error(error.localizedDescription)
            notify()
            return false
        }
        let buffer = DownloadWorkerOutput()
        let request = Self.request(record, executable: executable)
        let gallery = galleryExecutable()
        let runCommand = runCommand
        let task = Task.detached(priority: .utility) { [weak self] in
            do {
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
            task: task, progress: progress, output: buffer, publishedRevision: 0)
        notify()
        return true
    }

    private func tick() {
        if !isEnabled() {
            for id in Array(flights.keys) { interrupt(id, reason: "Downloads are disabled.") }
        }
        var changed = false
        for id in Array(flights.keys) {
            guard var flight = flights[id] else { continue }
            let revision = flight.output.snapshot.2
            guard revision != flight.publishedRevision else { continue }
            flight.publishedRevision = revision
            flights[id] = flight
            changed = true
        }
        if changed { notify() }
    }

    private func interrupt(_ id: UUID, reason: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isFinished
        else { return }
        records[index].status = .interrupted(reason)
        try? save()
        flights[id]?.task.cancel()
        notify()
    }

    private func finish(_ id: UUID, result: Result<CLICommandResult, Error>) async {
        guard let flight = flights.removeValue(forKey: id) else { return }
        flight.progress?.cancel()
        logs[id.uuidString] = flight.output.snapshot.0
        var succeeded = false
        if let index = records.firstIndex(where: { $0.id == id }), !records[index].isFinished {
            switch result {
            case .success(let result):
                let paths = Self.resultPaths(result, record: records[index])
                records[index].resultPaths = paths.isEmpty ? nil : paths
                if result.terminationStatus == 0, !paths.isEmpty {
                    records[index].status = .done(
                        paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
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
        let keepLogs = Set(records.prefix(32).map { $0.id.uuidString })
        logs = logs.filter { keepLogs.contains($0.key) }
        try? save()
        notify()
        startNext()
        if succeeded { await completed() }
    }

    private func save() throws {
        do {
            try DownloadQueue.save(records, to: file)
            persistenceError = nil
        } catch {
            persistenceError =
                "The download queue could not be saved: \(error.localizedDescription)"
            throw error
        }
    }

    private func notify() {
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
