import Darwin
import Foundation

public struct LidAwakeCommandProcessResult: Equatable, Sendable {
    public let terminationStatus: Int32
    public let standardOutput: String
    public let standardError: String
    public let timedOut: Bool
    public let cancelled: Bool

    public init(
        terminationStatus: Int32, standardOutput: String, standardError: String,
        timedOut: Bool, cancelled: Bool
    ) {
        self.terminationStatus = terminationStatus
        self.standardOutput = standardOutput
        self.standardError = standardError
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

public enum LidAwakeCommandProcess {
    public enum Error: LocalizedError, Equatable, Sendable {
        case didNotTerminate

        public var errorDescription: String? {
            "The Lid Awake state process did not terminate."
        }
    }

    public static func run(
        executableURL: URL, arguments: [String], timeout: TimeInterval = 10,
        terminationGrace: TimeInterval = 1, pollInterval: TimeInterval = 0.01,
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> LidAwakeCommandProcessResult {
        if cancelled() {
            return LidAwakeCommandProcessResult(
                terminationStatus: SIGTERM, standardOutput: "", standardError: "",
                timedOut: false, cancelled: true)
        }
        let captureDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-lid-awake-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: captureDirectory, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: captureDirectory) }
        let outputURL = captureDirectory.appendingPathComponent("stdout")
        let errorURL = captureDirectory.appendingPathComponent("stderr")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
            FileManager.default.createFile(atPath: errorURL.path, contents: nil),
            let outputCapture = FileHandle(forWritingAtPath: outputURL.path),
            let errorCapture = FileHandle(forWritingAtPath: errorURL.path)
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer {
            try? outputCapture.close()
            try? errorCapture.close()
        }

        let processID = try spawn(
            executableURL: executableURL, arguments: arguments,
            outputDescriptor: outputCapture.fileDescriptor,
            errorDescriptor: errorCapture.fileDescriptor)
        var waitStatus: Int32?
        let deadline = Date().addingTimeInterval(max(0, timeout))
        while try pollParent(processID, waitStatus: &waitStatus), Date() < deadline,
            !cancelled()
        {
            Thread.sleep(forTimeInterval: max(0.001, pollInterval))
        }
        let wasCancelled = waitStatus == nil && cancelled()
        let timedOut = waitStatus == nil && !wasCancelled
        if waitStatus == nil || processGroupIsAlive(processID) {
            try terminateProcessGroup(
                processID, waitStatus: &waitStatus, grace: terminationGrace,
                pollInterval: pollInterval)
        }
        try reapParent(processID, waitStatus: &waitStatus)
        try outputCapture.synchronize()
        try errorCapture.synchronize()
        let outputData = try Data(contentsOf: outputURL)
        let errorData = try Data(contentsOf: errorURL)
        return LidAwakeCommandProcessResult(
            terminationStatus: terminationStatus(waitStatus ?? 0),
            standardOutput: String(data: outputData, encoding: .utf8) ?? "",
            standardError: String(data: errorData, encoding: .utf8) ?? "",
            timedOut: timedOut, cancelled: wasCancelled)
    }

    private static func spawn(
        executableURL: URL, arguments: [String], outputDescriptor: Int32,
        errorDescriptor: Int32
    ) throws -> pid_t {
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        var processID: pid_t = 0
        let fileActionsStatus = posix_spawn_file_actions_init(&fileActions)
        guard fileActionsStatus == 0 else { throw posixError(fileActionsStatus) }
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        let attributesStatus = posix_spawnattr_init(&attributes)
        guard attributesStatus == 0 else { throw posixError(attributesStatus) }
        defer { posix_spawnattr_destroy(&attributes) }
        for (source, target) in [
            (outputDescriptor, STDOUT_FILENO), (errorDescriptor, STDERR_FILENO),
        ] {
            let duplicateStatus = posix_spawn_file_actions_adddup2(
                &fileActions, source, target)
            guard duplicateStatus == 0 else { throw posixError(duplicateStatus) }
            if source != target {
                let closeStatus = posix_spawn_file_actions_addclose(&fileActions, source)
                guard closeStatus == 0 else { throw posixError(closeStatus) }
            }
        }
        let flagsStatus = posix_spawnattr_setflags(
            &attributes, Int16(POSIX_SPAWN_SETPGROUP))
        guard flagsStatus == 0 else { throw posixError(flagsStatus) }
        let groupStatus = posix_spawnattr_setpgroup(&attributes, 0)
        guard groupStatus == 0 else { throw posixError(groupStatus) }
        let argumentStrings = [executableURL.path] + arguments
        let argumentStorage = argumentStrings.map { strdup($0) }
        guard argumentStorage.allSatisfy({ $0 != nil }) else {
            argumentStorage.compactMap { $0 }.forEach { free($0) }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        defer { argumentStorage.compactMap { $0 }.forEach { free($0) } }
        var argumentPointers = argumentStorage + [nil]
        let spawnStatus = executableURL.path.withCString { executablePath in
            argumentPointers.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &processID, executablePath, &fileActions, &attributes,
                    buffer.baseAddress, environ)
            }
        }
        guard spawnStatus == 0 else { throw posixError(spawnStatus) }
        return processID
    }

    private static func pollParent(
        _ processID: pid_t, waitStatus: inout Int32?
    ) throws -> Bool {
        guard waitStatus == nil else { return false }
        var status: Int32 = 0
        let result = waitpid(processID, &status, WNOHANG)
        if result == processID {
            waitStatus = status
            return false
        }
        if result == 0 { return true }
        if result == -1, errno == EINTR { return true }
        throw posixError(errno)
    }

    private static func reapParent(
        _ processID: pid_t, waitStatus: inout Int32?
    ) throws {
        guard waitStatus == nil else { return }
        while true {
            var status: Int32 = 0
            let result = waitpid(processID, &status, 0)
            if result == processID {
                waitStatus = status
                return
            }
            if result == -1, errno == EINTR { continue }
            throw posixError(errno)
        }
    }

    private static func terminateProcessGroup(
        _ processID: pid_t, waitStatus: inout Int32?, grace: TimeInterval,
        pollInterval: TimeInterval
    ) throws {
        if processGroupIsAlive(processID) { _ = kill(-processID, SIGTERM) }
        let terminatedAfterTerm = try waitForProcessGroup(
            processID, waitStatus: &waitStatus, timeout: grace, pollInterval: pollInterval)
        if terminatedAfterTerm { return }
        if processGroupIsAlive(processID) { _ = kill(-processID, SIGKILL) }
        guard
            try waitForProcessGroup(
                processID, waitStatus: &waitStatus, timeout: grace,
                pollInterval: pollInterval)
        else { throw Error.didNotTerminate }
    }

    private static func waitForProcessGroup(
        _ processID: pid_t, waitStatus: inout Int32?, timeout: TimeInterval,
        pollInterval: TimeInterval
    ) throws -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            _ = try pollParent(processID, waitStatus: &waitStatus)
            if !processGroupIsAlive(processID) { return true }
            Thread.sleep(forTimeInterval: max(0.001, pollInterval))
        } while Date() < deadline
        _ = try pollParent(processID, waitStatus: &waitStatus)
        return !processGroupIsAlive(processID)
    }

    private static func processGroupIsAlive(_ processID: pid_t) -> Bool {
        if kill(-processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func terminationStatus(_ waitStatus: Int32) -> Int32 {
        let signal = waitStatus & 0x7f
        return signal == 0 ? (waitStatus >> 8) & 0xff : signal
    }

    private static func posixError(_ status: Int32) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(status))
    }
}

public enum LidAwakeSystemStateReadError: LocalizedError, Equatable, Sendable {
    case timedOut
    case failed(Int32, String)
    case malformedOutput

    public var errorDescription: String? {
        switch self {
        case .timedOut:
            "Reading the Lid Awake system state timed out."
        case .failed(let status, let message):
            message.isEmpty
                ? "Reading the Lid Awake system state failed with status \(status)." : message
        case .malformedOutput:
            "The Lid Awake system state response did not include SleepDisabled."
        }
    }
}

public enum LidAwakeSystemStateReader {
    typealias Runner =
        @Sendable (
            URL, [String], TimeInterval, @escaping @Sendable () -> Bool
        ) throws -> LidAwakeCommandProcessResult

    public static func read(
        executableURL: URL = URL(fileURLWithPath: LidAwakeCommand.toolPath),
        arguments: [String] = ["-g"], timeout: TimeInterval = 5
    ) async throws -> Bool {
        try await read(
            executableURL: executableURL, arguments: arguments, timeout: timeout,
            runner: { executableURL, arguments, timeout, cancelled in
                try LidAwakeCommandProcess.run(
                    executableURL: executableURL, arguments: arguments, timeout: timeout,
                    cancelled: cancelled)
            })
    }

    static func read(
        executableURL: URL, arguments: [String], timeout: TimeInterval,
        runner: @escaping Runner
    ) async throws -> Bool {
        let task = Task.detached(priority: .utility) {
            try runner(executableURL, arguments, timeout) { Task.isCancelled }
        }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        if result.cancelled { throw CancellationError() }
        if result.timedOut { throw LidAwakeSystemStateReadError.timedOut }
        guard result.terminationStatus == 0 else {
            throw LidAwakeSystemStateReadError.failed(
                result.terminationStatus, result.standardError)
        }
        for line in result.standardOutput.split(whereSeparator: { $0.isNewline }) {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[0] == "SleepDisabled" else { continue }
            if fields[1] == "1" { return true }
            if fields[1] == "0" { return false }
            throw LidAwakeSystemStateReadError.malformedOutput
        }
        throw LidAwakeSystemStateReadError.malformedOutput
    }
}
