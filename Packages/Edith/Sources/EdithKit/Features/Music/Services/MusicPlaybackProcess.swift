import Darwin
import Foundation

public final class MusicPlaybackProcess: @unchecked Sendable {
    private let child: CLIChildProcess
    private let input: FileHandle
    private let output: FileHandle
    private let commands = DispatchQueue(label: "music.playback.commands")

    public init(
        executable: URL, arguments: [String], receive: @escaping @Sendable (Data) -> Void,
        onExit: @escaping @Sendable () -> Void
    ) throws {
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        output.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil } else { receive(data) }
        }
        do {
            child = try CLIChildProcess(
                request: CLICommandRequest(
                    executableURL: executable, arguments: arguments,
                    environment: ProcessInfo.processInfo.environment, terminatesProcessGroup: true),
                input: inputPipe.fileHandleForReading.fileDescriptor,
                output: outputPipe.fileHandleForWriting.fileDescriptor,
                error: FileHandle.nullDevice.fileDescriptor, onExit: onExit)
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
        } catch {
            output.readabilityHandler = nil
            throw error
        }
    }

    deinit {
        output.readabilityHandler = nil
        try? input.close()
        child.signal(SIGTERM)
        let child = child
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if child.groupIsAlive { child.signal(SIGKILL) }
        }
    }

    public func send(_ data: Data, onError: @escaping @Sendable () -> Void) {
        let input = input
        commands.async {
            do { try input.write(contentsOf: data) } catch { onError() }
        }
    }

    public func stop() {
        output.readabilityHandler = nil
        try? input.close()
        child.signal(SIGTERM)
        let child = child
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if child.groupIsAlive { child.signal(SIGKILL) }
        }
    }

    public func waitForExit() async {
        for _ in 0..<100 {
            if !child.isRunning { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
        child.signal(SIGKILL)
    }
}
