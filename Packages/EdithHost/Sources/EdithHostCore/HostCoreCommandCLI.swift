import EdithExtensionSupport
import Foundation

@MainActor public struct HostCoreCommandCLI {
    public typealias Invoke =
        @MainActor @Sendable (HostAgentCommandOperation, Data) async throws -> Data
    private let invoke: Invoke
    private let environment: @MainActor () -> [String: String]
    private let workingDirectory: @MainActor () -> String

    public init(
        invoke: @escaping Invoke,
        environment: @escaping @MainActor () -> [String: String] = { Self.currentEnvironment() },
        workingDirectory: @escaping @MainActor () -> String = {
            FileManager.default.currentDirectoryPath
        }
    ) {
        self.invoke = invoke; self.environment = environment;
        self.workingDirectory = workingDirectory
    }

    public func execute(
        _ arguments: [String], streamWrite: (@Sendable (Data, Bool) async throws -> Void)? = nil
    ) async throws -> ExtensionCLIReply {
        do {
            guard let domain = arguments.first else {
                throw HostCLIError.usage("Unknown core command group.")
            }
            let remainder = Array(arguments.dropFirst())
            if domain == "tasks" { return try await tasks(remainder, streamWrite: streamWrite) }
            if domain == "schedule" { return try await schedules(remainder) }
            throw HostCLIError.usage("Unknown core command group.")
        } catch let error as HostAgentCommandError {
            return try HostCoreCommandFailure(
                error.message, code: error.kind == .unavailable ? 4 : 1
            ).reply()
        }
    }

    public static func currentEnvironment() -> [String: String] {
        #if EDITH_CLI_FIXTURE
        ProcessInfo.processInfo.environment
        #else
        CLIToolEnvironment.sanitized()
        #endif
    }

    private func tasks(
        _ arguments: [String], streamWrite: (@Sendable (Data, Bool) async throws -> Void)?
    ) async throws -> ExtensionCLIReply {
        let action = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "ls"
        let remainder = action == arguments.first ? Array(arguments.dropFirst()) : arguments
        if action == "exec" { return try await exec(remainder, streamWrite: streamWrite) }
        let args = try HostCLIArguments(remainder, flags: ["--json"])
        try args.require(words: action == "ls" ? 0...0 : 1...1, flags: ["--json"])
        let json = args.flags.contains("--json")
        switch action {
        case "ls":
            let tasks: [HostAgentTaskSnapshot] = try await call(.list)
            if json { return try Self.json(tasks) }
            return try HostCLIOutput.text(
                HostCLIOutput.table(
                    headers: ["ID", "STATE", "TITLE"],
                    rows: tasks.map { [$0.id.uuidString, $0.state.rawValue, $0.title] }))
        case "inspect", "cancel":
            guard let id = UUID(uuidString: args.words[0]) else {
                throw HostCLIError.usage("Enter a task UUID from ed agent tasks ls.")
            }
            if action == "cancel" {
                let task: HostAgentTaskSnapshot = try await call(
                    .cancel, HostAgentTaskIDRequest(id: id))
                return json
                    ? try Self.json(task)
                    : try HostCLIOutput.text("\(task.id): \(task.state.rawValue)")
            }
            let status: HostAgentTaskStatus = try await call(
                .status, HostAgentTaskIDRequest(id: id))
            if json { return try Self.json(status) }
            var lines =
                ["\(status.snapshot.title): \(status.snapshot.state.rawValue)"]
                + status.output.map(\.text)
            if let failure = status.snapshot.failure { lines.append(failure) }
            return try HostCLIOutput.text(lines.joined(separator: "\n"))
        default: throw HostCLIError.usage("Unknown agent tasks command.")
        }
    }

    private func exec(
        _ arguments: [String], streamWrite: (@Sendable (Data, Bool) async throws -> Void)?
    ) async throws -> ExtensionCLIReply {
        let (prefix, command) = try Self.command(arguments)
        let args = try HostCLIArguments(
            prefix, flags: ["--json", "--detach"], options: ["--timeout"])
        try args.require(words: 0...0, flags: ["--json", "--detach"], options: ["--timeout"])
        let timeout = try Self.timeout(args.options["--timeout"])
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: command[0]), arguments: Array(command.dropFirst()),
            environment: environment(),
            currentDirectoryURL: URL(fileURLWithPath: workingDirectory()), timeout: timeout,
            maximumOutputBytes: 4 << 20, terminatesProcessGroup: true)
        let submission = HostAgentTaskSubmission(
            operation: HostAgentTaskOperation.command,
            title: "Running " + request.executableURL.lastPathComponent,
            payload: try HostAgentPayload.encode(request))
        let json = args.flags.contains("--json")
        if args.flags.contains("--detach") {
            let task: HostAgentTaskSnapshot = try await call(.submit, submission)
            return json ? try Self.json(task) : try HostCLIOutput.text(task.id.uuidString)
        }
        let result: CLICommandResult
        do {
            let _: HostAgentTaskSnapshot = try await call(.submit, submission)
            result = try await waitCommand(submission.id, timeout: timeout)
        } catch {
            let cancel = invoke
            let payload = try HostAgentPayload.encode(HostAgentTaskIDRequest(id: submission.id))
            await Task.detached {
                for attempt in 0..<3 {
                    do { _ = try await cancel(.cancel, payload); return } catch {
                        guard attempt < 2 else { return }
                        try? await Task.sleep(for: .milliseconds(50))
                    }
                }
            }.value
            throw error
        }
        if json {
            return try ExtensionCLIReply(
                stdout: String(decoding: HostAgentPayload.encode(result), as: UTF8.self) + "\n",
                stderr: "", exitCode: result.terminationStatus)
        }
        if let streamWrite {
            try await streamWrite(result.standardOutputData, false)
            try await streamWrite(result.standardErrorData, true)
            return try ExtensionCLIReply(stdout: "", stderr: "", exitCode: result.terminationStatus)
        }
        guard let stdout = String(data: result.standardOutputData, encoding: .utf8),
            let stderr = String(data: result.standardErrorData, encoding: .utf8)
        else {
            throw HostCoreCommandFailure("Raw command output requires a byte output sink.")
        }
        return try ExtensionCLIReply(
            stdout: stdout, stderr: stderr, exitCode: result.terminationStatus)
    }

    private func waitCommand(_ id: UUID, timeout: Double) async throws -> CLICommandResult {
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout + 30))
        var delay = 0.25
        var previous: HostAgentTaskState?
        var sequence = 0
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let status: HostAgentTaskStatus = try await call(
                .status, HostAgentTaskIDRequest(id: id))
            if status.snapshot.state == .cancelled { throw CancellationError() }
            if status.snapshot.state.isTerminal {
                if status.snapshot.state == .succeeded
                    || status.snapshot.failureCode == "commandExit", let result = status.result
                {
                    return try HostAgentPayload.decode(CLICommandResult.self, from: result)
                }
                switch status.snapshot.failureCode {
                case "timedOut": throw CLICommandRunnerError.timedOut
                case "outputLimitExceeded": throw CLICommandRunnerError.outputLimitExceeded
                case "launchFailed": throw CLICommandRunnerError.launchFailed
                case "streamFailed": throw CLICommandRunnerError.streamFailed
                default:
                    throw HostAgentTaskFailure(snapshot: status.snapshot, result: status.result)
                }
            }
            let current = status.output.last?.sequence ?? 0
            delay =
                previous == status.snapshot.state && sequence == current
                ? min(2, delay * 1.5) : 0.25
            previous = status.snapshot.state; sequence = current
            try await Task.sleep(for: .seconds(delay))
        }
        throw HostAgentCommandError(
            .unavailable, "The owned task did not finish before the bounded wait expired.")
    }

    private func schedules(_ arguments: [String]) async throws -> ExtensionCLIReply {
        let action = arguments.first.flatMap { $0.hasPrefix("-") ? nil : $0 } ?? "ls"
        let remainder = action == arguments.first ? Array(arguments.dropFirst()) : arguments
        if action == "add" {
            let (prefix, command) = try Self.command(remainder)
            let args = try HostCLIArguments(
                prefix, flags: ["--json"], options: ["--every", "--cron", "--cwd", "--timeout"])
            try args.require(
                words: 1...1, flags: ["--json"],
                options: ["--every", "--cron", "--cwd", "--timeout"])
            let definition = try HostScheduledTaskDefinition(
                name: args.words[0],
                schedule: HostAgentSchedule.parse(
                    every: args.options["--every"], cron: args.options["--cron"]),
                executablePath: command[0], arguments: Array(command.dropFirst()),
                workingDirectory: args.options["--cwd"] ?? workingDirectory(),
                timeout: Self.timeout(args.options["--timeout"], validatePositive: false))
            let added: HostScheduledTaskSnapshot = try await call(.scheduleAdd, definition)
            return try Self.schedule(added, json: args.flags.contains("--json"))
        }
        let args = try HostCLIArguments(remainder, flags: ["--json"])
        try args.require(words: action == "ls" ? 0...0 : 1...1, flags: ["--json"])
        let json = args.flags.contains("--json")
        switch action {
        case "ls":
            let schedules: [HostScheduledTaskSnapshot] = try await call(.scheduleList)
            if json { return try Self.json(schedules) }
            return try HostCLIOutput.text(
                HostCLIOutput.table(
                    headers: ["NAME", "SCHEDULE", "STATE", "NEXT", "LAST", "COMMAND"],
                    rows: schedules.map {
                        [
                            $0.definition.name, $0.definition.schedule.text,
                            $0.enabled ? "enabled" : "disabled", Self.date($0.nextRunAt),
                            [Self.date($0.lastRunAt), $0.lastState?.rawValue].compactMap { $0 }
                                .joined(separator: " "), $0.definition.commandLine,
                        ]
                    }))
        case "rm":
            let _: HostCLIJSON = try await call(
                .scheduleRemove, HostAgentScheduleNameRequest(name: args.words[0]))
            return json
                ? try HostCLIOutput.json(
                    .object(["name": .string(args.words[0]), "removed": .bool(true)]))
                : try HostCLIOutput.text("removed " + args.words[0])
        case "enable", "disable":
            let value: HostScheduledTaskSnapshot = try await call(
                .scheduleEnabled,
                HostAgentScheduleEnabledRequest(name: args.words[0], enabled: action == "enable"))
            return try Self.schedule(value, json: json)
        case "run":
            let task: HostAgentTaskSnapshot = try await call(
                .scheduleRun, HostAgentScheduleNameRequest(name: args.words[0]))
            return json ? try Self.json(task) : try HostCLIOutput.text(task.id.uuidString)
        default: throw HostCLIError.usage("Unknown agent schedule command.")
        }
    }

    private func call<T: Decodable>(_ operation: HostAgentCommandOperation) async throws -> T {
        try HostAgentPayload.decode(T.self, from: await invoke(operation, Data("{}".utf8)))
    }
    private func call<T: Decodable>(
        _ operation: HostAgentCommandOperation, _ payload: some Encodable
    ) async throws -> T {
        try Task.checkCancellation()
        return try HostAgentPayload.decode(
            T.self, from: await invoke(operation, HostAgentPayload.encode(payload)))
    }
    private static func json(_ value: some Encodable) throws -> ExtensionCLIReply {
        try HostCLIOutput.text(String(decoding: HostAgentPayload.encode(value), as: UTF8.self))
    }
    private static func schedule(_ value: HostScheduledTaskSnapshot, json: Bool) throws
        -> ExtensionCLIReply
    {
        json
            ? try Self.json(value)
            : try HostCLIOutput.text(
                "\(value.definition.name): \(value.enabled ? "enabled" : "disabled"), \(value.definition.schedule.text)"
            )
    }
    private static func date(_ value: Date?) -> String { value.map { $0.ISO8601Format() } ?? "-" }
    private static func command(_ arguments: [String]) throws -> ([String], [String]) {
        guard let separator = arguments.firstIndex(of: "--"), separator + 1 < arguments.count,
            arguments[separator + 1].hasPrefix("/")
        else { throw HostCLIError.usage("Provide an absolute executable path after --.") }
        return (Array(arguments[..<separator]), Array(arguments[(separator + 1)...]))
    }
    private static func timeout(_ value: String?, validatePositive: Bool = true) throws -> Double {
        let timeout = value.flatMap(Double.init) ?? (value == nil ? 300 : .nan)
        guard value == nil || Double(value!) != nil else {
            throw HostCLIError.usage("Timeout must be a number.")
        }
        guard !validatePositive || timeout.isFinite && timeout > 0 else {
            throw HostCLIError.usage("Timeout must be a positive number.")
        }
        return timeout
    }
}
