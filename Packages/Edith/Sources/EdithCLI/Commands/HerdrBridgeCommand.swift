import ArgumentParser
import Darwin
import EdithKit
import Foundation

struct HerdrBridgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bridge", shouldDisplay: false)

    @Argument var specification: String

    func run() throws {
        let specification = try HerdrTerminalBridgeSpecification(encoded: specification)
        try HerdrTerminalBridgeRuntime(specification: specification).run()
    }
}

private struct HerdrTerminalDimensions: Equatable {
    let columns: UInt16
    let rows: UInt16
    let cellWidth: UInt32
    let cellHeight: UInt32

    static func current() -> Self {
        var size = winsize()
        guard ioctl(STDIN_FILENO, TIOCGWINSZ, &size) == 0,
            size.ws_col > 0, size.ws_row > 0
        else { return Self(columns: 80, rows: 24, cellWidth: 0, cellHeight: 0) }
        let cellWidth = size.ws_xpixel > 0 ? UInt32(size.ws_xpixel) / UInt32(size.ws_col) : 0
        let cellHeight = size.ws_ypixel > 0 ? UInt32(size.ws_ypixel) / UInt32(size.ws_row) : 0
        return Self(
            columns: size.ws_col, rows: size.ws_row,
            cellWidth: cellWidth, cellHeight: cellHeight)
    }
}

private final class HerdrTerminalWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var open = true

    init(_ handle: FileHandle) {
        self.handle = handle
    }

    func send(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        do {
            try handle.write(contentsOf: data)
        } catch {
            open = false
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard open else { return }
        open = false
        try? handle.close()
    }
}

private final class HerdrRawTerminal {
    private var original = termios()
    private var configured = false

    func configure() throws {
        guard isatty(STDIN_FILENO) == 1 else { return }
        guard tcgetattr(STDIN_FILENO, &original) == 0 else {
            throw POSIXError(.EIO)
        }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == 0 else {
            throw POSIXError(.EIO)
        }
        configured = true
        try FileHandle.standardOutput.write(contentsOf: HerdrTerminalBridge.startSequence)
    }

    func restore() {
        if configured {
            try? FileHandle.standardOutput.write(contentsOf: HerdrTerminalBridge.stopSequence)
            _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
            configured = false
        }
    }

    deinit {
        restore()
    }
}

private final class HerdrTerminalBridgeRuntime {
    private let specification: HerdrTerminalBridgeSpecification
    private let input = FileHandle.standardInput
    private let output = FileHandle.standardOutput

    init(specification: HerdrTerminalBridgeSpecification) {
        self.specification = specification
    }

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let terminal = HerdrRawTerminal()
        try terminal.configure()
        defer { terminal.restore() }

        let dimensions = HerdrTerminalDimensions.current()
        let request = specification.request(columns: dimensions.columns, rows: dimensions.rows)
        let controller = Process()
        let controllerInput = Pipe()
        let controllerOutput = Pipe()
        controller.executableURL = URL(fileURLWithPath: request.executable)
        controller.arguments = request.arguments
        controller.environment = ForegroundProcess.environment(
            assignments: request.environment, inheriting: true)
        controller.standardInput = controllerInput
        controller.standardOutput = controllerOutput
        controller.standardError = FileHandle.standardError
        try controller.run()

        let writer = HerdrTerminalWriter(controllerInput.fileHandleForWriting)
        let resizeTimer = startResizeTimer(writer: writer, initial: dimensions)
        startInputForwarding(writer: writer)
        defer {
            resizeTimer.cancel()
            writer.close()
            if controller.isRunning { controller.terminate() }
            controller.waitUntilExit()
        }

        try forwardFrames(from: controllerOutput.fileHandleForReading)
        controller.waitUntilExit()
        guard controller.terminationStatus == 0 else {
            throw ExitCode(controller.terminationStatus)
        }
    }

    private func startInputForwarding(writer: HerdrTerminalWriter) {
        DispatchQueue.global(qos: .userInteractive).async { [input] in
            while let bytes = try? input.read(upToCount: 4096), !bytes.isEmpty {
                guard let command = try? HerdrTerminalBridge.inputCommand(bytes) else { return }
                writer.send(command)
            }
        }
    }

    private func startResizeTimer(
        writer: HerdrTerminalWriter, initial: HerdrTerminalDimensions
    ) -> DispatchSourceTimer {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInteractive))
        let state = HerdrTerminalDimensionState(initial)
        timer.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(150))
        timer.setEventHandler {
            let next = HerdrTerminalDimensions.current()
            guard state.replace(ifChanged: next) else { return }
            guard
                let command = try? HerdrTerminalBridge.resizeCommand(
                    columns: next.columns, rows: next.rows,
                    cellWidth: next.cellWidth, cellHeight: next.cellHeight)
            else { return }
            writer.send(command)
        }
        timer.activate()
        return timer
    }

    private func forwardFrames(from handle: FileHandle) throws {
        var buffer = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[..<newline]
                buffer.removeSubrange(...newline)
                guard !line.isEmpty else { continue }
                switch try HerdrTerminalBridge.decodeRecord(Data(line)) {
                case let .frame(bytes):
                    try output.write(contentsOf: bytes)
                case .closed:
                    return
                case .ignored:
                    break
                }
            }
        }
        if !buffer.isEmpty {
            switch try HerdrTerminalBridge.decodeRecord(buffer) {
            case let .frame(bytes):
                try output.write(contentsOf: bytes)
            case .closed, .ignored:
                break
            }
        }
    }
}

private final class HerdrTerminalDimensionState: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HerdrTerminalDimensions

    init(_ value: HerdrTerminalDimensions) {
        self.value = value
    }

    func replace(ifChanged next: HerdrTerminalDimensions) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard next != value else { return false }
        value = next
        return true
    }
}
