import Foundation

struct MusicDownloadsState: Codable, Sendable {
    var snapshot: DownloadWorkerSnapshot
    var unavailableReason: String?
    var updating: Bool
    var updateMessage: String?
    var updateError: String?
    var directories: [String: URL]
}

enum MusicDownloadActionKind: String, Codable, Sendable {
    case enqueue, retry, retryAll, clearHistory, remove, cancel, cancelAll
    case checkAvailability, updateTools, open, reveal
}

struct MusicDownloadAction: Codable, Sendable {
    var kind: MusicDownloadActionKind
    var id: UUID?
    var urls: [URL] = []
    var prefix = ""
    var downloadKind = DownloadKind.audio
    var outputDirectory: URL?
    var browser: DownloadBrowser?
}
