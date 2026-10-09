import Darwin
import EdithExtensionSupport
import Foundation

enum HerdrBridgeCommand {
    static func run(encoded: String) throws {
        let specification = try HerdrTerminalBridgeSpecification(encoded: encoded)
        if specification.transport == .terminal {
            try HerdrNativeTerminalBridge.run(specification: specification)
        } else {
            try HerdrTerminalBridgeRuntime(specification: specification).run()
        }
    }
}
struct HerdrBridgeExit: Error { let status: Int32; init(_ status: Int32) { self.status = status } }

struct HerdrTerminalDimensions: Equatable {
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

enum HerdrTerminalStream {
    static func read(from handle: FileHandle) -> Data {
        handle.availableData
    }

    static func read(from handle: FileHandle, timeoutMilliseconds: Int32) throws -> Data? {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        while true {
            let ready = poll(&descriptor, 1, timeoutMilliseconds)
            if ready > 0 { return read(from: handle) }
            if ready == 0 { return nil }
            if errno != EINTR { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
    }
}

struct HerdrTerminalInputRouter {
    private enum Report {
        case incomplete
        case input
        case pointer(hover: Bool, length: Int)
        case scroll(
            direction: HerdrTerminalScrollDirection, column: UInt16, row: UInt16,
            modifiers: UInt8, length: Int)
    }

    private let mouse: HerdrTerminalMouse
    private let transport: HerdrTerminalBridgeSpecification.Transport
    private var pending = Data()

    init(
        mouse: HerdrTerminalMouse = .buttons,
        transport: HerdrTerminalBridgeSpecification.Transport = .records
    ) {
        self.mouse = mouse
        self.transport = transport
    }

    var hasPendingEscapePrefix: Bool { !pending.isEmpty && pending.count < 3 }

    mutating func commands(for data: Data) throws -> [Data] {
        pending.append(data)
        let bytes = [UInt8](pending)
        var commands: [Data] = []
        var inputStart = 0
        var offset = 0

        while offset < bytes.count {
            if bytes[offset] == 0x1B,
                bytes.count - offset == 1
                    || (bytes.count - offset == 2 && bytes[offset + 1] == 0x5B)
            {
                if inputStart < offset {
                    commands.append(
                        try input(Data(bytes[inputStart..<offset])))
                }
                pending = Data(bytes[offset...])
                return commands
            }
            if transport == .records, isFocusReport(bytes, at: offset) {
                if inputStart < offset {
                    commands.append(
                        try input(Data(bytes[inputStart..<offset])))
                }
                offset += 3
                inputStart = offset
                continue
            }
            guard isMousePrefix(bytes, at: offset) else {
                offset += 1
                continue
            }
            switch report(bytes, at: offset) {
            case .incomplete:
                if inputStart < offset {
                    commands.append(
                        try input(Data(bytes[inputStart..<offset])))
                }
                pending = Data(bytes[offset...])
                return commands
            case .input:
                offset += 1
            case let .pointer(hover, length):
                if mouse == .buttons, !hover {
                    offset += length
                    continue
                }
                if inputStart < offset {
                    commands.append(
                        try input(Data(bytes[inputStart..<offset])))
                }
                offset += length
                inputStart = offset
            case let .scroll(direction, column, row, modifiers, length):
                if transport == .terminal {
                    offset += length
                    continue
                }
                if inputStart < offset {
                    commands.append(
                        try input(Data(bytes[inputStart..<offset])))
                }
                commands.append(
                    try HerdrTerminalBridge.scrollCommand(
                        direction: direction, lines: 3, column: column, row: row,
                        modifiers: modifiers))
                offset += length
                inputStart = offset
            }
        }

        if inputStart < bytes.count {
            commands.append(try input(Data(bytes[inputStart...])))
        }
        pending.removeAll(keepingCapacity: true)
        return commands
    }

    mutating func finish() throws -> [Data] {
        guard !pending.isEmpty else { return [] }
        let bytes = pending
        pending.removeAll(keepingCapacity: true)
        guard !bytes.starts(with: [0x1B, 0x5B, 0x3C]) else { return [] }
        return [try input(bytes)]
    }

    private func input(_ bytes: Data) throws -> Data {
        transport == .terminal ? bytes : try HerdrTerminalBridge.inputCommand(bytes)
    }

    mutating func flushEscapePrefix() throws -> [Data] {
        guard hasPendingEscapePrefix else { return [] }
        return try finish()
    }

    private func isFocusReport(_ bytes: [UInt8], at offset: Int) -> Bool {
        bytes.count - offset >= 3
            && bytes[offset] == 0x1B && bytes[offset + 1] == 0x5B
            && (bytes[offset + 2] == 0x49 || bytes[offset + 2] == 0x4F)
    }

    private func isMousePrefix(_ bytes: [UInt8], at offset: Int) -> Bool {
        bytes.count - offset >= 3
            && bytes[offset] == 0x1B && bytes[offset + 1] == 0x5B && bytes[offset + 2] == 0x3C
    }

    private func report(_ bytes: [UInt8], at offset: Int) -> Report {
        var end = offset + 3
        while end < bytes.count {
            let byte = bytes[end]
            if byte == 0x4D || byte == 0x6D {
                return parsedReport(Array(bytes[(offset + 3)..<end]), length: end - offset + 1)
            }
            guard byte == 0x3B || (0x30...0x39).contains(byte) else { return .input }
            end += 1
        }
        return .incomplete
    }

    private func parsedReport(_ payload: [UInt8], length: Int) -> Report {
        let parts = String(decoding: payload, as: UTF8.self).split(
            separator: ";", omittingEmptySubsequences: false)
        guard parts.count == 3, let button = UInt8(parts[0]),
            let oneBasedColumn = UInt16(parts[1]), let oneBasedRow = UInt16(parts[2]),
            oneBasedColumn > 0, oneBasedRow > 0
        else { return .input }
        let buttonNumber = (button & 0b0000_0011) | ((button & 0b1100_0000) >> 4)
        let direction: HerdrTerminalScrollDirection
        switch buttonNumber {
        case 4: direction = .up
        case 5: direction = .down
        default:
            return .pointer(hover: button & 0b0010_0000 != 0 && buttonNumber == 3, length: length)
        }
        var modifiers: UInt8 = 0
        if button & 0b0000_0100 != 0 { modifiers |= 1 }
        if button & 0b0000_1000 != 0 { modifiers |= 4 }
        if button & 0b0001_0000 != 0 { modifiers |= 2 }
        return .scroll(
            direction: direction, column: oneBasedColumn - 1, row: oneBasedRow - 1,
            modifiers: modifiers, length: length)
    }
}

final class HerdrRawTerminal {
    private var original = termios()
    private var configured = false
    private var managesPresentation = true

    func configure(mouse: HerdrTerminalMouse, managesPresentation: Bool = true) throws {
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
        self.managesPresentation = managesPresentation
        if managesPresentation {
            try FileHandle.standardOutput.write(
                contentsOf: HerdrTerminalBridge.startSequence(for: mouse))
        }
    }

    func restore() {
        if configured {
            if managesPresentation {
                try? FileHandle.standardOutput.write(contentsOf: HerdrTerminalBridge.stopSequence)
            }
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
        try terminal.configure(mouse: specification.mouse)
        defer { terminal.restore() }

        let dimensions = HerdrTerminalDimensions.current()
        let request = specification.request(columns: dimensions.columns, rows: dimensions.rows)
        let controllerInput = Pipe()
        let controllerOutput = Pipe()
        let controller = ForegroundProcess.configured(
            executable: URL(fileURLWithPath: request.executable),
            arguments: request.arguments,
            environment: ForegroundProcess.environment(
                assignments: request.environment, inheriting: true))
        controller.standardInput = controllerInput
        controller.standardOutput = controllerOutput
        controller.standardError = FileHandle.standardError
        try controller.run()

        let writer = HerdrTerminalWriter(controllerInput.fileHandleForWriting)
        writer.send(
            try HerdrTerminalBridge.resizeCommand(
                columns: dimensions.columns, rows: dimensions.rows,
                cellWidth: dimensions.cellWidth, cellHeight: dimensions.cellHeight))
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
            throw HerdrBridgeExit(controller.terminationStatus)
        }
    }

    private func startInputForwarding(writer: HerdrTerminalWriter) {
        DispatchQueue.global(qos: .userInteractive).async { [input, specification] in
            var router = HerdrTerminalInputRouter(mouse: specification.mouse)
            while true {
                do {
                    guard
                        let bytes = try HerdrTerminalStream.read(
                            from: input,
                            timeoutMilliseconds: router.hasPendingEscapePrefix ? 40 : -1)
                    else {
                        try router.flushEscapePrefix().forEach(writer.send)
                        continue
                    }
                    guard !bytes.isEmpty else {
                        try router.finish().forEach(writer.send)
                        return
                    }
                    let commands = try router.commands(for: bytes)
                    commands.forEach(writer.send)
                } catch {
                    return
                }
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
        while true {
            let chunk = HerdrTerminalStream.read(from: handle)
            guard !chunk.isEmpty else { break }
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
