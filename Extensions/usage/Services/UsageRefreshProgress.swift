import Foundation

final class UsageRefreshProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let url: URL
    private var bytes = Data()
    private var closed = false

    init(directory: URL, now: Date = Date()) {
        url = directory.appendingPathComponent("refresh.log")
        bytes = Data((UsageRefreshTranscript.header(at: now).joined(separator: "\n") + "\n").utf8)
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try? UsageDataFiles.write(bytes, to: url)
    }

    func record(_ event: UsageRefreshEvent) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        let text = UsageRefreshTranscript.lines(for: event).joined(separator: "\n") + "\n"
        let line = Data(text.utf8.prefix(4_096))
        if bytes.count + line.count > 65_536 {
            bytes = Data(bytes.suffix(max(0, 65_536 - line.count)))
            if let newline = bytes.firstIndex(of: 10) { bytes.removeSubrange(...newline) }
        }
        bytes.append(line)
        try? UsageDataFiles.write(bytes, to: url)
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
    }
}
