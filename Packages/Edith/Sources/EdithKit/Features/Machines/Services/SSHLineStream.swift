import Foundation

private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""

    func receive(_ data: Data) -> [String] {
        guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return [] }
        lock.lock()
        defer { lock.unlock() }
        pending += text
        var lines: [String] = []
        while let newline = pending.firstIndex(where: \.isNewline) {
            lines.append(String(pending[..<newline]))
            pending.removeSubrange(...newline)
        }
        return lines
    }

    func flush() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        let rest = pending
        pending = ""
        return rest.isEmpty ? [] : [rest]
    }
}

private final class StreamCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuations: [CheckedContinuation<Int32, Never>] = []

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                continuations.append(continuation)
                lock.unlock()
            }
        }
    }

    func finish(_ status: Int32) {
        lock.lock()
        guard self.status == nil else {
            lock.unlock()
            return
        }
        self.status = status
        let waiting = continuations
        continuations.removeAll(keepingCapacity: false)
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: status) }
    }
}

public final class SSHLineStream: @unchecked Sendable {
    private let process: Process
    private let stdinData: Data?
    private let onLine: @Sendable (String, Bool) -> Void
    private let onExit: @Sendable (Int32) -> Void
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let stdoutSplitter = LineSplitter()
    private let stderrSplitter = LineSplitter()
    private let completion = StreamCompletion()
    private let outputQueue = DispatchQueue(label: "com.pulkit.edith.ssh-line-stream.output")

    public init(
        process: Process, stdinData: Data? = nil,
        onLine: @escaping @Sendable (String, Bool) -> Void,
        onExit: @escaping @Sendable (Int32) -> Void
    ) {
        self.process = process
        self.stdinData = stdinData
        self.onLine = onLine
        self.onExit = onExit
    }

    deinit {
        cancel()
    }

    public func start() throws {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        let stdout = stdoutSplitter
        let stderr = stderrSplitter
        let deliver = onLine
        let deliverFiltered: @Sendable (String, Bool) -> Void = { line, isStderr in
            guard !isStderr || !SSHTransportDiagnostics.isMultiplexingWarning(line) else {
                return
            }
            deliver(line, isStderr)
        }
        let outputQueue = outputQueue
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            var lines: [String] = []
            PipeReading.consume(handle) { lines = stdout.receive($0) }
            guard !lines.isEmpty else { return }
            outputQueue.async {
                for line in lines { deliverFiltered(line, false) }
            }
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            var lines: [String] = []
            PipeReading.consume(handle) { lines = stderr.receive($0) }
            guard !lines.isEmpty else { return }
            outputQueue.async {
                for line in lines { deliverFiltered(line, true) }
            }
        }
        let finish = onExit
        let completion = completion
        process.terminationHandler = { [stdoutPipe, stderrPipe, completion] finished in
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            outputQueue.async {
                for line in stdout.receive(
                    stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                {
                    deliverFiltered(line, false)
                }
                for line in stdout.flush() { deliverFiltered(line, false) }
                for line in stderr.receive(
                    stderrPipe.fileHandleForReading.readDataToEndOfFile())
                {
                    deliverFiltered(line, true)
                }
                for line in stderr.flush() { deliverFiltered(line, true) }
                completion.finish(finished.terminationStatus)
                finish(finished.terminationStatus)
            }
        }
        if let stdinData {
            let stdinPipe = Pipe()
            process.standardInput = stdinPipe
            try process.run()
            stdinPipe.fileHandleForWriting.write(stdinData)
            try? stdinPipe.fileHandleForWriting.close()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run()
        }
    }

    public func waitForExit() async -> Int32 {
        if Task.isCancelled {
            cancel()
            return 130
        }
        return await withTaskCancellationHandler {
            await completion.wait()
        } onCancel: {
            cancel()
        }
    }

    public func cancel() {
        process.terminationHandler = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        let status = process.isRunning ? 130 : process.terminationStatus
        if process.isRunning {
            process.terminate()
        }
        completion.finish(status)
    }
}

public struct MachineCollectorInvocation: Sendable {
    public let command: String
    public let stdinData: Data?

    public init(command: String, stdinData: Data?) {
        self.command = command
        self.stdinData = stdinData
    }
}

public enum MachineCollector {
    public static let streamCommand = "sh -s -- --stream -i 2"
    public static let onceCommand = "sh -s -- --once"
    public static let windowsScriptTerminator = "@EDITH_SCRIPT_END@"

    public static func invocation(
        for platform: RemoteMachinePlatform, follow: Bool, interval: Int = 2
    ) -> MachineCollectorInvocation? {
        guard let source = script(for: platform, follow: follow, interval: interval) else {
            return nil
        }
        switch platform {
        case .darwin, .linux:
            let command = follow ? "sh -s -- --stream -i \(max(1, interval))" : onceCommand
            return MachineCollectorInvocation(command: command, stdinData: source)
        case .windows:
            var input = source
            guard let terminator = "\n\(windowsScriptTerminator)\n".data(using: .utf8) else {
                return nil
            }
            input.append(terminator)
            let command = PowerShell.command(
                """
                $lines = [Collections.Generic.List[string]]::new()
                while ($null -ne ($line = [Console]::In.ReadLine()) -and
                    $line -ne '\(windowsScriptTerminator)') {
                    $lines.Add($line)
                }
                & ([ScriptBlock]::Create([string]::Join("`n", $lines)))
                """)
            return MachineCollectorInvocation(command: command, stdinData: input)
        }
    }

    public static func script() -> Data? {
        guard
            let url = BundledResources.url(
                forResource: "machine-collector", withExtension: "sh")
        else { return nil }
        return try? Data(contentsOf: url)
    }

    public static func script(
        for platform: RemoteMachinePlatform, follow: Bool = true, interval: Int = 2
    ) -> Data? {
        switch platform {
        case .darwin, .linux:
            return script()
        case .windows:
            guard
                let url = BundledResources.url(
                    forResource: "windows-machine-collector", withExtension: "ps1"),
                let source = try? String(contentsOf: url, encoding: .utf8)
            else { return nil }
            let mode = follow ? "stream" : "once"
            return "$EdithMode = '\(mode)'\n$EdithInterval = \(max(1, interval))\n\(source)"
                .data(using: .utf8)
        }
    }
}
