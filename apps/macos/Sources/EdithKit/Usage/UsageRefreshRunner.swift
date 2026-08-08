import Foundation

public enum UsageRefreshFailure: Error, CustomStringConvertible, Equatable {
    case scriptMissing
    case busy
    case launchFailed(String)
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
        case .reported(let message) where message.contains("bun or npx"):
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

public final class UsageRefreshLock {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    public static func acquire(at url: URL) -> UsageRefreshLock? {
        let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { return nil }
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
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

public enum UsageRefreshRunner {
    public static func scriptURL() -> URL? { UsageCollector.scriptURL() }

    public static func lockURL(dataDir: URL = Repo.dataDir) -> URL {
        dataDir.appendingPathComponent("refresh.lock")
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
        guard let script = scriptURL() else { throw UsageRefreshFailure.scriptMissing }
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let lock = UsageRefreshLock.acquire(at: lockURL(dataDir: dataDir)) else {
            throw UsageRefreshFailure.busy
        }
        defer { lock.release() }

        let startedAt = Date()
        let sink = UsageRefreshSink(dataDir: dataDir, startedAt: startedAt)
        sink.begin()
        IPC.post(IPC.Name.usageRefreshStarted)
        defer { IPC.post(IPC.Name.usageRefreshFinished) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, dataDir.path]
        process.currentDirectoryURL = workingDirectory
        process.qualityOfService = .utility

        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collector = UsageRefreshCollector(sink: sink, onEvent: onEvent)
        out.fileHandleForReading.readabilityHandler = { handle in
            collector.ingestStandardOutput(handle.availableData)
        }
        err.fileHandleForReading.readabilityHandler = { handle in
            collector.ingestStandardError(handle.availableData)
        }

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Void, Error>) in
                    process.terminationHandler = { _ in
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        collector.ingestStandardOutput(
                            out.fileHandleForReading.availableData)
                        collector.ingestStandardError(err.fileHandleForReading.availableData)
                        collector.flush()
                        continuation.resume()
                    }
                    do {
                        try process.run()
                    } catch {
                        out.fileHandleForReading.readabilityHandler = nil
                        err.fileHandleForReading.readabilityHandler = nil
                        continuation.resume(
                            throwing: UsageRefreshFailure.launchFailed(
                                error.localizedDescription))
                    }
                }
            } onCancel: {
                if process.isRunning { process.terminate() }
            }
        } catch {
            sink.finish()
            throw error
        }

        sink.finish()

        if let message = collector.reportedFailure {
            throw UsageRefreshFailure.reported(message)
        }
        let status = process.terminationStatus
        guard status == 0 else {
            throw UsageRefreshFailure.exited(status, collector.diagnosticTail)
        }
        let elapsed = collector.totalSeconds ?? Date().timeIntervalSince(startedAt)
        return UsageRefreshResult(
            events: collector.events, seconds: elapsed, startedAt: startedAt)
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
