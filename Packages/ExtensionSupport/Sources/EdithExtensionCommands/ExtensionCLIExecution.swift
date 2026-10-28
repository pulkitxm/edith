import ArgumentParser
import EdithExtensionSupport
import Foundation

@MainActor public enum ExtensionCLIExecution {
    nonisolated public static let maximumConcurrentExecutions = 8
    private static var activeExecutions = 0
    public static var hostVersion: @MainActor () -> String? = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, arguments: [String]
    ) async throws -> ExtensionCLIReply {
        try await run(root, request: ExtensionCLIRequest(arguments: arguments))
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest
    ) async throws -> ExtensionCLIReply {
        let buffer = CLIOutputBuffer()
        let code = try await run(
            root, request: request, rawSink: { data, error in buffer.append(data, error: error) })
        return try buffer.reply(exitCode: code)
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest,
        sink: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> Int32 {
        try await run(root, request: request, input: nil, textSink: sink, rawSink: nil)
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest,
        rawSink: @escaping @Sendable (Data, Bool) -> Void
    ) async throws -> Int32 {
        try await run(root, request: request, input: nil, rawSink: rawSink)
    }

    static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest, input: ExtensionCLIInput?,
        rawSink: @escaping @Sendable (Data, Bool) -> Void
    ) async throws -> Int32 {
        try await run(
            root, request: request, input: input,
            textSink: { text, error in rawSink(Data(text.utf8), error) }, rawSink: rawSink)
    }

    private static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest, input: ExtensionCLIInput?,
        textSink: @escaping @Sendable (String, Bool) -> Void,
        rawSink: (@Sendable (Data, Bool) -> Void)?
    ) async throws -> Int32 {
        try request.validate()
        guard activeExecutions < maximumConcurrentExecutions else {
            throw ExtensionPeerError.rejected(
                "At most eight terminal commands may run concurrently.")
        }
        try Task.checkCancellation()
        activeExecutions += 1
        defer { activeExecutions -= 1 }
        return try await ExtensionCLIContext.$request.withValue(request) {
            try await ExtensionCLIContext.$outputSink.withValue(textSink) {
                try await ExtensionCLIContext.$rawOutputSink.withValue(rawSink) {
                    try await ExtensionCLIContext.$input.withValue(input) {
                        try await execute(root, arguments: request.arguments)
                    }
                }
            }
        }
    }

    private static func presented<Command: AsyncParsableCommand>(
        _ message: String, root: Command.Type
    ) -> String {
        guard let name = root.configuration.commandName else { return message }
        var presented = message.replacingOccurrences(
            of: "USAGE: \(name) ", with: "USAGE: ed \(name) "
        )
        .replacingOccurrences(of: "See '\(name) help", with: "See 'ed \(name) help")
        if root.configuration.version.isEmpty, !presented.contains("--version"),
            let range = presented.range(of: "  -h, --help ")
        {
            presented.insert(
                contentsOf: "  --version               Show the version.\n", at: range.lowerBound)
        }
        return presented
    }

    private static func execute<Command: AsyncParsableCommand>(
        _ root: Command.Type, arguments: [String]
    ) async throws -> Int32 {
        var exitCode: Int32 = 0
        if arguments == ["--version"], root.configuration.version.isEmpty,
            let version = hostVersion()
        {
            CLIOut.out(version)
            return 0
        }
        do {
            var parsed = try root.parseAsRoot(arguments)
            if var async = parsed as? AsyncParsableCommand {
                try await async.run()
            } else {
                try parsed.run()
            }
        } catch let failure as CLIFailure {
            CLIOut.report(failure); exitCode = failure.kind.rawValue
        } catch let exit as ExitCode {
            exitCode = exit.rawValue
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let resolved = root.exitCode(for: error)
            if resolved == .success {
                CLIOut.out(presented(root.message(for: error), root: root))
            } else {
                CLIOut.note(presented(root.fullMessage(for: error), root: root))
            }
            exitCode = resolved == .validationFailure ? 2 : resolved.rawValue
        }
        try Task.checkCancellation()
        return exitCode
    }
}

private final class CLIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()
    private var exceeded = false
    private var byteCount = 0

    func append(_ data: Data, error: Bool) {
        lock.withLock {
            guard !exceeded else { return }
            let count = data.count
            guard count <= ExtensionCLIReply.maximumOutputBytes - byteCount
            else {
                exceeded = true; return
            }
            byteCount += count
            if error { stderr.append(data) } else { stdout.append(data) }
        }
    }

    func reply(exitCode: Int32) throws -> ExtensionCLIReply {
        try lock.withLock {
            guard !exceeded else {
                throw ExtensionPeerError.rejected("The terminal output exceeds 4 MiB.")
            }
            guard let stdout = String(data: stdout, encoding: .utf8),
                let stderr = String(data: stderr, encoding: .utf8)
            else {
                throw ExtensionPeerError.rejected(
                    "The terminal output is not UTF-8. Use a raw output stream.")
            }
            return try ExtensionCLIReply(stdout: stdout, stderr: stderr, exitCode: exitCode)
        }
    }
}
