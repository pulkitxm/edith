import Foundation

struct EmbeddedMusicDownloadsState: Codable, Sendable {
    var snapshot: EmbeddedDownloadWorkerSnapshot
    var unavailableReason: String?
    var updating: Bool
    var updateMessage: String?
    var updateError: String?
    var directories: [String: URL]
}

enum EmbeddedMusicDownloadActionKind: String, Codable, Sendable {
    case enqueue, retry, retryAll, clearHistory, remove, cancel, cancelAll
    case checkAvailability, updateTools, open, reveal
}

struct EmbeddedMusicDownloadAction: Codable, Sendable {
    var kind: EmbeddedMusicDownloadActionKind
    var id: UUID?
    var urls: [URL] = []
    var prefix = ""
    var downloadKind = EmbeddedDownloadKind.audio
    var outputDirectory: URL?
    var browser: EmbeddedDownloadBrowser?
}
public struct EmbeddedDownloadWorkerSnapshot: Codable, Sendable {
    public let readAt: Date
    public let generation: UUID
    public let revision: Int
    public let queued: Int
    public let running: Int
    public let finished: Int
    public let failed: Int
    public let records: [EmbeddedDownloadRecord]
    public let logs: [String: String]
    public let enabled: Bool
    public let problem: String?
    public let executable: URL?

    public init(
        records: [EmbeddedDownloadRecord], logs: [String: String], enabled: Bool, running: Bool,
        generation: UUID, revision: Int, problem: String? = nil, executable: URL? = nil
    ) {
        self.problem = problem
        self.executable = executable
        self.generation = generation
        self.revision = revision
        self.readAt = Date()
        self.records = records
        self.logs = logs
        self.enabled = enabled
        self.queued = records.count { $0.status == .queued }
        self.running = running ? 1 : 0
        self.finished = records.count { if case .done = $0.status { true } else { false } }
        self.failed = records.count { $0.canRetry }
    }
}
