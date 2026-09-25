import Foundation

public enum LocalMachineCommandExecution {
    public static func run(
        _ command: String, stdin: Data? = nil, timeout: TimeInterval = 60
    ) async -> Result<String, Error> {
        await run(
            executable: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", command],
            environment: CLIToolEnvironment.sanitized(), commandLabel: command, stdin: stdin,
            timeout: timeout)
    }

    public static func run(
        executable: URL, arguments: [String], environment: [String: String]? = nil,
        commandLabel: String, stdin: Data? = nil, timeout: TimeInterval = 60
    ) async -> Result<String, Error> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let output = PipeCollector(pipe.fileHandleForReading)
        let stdinPipe: Pipe?
        if stdin != nil {
            let pipe = Pipe()
            stdinPipe = pipe
            process.standardInput = pipe
        } else {
            stdinPipe = nil
            process.standardInput = FileHandle.nullDevice
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return .failure(error)
        }
        if let stdin, let stdinPipe {
            stdinPipe.fileHandleForWriting.write(stdin)
            try? stdinPipe.fileHandleForWriting.close()
        }
        let status = await withTaskCancellationHandler {
            await SSHConnection.waitForExit(process, timeout: timeout)
        } onCancel: {
            process.terminate()
        }
        let text = String(decoding: await output.collected(), as: UTF8.self)
        guard status == 0 else {
            return .failure(
                SSHConnectionError.commandFailed(
                    command: commandLabel, status: status, stderr: text))
        }
        return .success(text)
    }
}
