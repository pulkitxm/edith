import Foundation
import UniformTypeIdentifiers

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
        preview = try container.decodeIfPresent(String.self, forKey: .preview).map {
            String($0.prefix(500))
        }
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    public var kind: Kind {
        switch ext {
        case "png", "tiff", "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "bmp",
            "ico", "avif", "image":
            return .image
        case "url", "files", "weburl": return .file
        case "rtf", "rtfd": return .richText
        case "html": return .html
        case "pdf", "ps", "eps", "doc", "docx", "pages", "key", "numbers", "ppt", "pptx",
            "xls", "xlsx":
            return .document
        case "mp3", "m4a", "wav", "aiff", "flac", "ogg", "mp4", "mov", "m4v", "avi",
            "webm":
            return .media
        case "zip", "gz", "bz2", "xz", "tar", "7z", "rar", "sqlite", "sqlite3", "db", "data",
            "color", "ttf", "otf", "woff", "woff2", "usd", "usdz":
            return .data
        case let value where ClipboardTextKinds.isText(value):
            return .text
        default:
            for identifier in types {
                guard let type = UTType(identifier) else { continue }
                if type.conforms(to: .image) { return .image }
                if type.conforms(to: .text) { return .text }
                if let media = UTType("public.audiovisual-content"), type.conforms(to: media) {
                    return .media
                }
                if let document = UTType("public.composite-content"), type.conforms(to: document) {
                    return .document
                }
            }
            return .data
        }
    }

    public enum Kind: String, CaseIterable, Sendable {
        case text, richText, html, image, file, document, media, data
    }

    public var isTextual: Bool {
        switch kind {
        case .text, .richText, .html: return true
        default: return false
        }
    }

    public var displayPreview: String {
        if let preview {
            let initial = preview.prefix(500)
            if initial.unicodeScalars.contains(where: {
                !CharacterSet.whitespacesAndNewlines.contains($0)
                    && !CharacterSet.controlCharacters.contains($0)
            }) {
                return String(initial)
            }
        }
        switch kind {
        case .image: return "Image"
        case .file: return "File"
        case .richText: return "Rich text"
        case .html: return "HTML"
        case .document: return "Document"
        case .media: return "Media"
        case .data: return "Clipboard data"
        case .text: return "Text"
        }
    }
}
