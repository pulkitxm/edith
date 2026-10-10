import EdithExtensionCommands
import Foundation

final class CleanerCLIProgress: @unchecked Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let lock = NSLock()
    private let enabled: Bool
    private let sink: @Sendable (String) -> Void
    private var activity: String?
    private var startedAt: Date?
    private var frame = 0
    private var painted = false
    private var ticker: Task<Void, Never>?
    init(json: Bool) {
        enabled = !json && ExtensionCLIContext.request?.interactive == true
        let output = ExtensionCLIContext.outputSink
        sink = { text in if let output { output(text, true) } else { CLIOut.rawError(text) } }
    }
    deinit { ticker?.cancel() }
    func begin(_ text: String) {
        guard enabled else { return }
        end()
        lock.withLock {
            activity = text; startedAt = Date(); frame = 0
        }
        paint()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(90)) } catch { return }
                guard let self, !Task.isCancelled else { return }
                lock.withLock { frame = (frame + 1) % Self.frames.count }
                paint()
            }
        }
    }
    func update(_ text: String) { lock.withLock { activity = text } }
    func end() {
        ticker?.cancel(); ticker = nil
        let clear = lock.withLock {
            activity = nil; startedAt = nil
            let clear = painted; painted = false; return clear
        }
        if enabled && clear { sink("\r\u{1B}[K") }
    }
    private func paint() {
        let text = lock.withLock { () -> String? in
            guard let activity, let startedAt else { return nil }
            painted = true
            let elapsed = String(format: "%.0fs", Date().timeIntervalSince(startedAt))
            return "\r\u{1B}[K  \u{1B}[2m" + Self.frames[frame] + " " + activity + " " + elapsed
                + "\u{1B}[0m"
        }
        if enabled, let text { sink(text) }
    }
}
