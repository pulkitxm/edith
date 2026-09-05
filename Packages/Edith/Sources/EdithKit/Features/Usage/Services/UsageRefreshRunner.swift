import Darwin
import Foundation

public enum UsageRefreshFailure: Error, CustomStringConvertible, Equatable {
    case scriptMissing
    case busy
    case launchFailed(String)
    case timedOut
    case outputLimitExceeded
    case reported(String)
    case exited(Int32, String)

    public var description: String {
        switch self {
        case .scriptMissing:
            return "the usage refresh pipeline is missing from this build"
        case .busy:
            return "a usage refresh is already running"
        case let .launchFailed(reason):
            return "could not start the usage refresh: \(reason)"
        case .timedOut:
            return "usage refresh timed out"
        case .outputLimitExceeded:
            return "usage refresh produced too much output"
        case let .reported(message):
            return message
        case let .exited(status, output):
            let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return tail.isEmpty
                ? "usage refresh exited with status \(status)"
                : "usage refresh exited with status \(status): \(tail)"
        }
    }

    public var hint: String? {
        switch self {
        case .scriptMissing:
            return "reinstall Edith, then retry"
        case .busy:
            return "wait for it to finish, or run `ed usage refresh --follow`"
        case .launchFailed:
            return "check that /bin/bash is available"
        case .timedOut, .outputLimitExceeded:
            return "the pipeline output is in data/refresh.log"
        case .reported(let message)
        where message.contains("bun is required for durable billing history"):
            return "install bun (`brew install oven-sh/bun/bun`) and retry"
        case .reported, .exited:
            return "the pipeline output is in data/refresh.log"
        }
    }
}

public struct UsageRefreshResult: Sendable {
    public let events: [UsageRefreshEvent]
    public let seconds: Double
    public let startedAt: Date

    public init(events: [UsageRefreshEvent], seconds: Double, startedAt: Date) {
        self.events = events
        self.seconds = seconds
        self.startedAt = startedAt
    }

    public var summaries: [(label: String, value: String)] {
        events.compactMap {
            if case let .summary(label, value) = $0 { return (label, value) }
            return nil
        }
    }
}

struct UsageRefreshBaseline: Equatable, Sendable {
    let usage: Data?
    let machines: Data?
}

public final class UsageRefreshLock {
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL) -> UsageRefreshLock? {
        let fd = open(
            url.path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR))
        guard fd >= 0 else { return nil }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            return nil
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            return nil
        }
        return UsageRefreshLock(descriptor: fd)
    }

    public static func isHeld(at url: URL) -> Bool {
        guard let probe = acquire(at: url) else { return true }
        probe.release()
        return false
    }

    public func release() {
        let released = stateLock.withLock { () -> Int32 in
            guard descriptor >= 0 else { return -1 }
            let value = descriptor
            descriptor = -1
            return value
        }
        guard released >= 0 else { return }
        flock(released, LOCK_UN)
        close(released)
    }

    deinit { release() }
}

public enum UsageRefreshRunner {
    public static func scriptURL() -> URL? { UsageCollector.scriptURL() }

    public static func lockURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("refresh.lock")
    }

    public static func transactionURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("usage-transaction.lock")
    }

    public static func eventsURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("refresh.events")
    }

    public static func logURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("refresh.log")
    }

    public static var isRunning: Bool { UsageRefreshLock.isHeld(at: lockURL()) }

    public static func run(
        dataDir: URL = Repo.dataDir,
        workingDirectory: URL = AppData.supportDir,
        onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void = { _ in }
    ) async throws -> UsageRefreshResult {
        let refreshTrace = PerformanceTrace.begin(.git, "usage.refresh")
        defer { PerformanceTrace.end(refreshTrace) }
        guard let script = scriptURL() else { throw UsageRefreshFailure.scriptMissing }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let lock = UsageRefreshLock.acquire(at: lockURL(dataDir: dataDir)) else {
            throw UsageRefreshFailure.busy
        }
        defer { lock.release() }
        guard let transaction = UsageRefreshLock.acquire(at: transactionURL(dataDir: dataDir))
        else {
            throw UsageRefreshFailure.busy
        }
        defer { transaction.release() }

        let stagingDirectory = dataDir.appendingPathComponent(".refresh-staging")
        try? FileManager.default.createDirectory(
            at: stagingDirectory, withIntermediateDirectories: true)
        cleanupStaleStages(in: stagingDirectory)
        let stagedUsage = stagingDirectory.appendingPathComponent("\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: stagedUsage) }
        let baseline: UsageRefreshBaseline
        do {
            baseline = try stageCurrentUsage(at: stagedUsage, dataDir: dataDir)
        } catch {
            throw UsageRefreshFailure.reported(
                "usage refresh staging failed; previous data preserved")
        }

        let startedAt = Date()
        let sink = UsageRefreshSink(dataDir: dataDir, startedAt: startedAt)
        sink.begin()
        IPC.post(IPC.Name.usageRefreshStarted)
        defer { IPC.post(IPC.Name.usageRefreshFinished) }

        var environment = ProcessInfo.processInfo.environment
        environment["EDITH_USAGE_OUTPUT"] = stagedUsage.path
        environment["EDITH_USAGE_MACHINES_DIR"] = dataDir.appendingPathComponent("machines").path

        let collector = UsageRefreshCollector(sink: sink, onEvent: onEvent)
        defer {
            collector.flush()
            sink.finish()
        }

        let result: CLICommandResult
        do {
            result = try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/bash"),
                    arguments: [script.path, dataDir.path], environment: environment,
                    currentDirectoryURL: workingDirectory, timeout: 900,
                    maximumOutputBytes: 2 * 1_024 * 1_024,
                    terminatesProcessGroup: true),
                onStandardOutputLine: {
                    collector.ingestStandardOutput(Data(($0 + "\n").utf8))
                },
                onStandardErrorLine: {
                    collector.ingestStandardError(Data(($0 + "\n").utf8))
                })
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as CLICommandRunnerError {
            switch error {
            case .timedOut:
                throw UsageRefreshFailure.timedOut
            case .outputLimitExceeded:
                throw UsageRefreshFailure.outputLimitExceeded
            case .launchFailed:
                throw UsageRefreshFailure.launchFailed("process launch failed")
            case .streamFailed:
                throw UsageRefreshFailure.launchFailed("process output stream failed")
            }
        } catch {
            throw UsageRefreshFailure.launchFailed(error.localizedDescription)
        }

        if let message = collector.reportedFailure {
            throw UsageRefreshFailure.reported(message)
        }
        let status = result.terminationStatus
        guard status == 0 else {
            throw UsageRefreshFailure.exited(status, collector.diagnosticTail)
        }
        do {
            let retained = try publish(
                stagedUsage: stagedUsage, baseline: baseline, dataDir: dataDir)
            if retained > 0 {
                let message =
                    "\(retained) day/source blocks retain prior usage; "
                    + "overlapping changes remain unresolved, newer days continue"
                if !collector.events.contains(.note(message)) {
                    collector.ingestStandardOutput(Data("note\t\(message)\n".utf8))
                }
            }
        } catch {
            throw UsageRefreshFailure.reported(
                "usage refresh publication failed; previous data preserved")
        }
        let elapsed = collector.totalSeconds ?? Date().timeIntervalSince(startedAt)
        return UsageRefreshResult(
            events: collector.events, seconds: elapsed, startedAt: startedAt)
    }

    @discardableResult
    static func publish(
        stagedUsage: URL, baseline: UsageRefreshBaseline, dataDir: URL
    ) throws -> Int {
        guard
            let fresh = try UsageDataFiles.readRegularFile(
                at: stagedUsage, maximumBytes: UsageDataFiles.maximumUsageDocumentBytes),
            UsageHistory.isValidDocument(fresh)
        else { throw UsageDataFileError.unsafe(stagedUsage.path) }
        guard let merged = UsageHistory.mergeRefresh(fresh: fresh, previous: baseline.usage),
            merged.count <= UsageDataFiles.maximumUsageDocumentBytes,
            UsageHistory.isValidDocument(merged)
        else { throw UsageDataFileError.unsafe(stagedUsage.path) }
        try UsageDataLock.withLock(dataDirectory: dataDir) {
            let current = try UsageDataFiles.readRegularFile(
                at: dataDir.appendingPathComponent("usage.json"),
                maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
            let machines = try MachineUsageStore.generation(
                in: dataDir.appendingPathComponent("machines"))
            guard current == baseline.usage, machines == baseline.machines else {
                throw UsageDataFileError.unsafe(stagedUsage.path)
            }
            try UsageDataFiles.write(merged, to: dataDir.appendingPathComponent("usage.json"))
        }
        return UsageHistory.retainedHistoryBlockCount(in: merged)
    }

    static func stageCurrentUsage(
        at stagedUsage: URL, dataDir: URL
    ) throws -> UsageRefreshBaseline {
        let baseline = try UsageDataLock.withLock(dataDirectory: dataDir) {
            let usage = try UsageDataFiles.readRegularFile(
                at: dataDir.appendingPathComponent("usage.json"),
                maximumBytes: UsageDataFiles.maximumUsageDocumentBytes)
            if let usage, !UsageHistory.isValidDocument(usage) {
                throw UsageDataFileError.unsafe(dataDir.appendingPathComponent("usage.json").path)
            }
            let machines = try MachineUsageStore.generation(
                in: dataDir.appendingPathComponent("machines"))
            return UsageRefreshBaseline(usage: usage, machines: machines)
        }
        if let usage = baseline.usage { try UsageDataFiles.write(usage, to: stagedUsage) }
        return baseline
    }

    static func cleanupStaleStages(
        in directory: URL, now: Date = Date(), maximumAge: TimeInterval = 86_400
    ) {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ], options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
        else { return }
        var inspected = 0
        var removed = 0
        while inspected < 4_000, removed < 1_000,
            let url = enumerator.nextObject() as? URL
        {
            inspected += 1
            guard url.pathExtension == "json" else { continue }
            guard
                let values = try? url.resourceValues(forKeys: [
                    .contentModificationDateKey, .isRegularFileKey, .isSymbolicLinkKey,
                ]),
                values.isRegularFile == true, values.isSymbolicLink != true,
                now.timeIntervalSince(values.contentModificationDate ?? now) >= maximumAge
            else { continue }
            try? FileManager.default.removeItem(at: url)
            removed += 1
        }
    }
}

final class UsageRefreshCollector: @unchecked Sendable {
    private let lock = NSLock()
    private let sink: UsageRefreshSink
    private let onEvent: @Sendable (UsageRefreshEvent) -> Void
    private var outBuffer = ""
    private var errBuffer = ""
    private var stray: [String] = []
    private var collected: [UsageRefreshEvent] = []
    private var failure: String?
    private var seconds: Double?

    init(sink: UsageRefreshSink, onEvent: @escaping @Sendable (UsageRefreshEvent) -> Void) {
        self.sink = sink
        self.onEvent = onEvent
    }

    var events: [UsageRefreshEvent] {
        lock.lock()
        defer { lock.unlock() }
        return collected
    }

    var reportedFailure: String? {
        lock.lock()
        defer { lock.unlock() }
        return failure
    }

    var totalSeconds: Double? {
        lock.lock()
        defer { lock.unlock() }
        return seconds
    }

    var diagnosticTail: String {
        lock.lock()
        defer { lock.unlock() }
        return stray.suffix(6).joined(separator: "; ")
    }

    func ingestStandardOutput(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = takeLines(String(decoding: data, as: UTF8.self), buffer: &outBuffer)
        for line in lines { handle(line) }
    }

    func ingestStandardError(_ data: Data) {
        guard !data.isEmpty else { return }
        let lines = takeLines(String(decoding: data, as: UTF8.self), buffer: &errBuffer)
        lock.lock()
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            stray.append(line)
        }
        lock.unlock()
    }

    func flush() {
        let pending = outBuffer
        outBuffer = ""
        if !pending.isEmpty { handle(pending) }
        sink.flush()
    }

    private func takeLines(_ text: String, buffer: inout String) -> [String] {
        buffer += text
        var lines = buffer.components(separatedBy: "\n")
        buffer = lines.removeLast()
        return lines
    }

    private func handle(_ line: String) {
        guard let event = UsageRefreshEvent.parse(line) else {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return }
            lock.lock()
            stray.append(line)
            lock.unlock()
            return
        }
        lock.lock()
        collected.append(event)
        if case let .failure(message) = event { failure = message }
        if case let .finished(total) = event { seconds = total }
        lock.unlock()
        sink.write(event)
        onEvent(event)
    }
}

final class UsageRefreshSink: @unchecked Sendable {
    private let lock = NSLock()
    private let eventsURL: URL
    private let logURL: URL
    private let startedAt: Date
    private var transcript: [String] = []
    private var wire: [String] = []
    private var sawSummary = false
    private var lastFlush: Date?

    init(dataDir: URL, startedAt: Date) {
        self.eventsURL = UsageRefreshRunner.eventsURL(dataDir: dataDir)
        self.logURL = UsageRefreshRunner.logURL(dataDir: dataDir)
        self.startedAt = startedAt
    }

    func begin() {
        lock.lock()
        transcript = UsageRefreshTranscript.header(at: startedAt)
        wire = []
        sawSummary = false
        lock.unlock()
        persist()
    }

    func write(_ event: UsageRefreshEvent) {
        lock.lock()
        if case .summary = event, !sawSummary {
            sawSummary = true
            transcript.append("  " + UsageRefreshTranscript.rule)
        }
        transcript.append(contentsOf: UsageRefreshTranscript.lines(for: event))
        wire.append(event.wireLine)
        let due = lastFlush.map { Date().timeIntervalSince($0) >= 0.25 } ?? true
        lock.unlock()
        if due { persist() }
    }

    func flush() { persist() }

    func finish() { persist() }

    private func persist() {
        lock.lock()
        lastFlush = Date()
        let text = transcript.joined(separator: "\n") + "\n"
        let lines = wire.joined(separator: "\n") + "\n"
        lock.unlock()
        try? text.write(to: logURL, atomically: true, encoding: .utf8)
        try? lines.write(to: eventsURL, atomically: true, encoding: .utf8)
    }
}
