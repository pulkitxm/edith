import Foundation
public enum EmbeddedDownloadStatus: Equatable, Codable, Sendable {
    case queued
    case resolving
    case downloading(progress: String, videoIndex: Int, videoCount: Int)
    case done(String)
    case error(String)
    case interrupted(String?)

    enum CodingKeys: String, CodingKey {
        case kind, value, a, b, c
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "queued": self = .queued
        case "resolving": self = .resolving
        case "downloading":
            let p = try c.decodeIfPresent(String.self, forKey: .value) ?? ""
            let vi = try c.decodeIfPresent(Int.self, forKey: .a) ?? 0
            let vc = try c.decodeIfPresent(Int.self, forKey: .b) ?? 0
            self = .downloading(progress: p, videoIndex: vi, videoCount: vc)
        case "done":
            self = .done(try c.decode(String.self, forKey: .value))
        case "error":
            self = .error(try c.decode(String.self, forKey: .value))
        case "interrupted":
            self = .interrupted(try c.decodeIfPresent(String.self, forKey: .value))
        default: self = .interrupted(nil)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued: try c.encode("queued", forKey: .kind)
        case .resolving: try c.encode("resolving", forKey: .kind)
        case let .downloading(p, vi, vc):
            try c.encode("downloading", forKey: .kind)
            try c.encode(p, forKey: .value)
            try c.encode(vi, forKey: .a)
            try c.encode(vc, forKey: .b)
        case let .done(o):
            try c.encode("done", forKey: .kind)
            try c.encode(o, forKey: .value)
        case let .error(e):
            try c.encode("error", forKey: .kind)
            try c.encode(e, forKey: .value)
        case let .interrupted(r):
            try c.encode("interrupted", forKey: .kind)
            try c.encodeIfPresent(r, forKey: .value)
        }
    }
}

public enum EmbeddedDownloadKind: String, Codable, Sendable, CaseIterable {
    case post
    case images
    case audio
    case video

    public var title: String {
        switch self {
        case .post: "Entire post"
        case .images: "Images"
        case .audio: "Audio"
        case .video: "Video"
        }
    }

    public var fileExtension: String {
        switch self {
        case .post, .images: "original"
        case .audio: "m4a"
        case .video: "mp4"
        }
    }
}

public struct EmbeddedDownloadEstimate: Codable, Equatable, Sendable {
    public let audioBytes: Int64?
    public let videoBytes: Int64?
    public let approximate: Bool

    public init(audioBytes: Int64?, videoBytes: Int64?, approximate: Bool) {
        self.audioBytes = audioBytes
        self.videoBytes = videoBytes
        self.approximate = approximate
    }

    public func bytes(for kind: EmbeddedDownloadKind) -> Int64? {
        switch kind {
        case .post, .images: nil
        case .audio: audioBytes
        case .video: videoBytes
        }
    }

    public static func + (lhs: EmbeddedDownloadEstimate, rhs: EmbeddedDownloadEstimate)
        -> EmbeddedDownloadEstimate
    {
        EmbeddedDownloadEstimate(
            audioBytes: sum(lhs.audioBytes, rhs.audioBytes),
            videoBytes: sum(lhs.videoBytes, rhs.videoBytes),
            approximate: lhs.approximate || rhs.approximate)
    }

    private static func sum(_ a: Int64?, _ b: Int64?) -> Int64? {
        guard let a else { return b }
        guard let b else { return a }
        return a + b
    }
}

public struct EmbeddedDownloadRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var url: URL
    public var status: EmbeddedDownloadStatus
    public var outputFilename: String?
    public var createdAt: Date
    public var kind: EmbeddedDownloadKind?
    public var resultPaths: [String]?
    public var browser: EmbeddedDownloadBrowser?

    public init(
        id: UUID = UUID(), url: URL, status: EmbeddedDownloadStatus, outputFilename: String?,
        createdAt: Date,
        kind: EmbeddedDownloadKind?, resultPaths: [String]? = nil,
        browser: EmbeddedDownloadBrowser? = nil
    ) {
        self.id = id
        self.url = url
        self.status = status
        self.outputFilename = outputFilename
        self.createdAt = createdAt
        self.kind = kind
        self.resultPaths = resultPaths
        self.browser = browser
    }

    public var state: String {
        switch status {
        case .queued: return "queued"
        case .resolving: return "resolving"
        case .downloading: return "downloading"
        case .done: return "done"
        case .error: return "failed"
        case .interrupted: return "interrupted"
        }
    }

    public var detail: String {
        switch status {
        case let .downloading(progress, index, count):
            return count > 1 ? "\(progress) (\(index)/\(count))" : progress
        case let .done(output): return output
        case let .error(message): return message
        case let .interrupted(reason): return reason ?? ""
        case .queued, .resolving: return ""
        }
    }

    public var isFinished: Bool {
        switch status {
        case .done, .error, .interrupted: return true
        case .queued, .resolving, .downloading: return false
        }
    }

    public var canRetry: Bool {
        switch status {
        case .error, .interrupted: return true
        default: return false
        }
    }

    public var title: String {
        if case let .done(output) = status {
            let first = output.components(separatedBy: ", ").first ?? output
            let stem = (first as NSString).deletingPathExtension
            if !stem.isEmpty { return (stem as NSString).lastPathComponent }
        }
        return url.absoluteString
    }
}

public enum EmbeddedDownloadBrowser: String, Codable, CaseIterable, Sendable {
    case safari, chrome, firefox, brave, edge
}

public enum EmbeddedMediaDownloadInput {
    public static func isValid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
            && !url.absoluteString.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    @MainActor public static func defaultDirectory(for kind: EmbeddedDownloadKind) -> URL {
        EmbeddedYoutubeDownloader.shared.directories[kind.rawValue] ?? URL(fileURLWithPath: "/")
    }

    public static func isDirectImage(_ url: URL) -> Bool {
        ["jpg", "jpeg", "png", "gif", "webp", "avif", "heic", "tiff", "bmp"]
            .contains(url.pathExtension.lowercased())
    }
}
