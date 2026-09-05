import EdithCore
import EdithKit
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
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult
    public typealias Publish = @Sendable (DownloadWorkerSnapshot) async -> Void

    private let file: URL
    private let executable: @Sendable () -> URL?
    private let isEnabled: @Sendable () -> Bool
    private let runCommand: RunCommand
    private let publish: Publish
    private let completed: @Sendable () async -> Void
    private var records: [DownloadRecord]
    private let loadError: String?
    private var persistenceError: String?
    private var logs: [String: String] = [:]
    private var currentID: UUID?
    private var task: Task<Void, Never>?
    private var progressTask: Task<Void, Never>?
    private var output: DownloadWorkerOutput?
    private var publishedRevision = 0
    private var started = false
    private var stopping = false
    private let generation = UUID()
    private var revision = 0
    private var pendingSnapshot: DownloadWorkerSnapshot?
    private var publicationTask: Task<Void, Never>?

    public init(
        file: URL = DownloadQueue.file,
        executable: @escaping @Sendable () -> URL? = {
            CLIToolEnvironment.executable(named: "yt-dlp")
        },
        isEnabled: @escaping @Sendable () -> Bool = {
            ExtensionRegistry.entry("downloads")?.isEnabled(in: SharedDefaults.store) ?? false
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
        task?.cancel()
        progressTask?.cancel()
        publicationTask?.cancel()
    }

    public func start() throws {
        if let loadError { throw AgentError(.failed, loadError) }
        guard !started, !stopping else { return }
        started = true
        var changed = false
        for index in records.indices {
            switch records[index].status {
            case .resolving, .downloading:
                records[index].status = .interrupted("The background agent restarted.")
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
        let active = task
        if let currentID { interrupt(currentID, reason: "The background agent stopped.") }
        active?.cancel()
        progressTask?.cancel()
        progressTask = nil
        await active?.value
        notify()
        await publicationTask?.value
    }

    public func snapshot() -> DownloadWorkerSnapshot {
        revision += 1
        var snapshotRecords = records
        var snapshotLogs = logs
        if let currentID, let buffer = output?.snapshot {
            snapshotLogs[currentID.uuidString] = buffer.0
            if let index = snapshotRecords.firstIndex(where: { $0.id == currentID }),
                !snapshotRecords[index].isFinished, let status = buffer.1
            {
                snapshotRecords[index].status = status
            }
        }
        return DownloadWorkerSnapshot(
            records: snapshotRecords, logs: snapshotLogs, enabled: isEnabled(),
            running: task != nil, generation: generation, revision: revision,
            problem: loadError ?? persistenceError, executable: executable()
        )
    }

    public func refresh() {
        guard !stopping else { return }
        if !isEnabled(), let currentID { interrupt(currentID, reason: "Downloads are disabled.") }
        startNext()
        notify()
    }

    public func mutate(_ request: AgentDownloadMutation) throws -> AgentDownloadMutationResult {
        guard !stopping else { throw AgentError(.unavailable, "The agent is shutting down.") }
        if let loadError { throw AgentError(.failed, loadError) }
        let previousRecords = records
        let previousLogs = logs
        var shouldCancel = false
        var changed = 0
        var added: [DownloadRecord] = []
        switch request {
        case let .enqueue(urls, prefix, kind, outputDirectory):
            guard urls.count <= 100, !urls.isEmpty,
                records.count(where: { !$0.isFinished }) + urls.count <= 128,
                urls.allSatisfy({
                    ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil
                }),
                prefix.utf8.count <= 200, !prefix.contains("/"), !prefix.contains("\\"),
                outputDirectory.isFileURL
            else { throw AgentError(.refused, "The download request is invalid.") }
            try FileManager.default.createDirectory(
                at: outputDirectory, withIntermediateDirectories: true)
            let template = DownloadQueue.outputTemplate(prefix: prefix, directory: outputDirectory)
            added = urls.map {
                DownloadRecord(
                    url: $0, status: .queued, outputFilename: template, createdAt: Date(),
                    kind: kind)
            }
            records.insert(contentsOf: added, at: 0)
            changed = added.count
        case let .retry(id, all):
            for index in records.indices
            where (all || records[index].id == id) && records[index].canRetry {
                guard records[index].id != currentID else { continue }
                records[index].status = .queued
                changed += 1
            }
        case let .cancel(id, includeQueued, reason):
            for index in records.indices where id == nil || records[index].id == id {
                guard !records[index].isFinished, includeQueued || records[index].status != .queued
                else { continue }
                records[index].status = .interrupted(String(reason.prefix(200)))
                changed += 1
                if records[index].id == currentID { shouldCancel = true }
            }
        case let .remove(id):
            changed = records.count { $0.id == id }
            records.removeAll { $0.id == id }
            logs[id.uuidString] = nil
            if currentID == id { shouldCancel = true }
        case let .clear(includeActive):
            let removed = records.filter { includeActive || $0.isFinished }
            let ids = Set(removed.map(\.id))
            records.removeAll { ids.contains($0.id) }
            for id in ids { logs[id.uuidString] = nil }
            if let currentID, ids.contains(currentID) { shouldCancel = true }
            changed = removed.count
        }
        do {
            if changed > 0 { try save() }
        } catch {
            records = previousRecords
            logs = previousLogs
            throw error
        }
        if shouldCancel { task?.cancel() }
        let result = AgentDownloadMutationResult(changed: changed, records: records, added: added)
        startNext()
        notify()
        return result
    }

    public func registerEstimate(on tasks: AgentTaskService) async {
        let executable = executable
        let runCommand = runCommand
        await tasks.register(operation: AgentDownloadOperation.estimate) { payload, _ in
            let url = try AgentPayload.decode(URL.self, from: payload)
            guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                throw AgentError(.refused, "Enter a valid download URL.")
            }
            guard let executable = executable() else { throw DownloadToolOperationError.missing }
            let result = try await runCommand(
                CLICommandRequest(
                    executableURL: executable,
                    arguments: [
                        "--no-update", "--no-playlist", "--skip-download", "-J", url.absoluteString,
                    ],
                    environment: CLIToolEnvironment.sanitized(), timeout: 30,
                    maximumOutputBytes: 2 << 20, discardsStandardError: true,
                    terminatesProcessGroup: true), { _ in })
            let estimate =
                result.terminationStatus == 0
                ? DownloadSizeParser.estimate(fromJSON: result.standardOutputData) : nil
            return try AgentPayload.encode(estimate)
        }
    }

    private func startNext() {
        guard started, !stopping, task == nil, isEnabled(), let executable = executable() else {
            return
        }
        let queued = records.indices.filter { records[$0].status == .queued }
        guard let index = queued.min(by: { records[$0].createdAt < records[$1].createdAt }) else {
            return
        }
        let record = records[index]
        records[index].status = .resolving
        do { try save() } catch {
            records[index].status = .error(error.localizedDescription)
            notify()
            return
        }
        currentID = record.id
        let buffer = DownloadWorkerOutput()
        output = buffer
        publishedRevision = 0
        let request = Self.request(record, executable: executable)
        let runCommand = runCommand
        task = Task.detached(priority: .utility) { [weak self] in
            do {
                let result = try await runCommand(request) { buffer.append($0) }
                await self?.finish(record.id, result: .success(result))
            } catch {
                await self?.finish(record.id, result: .failure(error))
            }
        }
        progressTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                guard let self else { return }
                await tick()
            }
        }
        notify()
    }

    private func tick() {
        if !isEnabled(), let currentID { interrupt(currentID, reason: "Downloads are disabled.") }
        guard let revision = output?.snapshot.2, revision != publishedRevision else { return }
        publishedRevision = revision
        notify()
    }

    private func interrupt(_ id: UUID, reason: String) {
        guard let index = records.firstIndex(where: { $0.id == id }), !records[index].isFinished
        else { return }
        records[index].status = .interrupted(reason)
        try? save()
        task?.cancel()
        notify()
    }

    private func finish(_ id: UUID, result: Result<CLICommandResult, Error>) async {
        guard currentID == id else { return }
        progressTask?.cancel()
        progressTask = nil
        if let text = output?.snapshot.0 { logs[id.uuidString] = text }
        output = nil
        task = nil
        currentID = nil
        var succeeded = false
        if let index = records.firstIndex(where: { $0.id == id }), !records[index].isFinished {
            switch result {
            case .success(let result):
                let paths = Self.resultPaths(result, record: records[index])
                if result.terminationStatus == 0, !paths.isEmpty {
                    YoutubeDownloader.cleanupIntermediates(for: paths)
                    records[index].status = .done(
                        paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))
                    records[index].resultPaths = paths
                    succeeded = true
                } else {
                    let message = String(result.standardError.suffix(2_000)).trimmingCharacters(
                        in: .whitespacesAndNewlines)
                    records[index].status = .error(
                        message.isEmpty ? "The downloader produced no completed file." : message)
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
        pendingSnapshot = snapshot()
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in await self?.publishPending() }
    }

    private func publishPending() async {
        while let snapshot = pendingSnapshot {
            pendingSnapshot = nil
            await publish(snapshot)
        }
        publicationTask = nil
    }

    public static func request(_ record: DownloadRecord, executable: URL) -> CLICommandRequest {
        let format =
            record.kind == .video
            ? ["-f", "bv*+ba/b", "--merge-output-format", "mp4"] : ["-x", "--audio-format", "m4a"]
        return CLICommandRequest(
            executableURL: executable,
            arguments: ["--no-update", "--no-playlist", "--no-quiet"] + format + [
                "--embed-thumbnail", "--convert-thumbnails", "jpg", "--progress", "--newline",
                "-o", record.outputFilename ?? DownloadQueue.outputTemplate(prefix: ""),
                "--print", "after_move:filepath", record.url.absoluteString,
            ], environment: CLIToolEnvironment.sanitized(), timeout: 7_200,
            maximumOutputBytes: 2 << 20, terminatesProcessGroup: true)
    }

    public static func resultPaths(_ result: CLICommandResult, record: DownloadRecord) -> [String] {
        let directory =
            URL(fileURLWithPath: record.outputFilename ?? DownloadQueue.outputTemplate(prefix: ""))
            .deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path + "/"
        return result.standardOutput.components(separatedBy: .newlines).compactMap { line in
            let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.hasPrefix("/") else { return nil }
            let url = URL(fileURLWithPath: value).resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(directory), FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return url.path
        }
    }
}
