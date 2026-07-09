import Foundation

public struct ClipboardEntry: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let sha256: String
    public let types: [String]
    public let ext: String
    public let sourceApp: String?
    public let sourceBundleID: String?
    public let createdAt: Date
    public var lastCopiedAt: Date
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
        lastCopiedAt: Date? = nil,
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
        self.lastCopiedAt = lastCopiedAt ?? createdAt
        self.size = size
        self.preview = preview.map { String($0.prefix(500)) }
        self.pinned = pinned
    }

    enum CodingKeys: String, CodingKey {
        case id, sha256, types, ext, sourceApp, sourceBundleID, createdAt, lastCopiedAt, size,
            preview, pinned
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        sha256 = try container.decode(String.self, forKey: .sha256)
        types = try container.decode([String].self, forKey: .types)
        ext = try container.decode(String.self, forKey: .ext)
        sourceApp = try container.decodeIfPresent(String.self, forKey: .sourceApp)
        sourceBundleID = try container.decodeIfPresent(String.self, forKey: .sourceBundleID)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        lastCopiedAt = try container.decodeIfPresent(Date.self, forKey: .lastCopiedAt) ?? createdAt
        size = try container.decode(Int.self, forKey: .size)
        preview = try container.decodeIfPresent(String.self, forKey: .preview)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
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
