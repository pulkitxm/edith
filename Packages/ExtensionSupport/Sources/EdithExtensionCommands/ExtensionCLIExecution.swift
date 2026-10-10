import ArgumentParser
import EdithExtensionSupport
import Foundation

@MainActor public enum ExtensionCLIExecution {
    private static var running = false

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, arguments: [String]
    ) async throws -> ExtensionCLIReply {
        try await run(root, request: ExtensionCLIRequest(arguments: arguments))
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest
    ) async throws -> ExtensionCLIReply {
        let buffer = CLIOutputBuffer()
        let code = try await run(root, request: request) { text, error in
            buffer.append(text, error: error)
        }
        return try buffer.reply(exitCode: code)
    }

    public static func run<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIRequest,
        sink: @escaping @Sendable (String, Bool) -> Void
    ) async throws -> Int32 {
        try request.validate()
        guard !running else {
            throw ExtensionPeerError.rejected("Another terminal command is running.")
        }
        try Task.checkCancellation()
        running = true
        defer { running = false }
        return try await ExtensionCLIContext.$request.withValue(request) {
            try await ExtensionCLIContext.$outputSink.withValue(sink) {
                try await execute(root, arguments: request.arguments)
            }
        }
    }

    private static func execute<Command: AsyncParsableCommand>(
        _ root: Command.Type, arguments: [String]
    ) async throws -> Int32 {
        var exitCode: Int32 = 0
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
                CLIOut.out(root.message(for: error))
            } else {
                CLIOut.note(root.fullMessage(for: error))
            }
            exitCode = resolved == .validationFailure ? 2 : resolved.rawValue
        }
        try Task.checkCancellation()
        return exitCode
    }
}

private final class CLIOutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = ""
    private var stderr = ""
    private var exceeded = false
    private var byteCount = 0

    func append(_ text: String, error: Bool) {
        lock.withLock {
            guard !exceeded else { return }
            let count = text.utf8.count
            guard count <= ExtensionCLIReply.maximumOutputBytes - byteCount
            else {
                exceeded = true; return
            }
            byteCount += count
            if error { stderr += text } else { stdout += text }
        }
    }

    func reply(exitCode: Int32) throws -> ExtensionCLIReply {
        try lock.withLock {
            guard !exceeded else {
                throw ExtensionPeerError.rejected("The terminal output exceeds 4 MiB.")
            }
            return try ExtensionCLIReply(stdout: stdout, stderr: stderr, exitCode: exitCode)
        }
    }
}
