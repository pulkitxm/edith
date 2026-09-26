import Foundation
import UniformTypeIdentifiers

public enum StudioKind: String, CaseIterable, Codable, Hashable, Sendable {
    case image
    case pdf
    case video
    case audio
    case document
    case presentation
    case spreadsheet
    case archive
    case other

    public var title: String {
        switch self {
        case .image: "Image"
        case .pdf: "PDF"
        case .video: "Video"
        case .audio: "Audio"
        case .document: "Document"
        case .presentation: "Presentation"
        case .spreadsheet: "Spreadsheet"
        case .archive: "Archive"
        case .other: "File"
        }
    }

    public var pluralTitle: String {
        switch self {
        case .image: "Images"
        case .pdf: "PDFs"
        case .video: "Videos"
        case .audio: "Audio"
        case .document: "Documents"
        case .presentation: "Presentations"
        case .spreadsheet: "Spreadsheets"
        case .archive: "Archives"
        case .other: "Files"
        }
    }

    public var symbolName: String {
        switch self {
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .video: "film"
        case .audio: "waveform"
        case .document: "doc.text"
        case .presentation: "rectangle.on.rectangle.angled"
        case .spreadsheet: "tablecells"
        case .archive: "archivebox"
        case .other: "doc"
        }
    }

    public static let documentExtensions: Set<String> = [
        "doc", "docx", "rtf", "rtfd", "odt", "txt", "text", "md", "markdown", "html", "htm",
        "wordml", "pages",
    ]
    public static let presentationExtensions: Set<String> = ["ppt", "pptx", "key", "odp"]
    public static let spreadsheetExtensions: Set<String> = [
        "xls", "xlsx", "csv", "tsv", "numbers", "ods",
    ]
    public static let archiveExtensions: Set<String> = [
        "zip", "tar", "gz", "tgz", "bz2", "tbz", "tbz2", "xz", "txz", "7z", "rar", "cpio", "xar",
    ]
    public static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "3gp", "ts", "mts",
        "m2ts", "ogv",
    ]
    public static let audioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "aifc", "caf", "flac", "ogg", "oga", "opus",
        "wma", "alac", "amr",
    ]

    public static func of(_ url: URL) -> StudioKind {
        of(pathExtension: url.pathExtension)
    }

    public static func of(pathExtension raw: String) -> StudioKind {
        let ext = raw.lowercased()
        if ext == "pdf" { return .pdf }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if documentExtensions.contains(ext) { return .document }
        if presentationExtensions.contains(ext) { return .presentation }
        if spreadsheetExtensions.contains(ext) { return .spreadsheet }
        if archiveExtensions.contains(ext) { return .archive }
        guard let type = UTType(filenameExtension: ext) else { return .other }
        if type.conforms(to: .pdf) { return .pdf }
        if type.conforms(to: .image) { return .image }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) { return .archive }
        if type.conforms(to: .text) || type.conforms(to: .rtf) { return .document }
        return .other
    }
}

extension URL {
    public var studioKind: StudioKind { StudioKind.of(self) }

    public var studioStem: String { deletingPathExtension().lastPathComponent }
}
