import Foundation

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public let types: [String]
    public let ext: String
    public let sourceApp: String?
    public let sourceBundleID: String?
    public let createdAt: Date
    public let size: Int
    public let preview: String?
    public var pinned: Bool

    public init(
        id: String = UUID().uuidString,
        sha256: String,
        types: [String],
        ext: String,
        sourceApp: String?,
        sourceBundleID: String?,
        createdAt: Date = Date(),
        size: Int,
        preview: String?,
        pinned: Bool = false
    ) {
        self.id = id
        self.sha256 = sha256
        self.types = types
        self.ext = ext
        self.sourceApp = sourceApp
        self.sourceBundleID = sourceBundleID
        self.createdAt = createdAt
        self.size = size
        self.preview = preview.map { String($0.prefix(500)) }
        self.pinned = pinned
    }

    public var kind: Kind {
        switch ext {
        case "png", "tiff": .image
        case "url": .file
        case "rtf": .richText
        case "html": .html
        default: .text
        }
    }

    public enum Kind {
        case text, richText, html, image, file
    }
}
