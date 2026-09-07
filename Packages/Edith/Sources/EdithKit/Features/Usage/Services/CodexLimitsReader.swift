import Darwin
import Foundation

final class CodexLimitsCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

enum CodexLimitsReader {
    enum Failure: LocalizedError {
        case unavailable
        case timedOut
        case outputTooLarge
        case rejected(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: "The provider did not return rate limits."
            case .timedOut: "The rate-limit request timed out."
            case .outputTooLarge: "The rate-limit response exceeded the size limit."
            case .rejected(let message): "Rate-limit request failed: \(message)"
            }
        }
    }

    struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Double?
        let resetsAt: Double?
    }

    struct Snapshot: Decodable {
        let primary: Window?
        let secondary: Window?
    }

    struct Result: Decodable {
        let rateLimits: Snapshot?
        let rateLimitsByLimitId: [String: Snapshot]?
    }

    struct Response: Decodable {
        struct RPCError: Decodable { let message: String }
        let id: Int?
        let result: Result?
        let error: RPCError?
    }

    static func read(
        executable: URL, arguments: [String] = ["app-server"],
        environment: [String: String], timeout: TimeInterval = 25,
        maximumOutputBytes: Int = 1_048_576
    ) async throws -> ProviderLimits {
        let cancellation = CodexLimitsCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    do {
                        continuation.resume(
                            returning: try readBlocking(
                                executable: executable, arguments: arguments,
                                environment: environment,
                                timeout: timeout, maximumOutputBytes: maximumOutputBytes,
                                cancellation: cancellation))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func readBlocking(
        executable: URL, arguments: [String], environment: [String: String],
        timeout: TimeInterval, maximumOutputBytes: Int, cancellation: CodexLimitsCancellation
    ) throws -> ProviderLimits {
        if cancellation.isCancelled { throw CancellationError() }
        let input = Pipe()
        let output = Pipe()
        defer {
            for handle in [
                input.fileHandleForReading, input.fileHandleForWriting,
                output.fileHandleForReading, output.fileHandleForWriting,
            ] {
                try? handle.close()
            }
        }
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let finished = DispatchSemaphore(value: 0)
        let process = try CLIChildProcess(
            request: CLICommandRequest(
                executableURL: executable, arguments: arguments, environment: environment,
                terminatesProcessGroup: true),
            input: input.fileHandleForReading.fileDescriptor,
            output: output.fileHandleForWriting.fileDescriptor,
            error: FileHandle.nullDevice.fileDescriptor,
            onExit: { finished.signal() })
        defer {
            try? input.fileHandleForWriting.close()
            process.signal(SIGTERM)
            _ = finished.wait(timeout: .now() + 0.25)
            if process.groupIsAlive { process.signal(SIGKILL) }
            if process.isRunning { _ = finished.wait(timeout: .now() + 1) }
        }
        try input.fileHandleForReading.close()
        try output.fileHandleForWriting.close()
        try input.fileHandleForWriting.write(
            contentsOf: Data(
                "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"edith\",\"title\":\"Edith\",\"version\":\"1.0\"}}}\n"
                    .utf8))
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        var pending = Data()
        var received = 0
        var initialized = false
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while ProcessInfo.processInfo.systemUptime < deadline {
            if cancellation.isCancelled { throw CancellationError() }
            var descriptor = pollfd(
                fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0 {
                if errno == EINTR { continue }
                throw Failure.unavailable
            }
            guard ready > 0 else { continue }
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw Failure.unavailable }
            received += count
            guard received <= maximumOutputBytes else { throw Failure.outputTooLarge }
            pending.append(contentsOf: bytes.prefix(count))
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                guard let response = try? JSONDecoder().decode(Response.self, from: line),
                    let id = response.id, id == 0 || id == 1
                else { continue }
                if let error = response.error {
                    throw Failure.rejected(String(error.message.prefix(300)))
                }
                if id == 0, !initialized {
                    initialized = true
                    try input.fileHandleForWriting.write(
                        contentsOf: Data(
                            "{\"method\":\"initialized\",\"params\":{}}\n{\"method\":\"account/rateLimits/read\",\"id\":1,\"params\":{}}\n"
                                .utf8))
                } else if id == 1, initialized, let result = response.result {
                    return try limits(result)
                }
            }
        }
        throw Failure.timedOut
    }

    static func limits(_ result: Result) throws -> ProviderLimits {
        guard let snapshot = result.rateLimitsByLimitId?["codex"] ?? result.rateLimits else {
            throw Failure.unavailable
        }
        let windows = [snapshot.primary, snapshot.secondary].compactMap { $0 }
        guard !windows.isEmpty,
            windows.allSatisfy({
                $0.usedPercent.isFinite && (0...100).contains($0.usedPercent)
                    && ($0.windowDurationMins ?? 0) > 0
            })
        else { throw Failure.unavailable }
        let mapped = windows.map { window in
            (
                duration: window.windowDurationMins ?? 0,
                value: LimitWindow(
                    percent: window.usedPercent,
                    resetsAt: window.resetsAt.map(Date.init(timeIntervalSince1970:)))
            )
        }.sorted { $0.duration < $1.duration }
        return ProviderLimits(
            provider: .codex,
            session: mapped.first { $0.duration < 7 * 24 * 60 }?.value,
            week: mapped.last { $0.duration >= 7 * 24 * 60 }?.value)
    }
}
