import Darwin
import Foundation

public struct CLICommandRequest: Codable, Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let currentDirectoryURL: URL?
    public let timeout: TimeInterval?
    public let maximumOutputBytes: Int?
    public let standardInputData: Data?
    public let discardsStandardError: Bool
    public let terminatesProcessGroup: Bool

    public init(
        executableURL: URL, arguments: [String], environment: [String: String],
        currentDirectoryURL: URL? = nil, timeout: TimeInterval? = nil,
        maximumOutputBytes: Int? = nil,
        standardInputData: Data? = nil,
        discardsStandardError: Bool = false, terminatesProcessGroup: Bool = false
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.currentDirectoryURL = currentDirectoryURL
        self.timeout = timeout
        self.maximumOutputBytes = maximumOutputBytes
        self.standardInputData = standardInputData
        self.discardsStandardError = discardsStandardError
        self.terminatesProcessGroup = terminatesProcessGroup
    }
}

public enum ToolVersionProbe {
    public typealias RunCommand =
        @Sendable (CLICommandRequest, @escaping @Sendable (String) -> Void) async throws ->
        CLICommandResult

    public static func version(
        _ request: CLICommandRequest,
        runCommand: @escaping RunCommand = { try await CLICommandRunner.run($0, onLine: $1) }
    ) async -> String? {
        guard let result = try? await runCommand(request, { _ in }), result.terminationStatus == 0
        else { return nil }
        return result.output.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? request.executableURL.lastPathComponent
    }
}

public struct CLICommandResult: Codable, Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutputData: Data
    public let standardErrorData: Data
    public var outputData: Data { standardOutputData + standardErrorData }
    public var output: String { String(decoding: outputData, as: UTF8.self) }
    public var standardOutput: String { String(decoding: standardOutputData, as: UTF8.self) }
    public var standardError: String { String(decoding: standardErrorData, as: UTF8.self) }

    public init(terminationStatus: Int32, output: String) {
        self.terminationStatus = terminationStatus
        standardOutputData = Data(output.utf8)
        standardErrorData = Data()
    }

    public init(terminationStatus: Int32, outputData: Data) {
        self.terminationStatus = terminationStatus
        standardOutputData = outputData
        standardErrorData = Data()
    }

    public init(terminationStatus: Int32, standardOutputData: Data, standardErrorData: Data) {
        self.terminationStatus = terminationStatus
        self.standardOutputData = standardOutputData
        self.standardErrorData = standardErrorData
    }
}

public enum CLICommandRunnerError: Error, Equatable, Sendable {
    case launchFailed
    case timedOut
    case outputLimitExceeded
    case streamFailed
}

private final class CLIStreamingOutput: @unchecked Sendable {
    static let streamedLineLimit = 64 * 1_024

    private let lock = NSLock()
    private let maximumBytes: Int?
    let retainsOutput: Bool
    private let onLine: (@Sendable (String) -> Void)?
    private let onLimit: (@Sendable () -> Void)?
    private var pending = Data()
    private var complete = Data()
    private var exceededLimit = false
    private var readFailed = false

    init(
        maximumBytes: Int?, retainsOutput: Bool = true, onLine: (@Sendable (String) -> Void)?,
        onLimit: (@Sendable () -> Void)? = nil
    ) {
        self.maximumBytes = maximumBytes
        self.retainsOutput = retainsOutput
        self.onLine = onLine
        self.onLimit = onLimit
    }

    func receive(_ data: Data) {
        let limited = lock.withLock { () -> (Bool, [String]) in
            guard !exceededLimit else { return (false, []) }
            if retainsOutput {
                if let maximumBytes, complete.count + data.count > maximumBytes {
                    complete.removeAll(keepingCapacity: false)
                    pending.removeAll(keepingCapacity: false)
                    exceededLimit = true
                    return (true, [])
                }
                complete.append(data)
            }
            guard onLine != nil else { return (false, []) }
            var lines: [String] = []
            var start = data.startIndex
            for index in data.indices where endsLine(data[index]) {
                appendPending(data[start..<index])
                if let line = takePendingLine() { lines.append(line) }
                start = data.index(after: index)
            }
            appendPending(data[start..<data.endIndex])
            return (false, lines)
        }
        if limited.0 { onLimit?() }
        for line in limited.1 { onLine?(line) }
    }

    private func endsLine(_ byte: UInt8) -> Bool {
        byte == 10 || (retainsOutput && byte == 13)
    }

    private func appendPending(_ bytes: Data) {
        guard !retainsOutput else {
            pending.append(bytes)
            return
        }
        let room = Self.streamedLineLimit - pending.count
        if room > 0 { pending.append(bytes.prefix(room)) }
    }

    private func takePendingLine() -> String? {
        if !retainsOutput, pending.last == 13 { pending.removeLast() }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
    }

    func finish() -> (output: Data, exceededLimit: Bool) {
        let finished = lock.withLock { () -> (String?, Data, Bool) in
            let line = exceededLimit ? nil : takePendingLine()
            pending.removeAll(keepingCapacity: false)
            return (line, complete, exceededLimit)
        }
        if let line = finished.0 { onLine?(line) }
        return (finished.1, finished.2)
    }

    var hasExceededLimit: Bool { lock.withLock { exceededLimit } }
    var hasReadFailure: Bool { lock.withLock { readFailed } }
    func recordReadFailure() { lock.withLock { readFailed = true } }
}

private final class CLIProcessOutputReader: @unchecked Sendable {
    let finished = DispatchSemaphore(value: 0)
    private let source: DispatchSourceRead
    private let descriptor: Int32
    private let output: CLIStreamingOutput

    init(handle: FileHandle, output: CLIStreamingOutput) {
        self.descriptor = handle.fileDescriptor
        self.output = output
        source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor, queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in self?.readAvailable() }
        source.setCancelHandler { [finished] in
            try? handle.close()
            finished.signal()
        }
        let flags = fcntl(descriptor, F_GETFL)
        if flags < 0 || fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) < 0 {
            output.recordReadFailure()
            source.cancel()
        }
        source.activate()
    }

    func cancel() { source.cancel() }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count > 0 {
                output.receive(Data(buffer.prefix(count)))
                if output.hasExceededLimit {
                    source.cancel()
                    return
                }
            } else if count < 0, errno == EINTR {
                continue
            } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                return
            } else {
                if count < 0 { output.recordReadFailure() }
                source.cancel()
                return
            }
        }
    }

    deinit { source.cancel() }
}

private final class CLICommandCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var onCancel: (@Sendable () -> Void)?
    var isCancelled: Bool { lock.withLock { cancelled } }

    func watch(_ handler: @escaping @Sendable () -> Void) {
        let fire = lock.withLock { () -> Bool in
            onCancel = handler
            return cancelled
        }
        if fire { handler() }
    }

    func cancel() {
        let handler = lock.withLock { () -> (@Sendable () -> Void)? in
            cancelled = true
            return onCancel
        }
        handler?()
    }
}

private enum CommandStop {
    case cancelled
    case timedOut
    case outputLimitExceeded
}

private final class ProcessExit: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var finished = false

    func signal() {
        lock.withLock { finished = true }
        semaphore.signal()
    }

    var isFinished: Bool { lock.withLock { finished } }

    func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
        semaphore.wait(timeout: timeout)
    }
}

private final class CommandLifecycle: @unchecked Sendable {
    private enum Settlement {
        case pending
        case done(CommandStop?)
    }

    private let lock = NSLock()
    private var continuation: CheckedContinuation<CommandStop?, Never>?
    private var settlement = Settlement.pending
    private var timer: DispatchSourceTimer?

    func finish(_ reason: CommandStop?) {
        lock.lock()
        guard case .pending = settlement else {
            lock.unlock()
            return
        }
        settlement = .done(reason)
        let continuation = self.continuation
        self.continuation = nil
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
        continuation?.resume(returning: reason)
    }

    func wait(deadline: TimeInterval?) async -> CommandStop? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if case .done(let reason) = settlement {
                lock.unlock()
                continuation.resume(returning: reason)
                return
            }
            self.continuation = continuation
            guard let deadline else {
                lock.unlock()
                return
            }
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
            source.schedule(deadline: .now() + delay, leeway: .milliseconds(50))
            source.setEventHandler { [weak self] in self?.finish(.timedOut) }
            self.timer = source
            lock.unlock()
            source.activate()
        }
    }
}

public enum CLICommandRunner {
    private static let terminationGrace: TimeInterval = 0.25
    private static let streamedDrainPatience: TimeInterval = 10
    private static let lifecyclePoll: TimeInterval = 0.01

    public static func run(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        return try await runLocalSeparated(
            request, onStandardOutputLine: onLine, onStandardErrorLine: onLine)
    }

    public static func runLocal(
        _ request: CLICommandRequest,
        onLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        try await runLocalSeparated(
            request, onStandardOutputLine: onLine, onStandardErrorLine: onLine)
    }

    public static func runSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool = false,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        return try await runLocalSeparated(
            request, streamsWhileRunning: streamsWhileRunning,
            onStandardOutputLine: onStandardOutputLine, onStandardErrorLine: onStandardErrorLine)
    }

    public static func runLocalSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool = false,
        retainsStandardOutput: Bool = true,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void
    ) async throws -> CLICommandResult {
        let cancellation = CLICommandCancellation()
        return try await withTaskCancellationHandler {
            let running = try await BlockingWork.perform {
                try launchSeparated(
                    request, streamsWhileRunning: streamsWhileRunning,
                    retainsStandardOutput: retainsStandardOutput,
                    onStandardOutputLine: onStandardOutputLine,
                    onStandardErrorLine: onStandardErrorLine,
                    cancellationRequested: { cancellation.isCancelled })
            }
            cancellation.watch { running.lifecycle.finish(.cancelled) }
            let stop = await running.wait()
            return try await BlockingWork.perform { try running.finish(stop) }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func launchSeparated(
        _ request: CLICommandRequest, streamsWhileRunning: Bool = false,
        retainsStandardOutput: Bool = true,
        onStandardOutputLine: @escaping @Sendable (String) -> Void,
        onStandardErrorLine: @escaping @Sendable (String) -> Void,
        cancellationRequested: @escaping @Sendable () -> Bool
    ) throws -> LocalCommand {
        let deadline = request.timeout.map {
            ProcessInfo.processInfo.systemUptime + max(0, $0)
        }
        let lifecycle = CommandLifecycle()
        let input = request.standardInputData.map { _ in Pipe() }

        let standardOutput = Pipe()
        let standardError = Pipe()
        let output = CLIStreamingOutput(
            maximumBytes: request.maximumOutputBytes, retainsOutput: retainsStandardOutput,
            onLine: streamsWhileRunning || !retainsStandardOutput ? onStandardOutputLine : nil,
            onLimit: { lifecycle.finish(.outputLimitExceeded) })
        let error = CLIStreamingOutput(
            maximumBytes: request.maximumOutputBytes,
            onLine: streamsWhileRunning ? onStandardErrorLine : nil,
            onLimit: { lifecycle.finish(.outputLimitExceeded) })
        let outputReader = CLIProcessOutputReader(
            handle: standardOutput.fileHandleForReading, output: output)
        let errorReader =
            request.discardsStandardError
            ? nil
            : CLIProcessOutputReader(
                handle: standardError.fileHandleForReading, output: error)

        let processFinished = ProcessExit()
        let process: CLIChildProcess
        do {
            if cancellationRequested() { throw CancellationError() }
            process = try CLIChildProcess(
                request: request,
                input: input?.fileHandleForReading.fileDescriptor
                    ?? FileHandle.nullDevice.fileDescriptor,
                output: standardOutput.fileHandleForWriting.fileDescriptor,
                error: request.discardsStandardError
                    ? FileHandle.nullDevice.fileDescriptor
                    : standardError.fileHandleForWriting.fileDescriptor,
                onExit: {
                    processFinished.signal()
                    lifecycle.finish(nil)
                })
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
        } catch {
            try? standardOutput.fileHandleForWriting.close()
            try? standardError.fileHandleForWriting.close()
            try? input?.fileHandleForReading.close()
            try? input?.fileHandleForWriting.close()
            _ = drain(outputReader)
            _ = drain(errorReader)
            if error is CancellationError { throw error }
            throw CLICommandRunnerError.launchFailed
        }
        let inputFinished = DispatchSemaphore(value: 0)
        if let data = request.standardInputData, let input {
            DispatchQueue.global(qos: .utility).async {
                try? input.fileHandleForWriting.write(contentsOf: data)
                try? input.fileHandleForWriting.close()
                inputFinished.signal()
            }
        } else {
            inputFinished.signal()
        }
        return LocalCommand(
            lifecycle: lifecycle, deadline: deadline, process: process,
            processFinished: processFinished, output: output, error: error,
            outputReader: outputReader, errorReader: errorReader, input: input,
            inputFinished: inputFinished, streamsWhileRunning: streamsWhileRunning,
            onStandardOutputLine: onStandardOutputLine,
            onStandardErrorLine: onStandardErrorLine,
            cancellationRequested: cancellationRequested)
    }

    private final class LocalCommand: @unchecked Sendable {
        let lifecycle: CommandLifecycle
        let deadline: TimeInterval?
        let process: CLIChildProcess
        let processFinished: ProcessExit
        let output: CLIStreamingOutput
        let error: CLIStreamingOutput
        let outputReader: CLIProcessOutputReader
        let errorReader: CLIProcessOutputReader?
        let input: Pipe?
        let inputFinished: DispatchSemaphore
        let streamsWhileRunning: Bool
        let onStandardOutputLine: @Sendable (String) -> Void
        let onStandardErrorLine: @Sendable (String) -> Void
        let cancellationRequested: @Sendable () -> Bool

        init(
            lifecycle: CommandLifecycle, deadline: TimeInterval?, process: CLIChildProcess,
            processFinished: ProcessExit, output: CLIStreamingOutput,
            error: CLIStreamingOutput, outputReader: CLIProcessOutputReader,
            errorReader: CLIProcessOutputReader?, input: Pipe?,
            inputFinished: DispatchSemaphore, streamsWhileRunning: Bool,
            onStandardOutputLine: @escaping @Sendable (String) -> Void,
            onStandardErrorLine: @escaping @Sendable (String) -> Void,
            cancellationRequested: @escaping @Sendable () -> Bool
        ) {
            self.lifecycle = lifecycle
            self.deadline = deadline
            self.process = process
            self.processFinished = processFinished
            self.output = output
            self.error = error
            self.outputReader = outputReader
            self.errorReader = errorReader
            self.input = input
            self.inputFinished = inputFinished
            self.streamsWhileRunning = streamsWhileRunning
            self.onStandardOutputLine = onStandardOutputLine
            self.onStandardErrorLine = onStandardErrorLine
            self.cancellationRequested = cancellationRequested
        }

        func wait() async -> CommandStop? {
            if cancellationRequested() { return .cancelled }
            if output.hasExceededLimit || error.hasExceededLimit { return .outputLimitExceeded }
            if processFinished.isFinished { return nil }
            if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
            return await lifecycle.wait(deadline: deadline)
        }

        func finish(_ stop: CommandStop?) throws -> CLICommandResult {
            defer { ExtensionCommandOwnership.release(process.processIdentifier) }
            if let stop {
                try? input?.fileHandleForWriting.close()
                terminateProcessGroup(process, processFinished: processFinished)
                _ = drain(outputReader)
                _ = drain(errorReader)
                _ = inputFinished.wait(timeout: .now() + terminationGrace)
                switch stop {
                case .cancelled:
                    throw CancellationError()
                case .timedOut:
                    throw CLICommandRunnerError.timedOut
                case .outputLimitExceeded:
                    throw CLICommandRunnerError.outputLimitExceeded
                }
            }
            if process.ownsProcessGroup, process.groupIsAlive {
                terminateProcessGroup(process, processFinished: processFinished)
            }
            let streamsOnly = !output.retainsOutput
            guard
                drain(
                    outputReader,
                    patience: streamsOnly ? streamedDrainPatience : terminationGrace,
                    requiresEnd: streamsOnly),
                drain(errorReader)
            else {
                throw CLICommandRunnerError.streamFailed
            }
            guard inputFinished.wait(timeout: .now() + terminationGrace) == .success else {
                try? input?.fileHandleForWriting.close()
                throw CLICommandRunnerError.streamFailed
            }
            let finishedOutput = output.finish()
            let finishedError = error.finish()
            guard !finishedOutput.exceededLimit, !finishedError.exceededLimit else {
                throw CLICommandRunnerError.outputLimitExceeded
            }
            guard !output.hasReadFailure, !error.hasReadFailure else {
                throw CLICommandRunnerError.streamFailed
            }
            if !streamsWhileRunning {
                for line in String(decoding: finishedOutput.output, as: UTF8.self).split(
                    whereSeparator: \.isNewline)
                {
                    onStandardOutputLine(String(line))
                }
                for line in String(decoding: finishedError.output, as: UTF8.self).split(
                    whereSeparator: \.isNewline)
                {
                    onStandardErrorLine(String(line))
                }
            }
            return CLICommandResult(
                terminationStatus: process.terminationStatus,
                standardOutputData: finishedOutput.output,
                standardErrorData: finishedError.output)
        }
    }

    enum ExitPollResult: Equatable { case finished, timedOut, running }

    static func pollForExit(_ finished: DispatchSemaphore, deadline: TimeInterval?)
        -> ExitPollResult
    {
        if finished.wait(timeout: .now()) == .success { return .finished }
        if let deadline, ProcessInfo.processInfo.systemUptime >= deadline { return .timedOut }
        return finished.wait(timeout: .now() + lifecyclePoll) == .success ? .finished : .running
    }

    private enum StopReason {
        case cancelled
        case timedOut
        case outputLimitExceeded
    }

    private static func terminateProcessGroup(
        _ process: CLIChildProcess, processFinished: ProcessExit
    ) {
        process.signal(SIGTERM)
        _ = processFinished.wait(timeout: .now() + terminationGrace)
        if process.groupIsAlive { process.signal(SIGKILL) }
        if process.isRunning { _ = processFinished.wait(timeout: .now() + terminationGrace) }
    }

    @discardableResult
    private static func drain(
        _ reader: CLIProcessOutputReader?, patience: TimeInterval = terminationGrace,
        requiresEnd: Bool = false
    ) -> Bool {
        guard let reader else { return true }
        if reader.finished.wait(timeout: .now() + patience) == .success { return true }
        reader.cancel()
        return reader.finished.wait(timeout: .now() + terminationGrace) == .success
            && !requiresEnd
    }
}
