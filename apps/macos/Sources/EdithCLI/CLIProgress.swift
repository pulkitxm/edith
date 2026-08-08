import EdithKit
import Foundation

public enum CLIStyle {
    nonisolated(unsafe) public static var forcedColor: Bool?

    public static var isInteractive: Bool {
        if let forcedColor { return forcedColor }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return isatty(FileHandle.standardError.fileDescriptor) == 1
    }

    public static func dim(_ text: String) -> String { wrap(text, "2") }
    public static func bold(_ text: String) -> String { wrap(text, "1") }
    public static func green(_ text: String) -> String { wrap(text, "32") }
    public static func red(_ text: String) -> String { wrap(text, "31") }

    private static func wrap(_ text: String, _ code: String) -> String {
        guard isInteractive else { return text }
        return "\u{1B}[\(code)m" + text + "\u{1B}[0m"
    }
}

public final class CLIProgress: @unchecked Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    private let lock = NSLock()
    private let enabled: Bool
    private let handle: FileHandle
    private var activity: String?
    private var activityStartedAt: Date?
    private var frame = 0
    private var ticker: Task<Void, Never>?
    private var painted = false

    public init(enabled: Bool, handle: FileHandle = FileHandle.standardError) {
        self.enabled = enabled
        self.handle = handle
    }

    public static func forCommand(json: Bool) -> CLIProgress {
        CLIProgress(enabled: !json && CLIStyle.isInteractive)
    }

    public var isEnabled: Bool { enabled }

    public func header(_ title: String) {
        emit("")
        emit("  " + CLIStyle.bold(title))
        emit("  " + CLIStyle.dim(String(repeating: "─", count: 52)))
    }

    public func step(_ name: String, _ detail: String, seconds: Double?) {
        let elapsed = seconds.map { String(format: "%.2fs", $0) } ?? ""
        emit(
            "  " + CLIStyle.green("▸") + " " + pad(name, 10) + " " + pad(detail, 32) + " "
                + CLIStyle.dim(leftPad(elapsed, 7)))
    }

    public func note(_ text: String) {
        emit("  " + CLIStyle.dim("· " + text))
    }

    public func summary(_ label: String, _ value: String) {
        emit("  " + CLIStyle.green("✓") + " " + pad(label, 9) + " " + value)
    }

    public func rule() {
        emit("  " + CLIStyle.dim(String(repeating: "─", count: 52)))
    }

    public func failure(_ text: String) {
        emit("  " + CLIStyle.red("✖") + " " + text)
    }

    public func done(_ text: String) {
        emit("  " + CLIStyle.green("✓") + " " + text)
        emit("")
    }

    public func begin(_ text: String) {
        guard enabled else { return }
        lock.lock()
        activity = text
        activityStartedAt = Date()
        frame = 0
        lock.unlock()
        paint()
        startTicker()
    }

    public func update(_ text: String) {
        guard enabled else { return }
        lock.lock()
        activity = text
        lock.unlock()
    }

    public func end() {
        stopTicker()
        lock.lock()
        activity = nil
        activityStartedAt = nil
        lock.unlock()
        clearLine()
    }

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(90))
                guard let self, !Task.isCancelled else { return }
                self.advanceFrame()
            }
        }
    }

    private func advanceFrame() {
        lock.lock()
        frame = (frame + 1) % Self.frames.count
        lock.unlock()
        paint()
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func emit(_ line: String) {
        guard enabled else { return }
        clearLine()
        write(line + "\n")
        paint()
    }

    private func paint() {
        guard enabled else { return }
        lock.lock()
        guard let activity, let startedAt = activityStartedAt else {
            lock.unlock()
            return
        }
        let spinner = Self.frames[frame]
        let elapsed = String(format: "%.0fs", Date().timeIntervalSince(startedAt))
        painted = true
        lock.unlock()
        write("\r\u{1B}[K  " + CLIStyle.dim(spinner + " " + activity + " " + elapsed))
    }

    private func clearLine() {
        guard enabled else { return }
        lock.lock()
        let needed = painted
        painted = false
        lock.unlock()
        guard needed else { return }
        write("\r\u{1B}[K")
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        handle.write(data)
    }

    private func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
    }

    private func leftPad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text : String(repeating: " ", count: width - text.count) + text
    }
}

public struct TransferMeter: Sendable {
    public let total: Int64?
    public let label: String

    public init(total: Int64?, label: String) {
        self.total = total
        self.label = label
    }

    public func text(sent: Int64) -> String {
        guard let total, total > 0 else {
            return "\(label)  \(ByteFormatter.string(sent))"
        }
        let percent = Int((Double(sent) / Double(total) * 100).rounded())
        return
            "\(label)  \(ByteFormatter.string(sent)) of \(ByteFormatter.string(total))  \(min(percent, 100))%"
    }
}
