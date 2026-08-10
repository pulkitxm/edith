import AppKit
import Foundation
import UniformTypeIdentifiers

public struct ClipboardCaptureOptions: Sendable {
    public let saveFiles: Bool
    public let saveImages: Bool
    public let saveText: Bool

    public init(saveFiles: Bool, saveImages: Bool, saveText: Bool) {
        self.saveFiles = saveFiles
        self.saveImages = saveImages
        self.saveText = saveText
    }
}

public struct ClipboardPayload: Sendable {
    public let data: Data
    public let types: [String]
    public let ext: String
    public let preview: String

    public init(data: Data, types: [String], ext: String, preview: String) {
        self.data = data
        self.types = types
        self.ext = ext
        self.preview = String(preview.prefix(500))
    }
}

public enum ClipboardPayloadExtractor {
    private static let maxPreviewCharacters = 500
    private static let maxSniffCharacters = 8_192
    private static let maxSniffBytes = 65_536

    private struct Format {
        let type: NSPasteboard.PasteboardType
        let ext: String
        let preview: String
    }

    private static let imageFormats = [
        Format(type: .png, ext: "png", preview: "PNG image"),
        Format(type: .tiff, ext: "tiff", preview: "TIFF image"),
        Format(type: .init("public.jpeg"), ext: "jpg", preview: "JPEG image"),
        Format(type: .init("com.compuserve.gif"), ext: "gif", preview: "GIF image"),
        Format(type: .init("public.heic"), ext: "heic", preview: "HEIC image"),
        Format(type: .init("public.heif"), ext: "heif", preview: "HEIF image"),
        Format(type: .init("org.webmproject.webp"), ext: "webp", preview: "WebP image"),
        Format(type: .init("public.svg-image"), ext: "svg", preview: "SVG image"),
        Format(type: .init("com.microsoft.bmp"), ext: "bmp", preview: "BMP image"),
        Format(type: .init("com.microsoft.ico"), ext: "ico", preview: "Icon image"),
        Format(type: .init("public.avif"), ext: "avif", preview: "AVIF image"),
    ]

    private static let richTextFormats = [
        Format(type: .rtf, ext: "rtf", preview: "Rich text"),
        Format(
            type: .init("com.apple.flat-rtfd"), ext: "rtfd", preview: "Rich text with attachments"),
        Format(type: .html, ext: "html", preview: "HTML"),
    ]

    private static let typedTextExtensions: [String: String] = [
        "public.json": "json",
        "public.xml": "xml",
        "public.comma-separated-values-text": "csv",
        "public.utf8-tab-separated-values-text": "tsv",
        "com.apple.property-list": "plist",
        "public.yaml": "yaml",
        "org.yaml.yaml": "yaml",
        "public.source-code": "txt",
        "public.shell-script": "sh",
        "public.python-script": "py",
        "public.ruby-script": "rb",
        "public.perl-script": "pl",
        "public.php-script": "php",
        "com.netscape.javascript-source": "js",
        "public.swift-source": "swift",
    ]

    @MainActor public static func extract(
        from pasteboard: NSPasteboard, options: ClipboardCaptureOptions
    ) -> ClipboardPayload? {
        if options.saveFiles, let files = filePayload(from: pasteboard) { return files }
        if options.saveImages, let image = imagePayload(from: pasteboard) { return image }
        if options.saveFiles, let document = pdfPayload(from: pasteboard) { return document }
        if options.saveText, let richText = richTextPayload(from: pasteboard) { return richText }
        if options.saveText, let text = typedTextPayload(from: pasteboard) { return text }
        if options.saveText, let text = standardTextPayload(from: pasteboard) { return text }
        if options.saveFiles, let webURL = webURLPayload(from: pasteboard) { return webURL }
        if options.saveFiles, let data = binaryPayload(from: pasteboard) { return data }
        return nil
    }

    private static func filePayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let objects =
            pasteboard.readObjects(
                forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        let urls = objects.compactMap { ($0 as? NSURL) as URL? }.filter(\.isFileURL)
        guard !urls.isEmpty else { return legacyFileListPayload(from: pasteboard) }
        if urls.count == 1, let url = urls.first {
            let value = url.absoluteString
            return ClipboardPayload(
                data: Data(value.utf8), types: [NSPasteboard.PasteboardType.fileURL.rawValue],
                ext: "url", preview: filePreview(for: url))
        }
        let values = urls.map(\.absoluteString)
        guard let data = try? JSONEncoder().encode(values) else { return nil }
        return ClipboardPayload(
            data: data, types: [NSPasteboard.PasteboardType.fileURL.rawValue], ext: "files",
            preview: fileListPreview(urls))
    }

    private static func legacyFileListPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let type = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        guard let value = pasteboard.propertyList(forType: type) as? [String], !value.isEmpty else {
            return nil
        }
        let urls = value.map { URL(fileURLWithPath: $0) }
        if urls.count == 1, let url = urls.first {
            return ClipboardPayload(
                data: Data(url.absoluteString.utf8), types: [type.rawValue], ext: "url",
                preview: filePreview(for: url))
        }
        guard let data = try? JSONEncoder().encode(urls.map(\.absoluteString)) else { return nil }
        return ClipboardPayload(
            data: data, types: [type.rawValue], ext: "files", preview: fileListPreview(urls))
    }

    private static func filePreview(for url: URL) -> String {
        let name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        {
            return name.isEmpty ? "Folder" : "\(name) · Folder"
        }
        if let content = initialFileText(url) {
            return "\(name.isEmpty ? url.path : name) · \(content)"
        }
        if let kind = kindDescription(for: url), isOpaqueName(name) {
            return kind
        }
        return name.isEmpty ? url.path : name
    }

    static func isOpaqueName(_ name: String) -> Bool {
        UUID(uuidString: (name as NSString).deletingPathExtension) != nil
    }

    static func kindDescription(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext),
            let description = type.localizedDescription
        else { return nil }
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    private static func initialFileText(_ url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        let name = url.lastPathComponent.lowercased()
        let textExtensions: Set<String> = [
            "astro", "bash", "c", "conf", "config", "cpp", "cs", "css", "csv", "env", "fish",
            "go", "gql", "graphql", "h", "hpp", "html", "ini", "java", "js", "json", "jsonl",
            "jsx", "kt", "kts", "less", "log", "md", "markdown", "ndjson", "php", "pl", "plist",
            "proto", "py", "rb", "rs", "sass", "scss", "sh", "sql", "svelte", "swift", "toml",
            "ts", "tsv", "tsx", "txt", "vue", "xml", "yaml", "yml", "zsh",
        ]
        let namedTextFiles: Set<String> = [
            ".editorconfig", ".env", ".gitattributes", ".gitignore", ".npmrc", ".prettierrc",
            "dockerfile", "gemfile", "makefile", "procfile",
        ]
        let type = ext.isEmpty ? nil : UTType(filenameExtension: ext)
        guard
            textExtensions.contains(ext) || namedTextFiles.contains(name)
                || type?.conforms(to: .text) == true
        else { return nil }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSniffBytes), !data.isEmpty,
            let text = decodeText(data, permissive: true), hasRenderableText(text)
        else { return nil }
        return String(preview(for: text, fallback: "Text file").prefix(320))
    }

    private static func fileListPreview(_ urls: [URL]) -> String {
        let names = urls.prefix(3).map { filePreview(for: $0) }
        let remainder = urls.count - names.count
        let suffix = remainder > 0 ? ", +\(remainder) more" : ""
        return "\(urls.count) items · \(names.joined(separator: ", "))\(suffix)"
    }

    private static func imagePayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        for format in imageFormats {
            if let data = pasteboard.data(forType: format.type), !data.isEmpty {
                return ClipboardPayload(
                    data: data, types: [format.type.rawValue], ext: format.ext,
                    preview: format.preview)
            }
        }
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard let uniformType = UTType(type.rawValue), uniformType.conforms(to: .image),
                    let data = item.data(forType: type), !data.isEmpty
                else { continue }
                let ext = safeExtension(uniformType.preferredFilenameExtension) ?? "image"
                let name = uniformType.localizedDescription ?? "Image"
                return ClipboardPayload(
                    data: data, types: [type.rawValue], ext: ext, preview: name)
            }
        }
        return nil
    }

    private static func pdfPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let formats = [
            Format(type: .pdf, ext: "pdf", preview: "PDF document"),
            Format(type: .init("com.adobe.postscript"), ext: "ps", preview: "PostScript document"),
        ]
        for format in formats {
            if let data = pasteboard.data(forType: format.type), !data.isEmpty {
                return ClipboardPayload(
                    data: data, types: [format.type.rawValue], ext: format.ext,
                    preview: format.preview)
            }
        }
        return nil
    }

    private static func richTextPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let directText = pasteboard.string(forType: .string)
        for format in richTextFormats {
            guard let data = pasteboard.data(forType: format.type) else { continue }
            let decoded: String?
            if hasRenderableText(directText) {
                decoded = directText
            } else {
                switch format.ext {
                case "rtf":
                    decoded = NSAttributedString(rtf: data, documentAttributes: nil)?.string
                case "rtfd":
                    decoded = NSAttributedString(rtfd: data, documentAttributes: nil)?.string
                default:
                    decoded = NSAttributedString(html: data, documentAttributes: nil)?.string
                }
            }
            let bestText = hasRenderableText(decoded) ? decoded : directText
            return ClipboardPayload(
                data: data, types: [format.type.rawValue], ext: format.ext,
                preview: preview(for: bestText, fallback: format.preview))
        }
        return nil
    }

    private static func standardTextPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        return ClipboardPayload(
            data: Data(text.utf8), types: [NSPasteboard.PasteboardType.string.rawValue],
            ext: inferredTextExtension(text), preview: preview(for: text, fallback: "Text"))
    }

    private static func typedTextPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard !reservedTypes.contains(type.rawValue), let data = item.data(forType: type)
                else { continue }
                let uniformType = UTType(type.rawValue)
                let declaredText = uniformType?.conforms(to: .text) == true
                let mappedText = typedTextExtensions[type.rawValue] != nil
                if uniformType?.conforms(to: .image) == true
                    || type.rawValue == NSPasteboard.PasteboardType.pdf.rawValue
                    || type.rawValue == "com.adobe.postscript"
                {
                    continue
                }
                guard let text = decodeText(data, permissive: declaredText || mappedText) else {
                    continue
                }
                let ext =
                    typedTextExtensions[type.rawValue]
                    ?? safeExtension(uniformType?.preferredFilenameExtension)
                    ?? inferredTextExtension(text)
                return ClipboardPayload(
                    data: data, types: [type.rawValue], ext: ext,
                    preview: preview(
                        for: text, fallback: uniformType?.localizedDescription ?? "Text"))
            }
        }
        return nil
    }

    private static func webURLPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let type = NSPasteboard.PasteboardType.URL
        guard let value = pasteboard.string(forType: type), let url = URL(string: value),
            !url.isFileURL
        else { return nil }
        return ClipboardPayload(
            data: Data(value.utf8), types: [type.rawValue], ext: "weburl", preview: value)
    }

    private static func binaryPayload(from pasteboard: NSPasteboard) -> ClipboardPayload? {
        let colorType = NSPasteboard.PasteboardType.color
        if let data = pasteboard.data(forType: colorType), !data.isEmpty {
            return ClipboardPayload(
                data: data, types: [colorType.rawValue], ext: "color", preview: "Color")
        }
        for item in pasteboard.pasteboardItems ?? [] {
            for type in item.types {
                guard !reservedTypes.contains(type.rawValue),
                    let data = item.data(forType: type), !data.isEmpty
                else { continue }
                let uniformType = UTType(type.rawValue)
                if uniformType?.conforms(to: .text) == true
                    || uniformType?.conforms(to: .image) == true
                {
                    continue
                }
                if decodeText(data, permissive: false) != nil { continue }
                let ext = safeExtension(uniformType?.preferredFilenameExtension) ?? "data"
                let description =
                    uniformType?.localizedDescription ?? binaryDescription(type.rawValue)
                return ClipboardPayload(
                    data: data, types: [type.rawValue], ext: ext,
                    preview: "\(description) · \(byteCount(data.count))")
            }
        }
        return nil
    }

    private static let reservedTypes: Set<String> = [
        NSPasteboard.PasteboardType.fileURL.rawValue,
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType.rtf.rawValue,
        NSPasteboard.PasteboardType.html.rawValue,
        ClipboardPasteboardFilter.edithOwnTag,
        ClipboardPasteboardFilter.concealedType,
        ClipboardPasteboardFilter.transientType,
        ClipboardPasteboardFilter.autoGeneratedType,
    ]

    private static func preview(for text: String?, fallback: String) -> String {
        guard let text else { return fallback }
        guard !text.isEmpty else { return "Empty text" }
        let initial = text.prefix(maxPreviewCharacters)
        if hasRenderableText(String(initial)) { return String(initial) }
        let whitespaceOnly = initial.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
        return whitespaceOnly
            ? "Whitespace text"
            : "Control characters"
    }

    private static func hasRenderableText(_ text: String?) -> Bool {
        guard let text else { return false }
        return text.prefix(maxPreviewCharacters).unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.controlCharacters.contains($0)
        }
    }

    private static func decodeText(_ data: Data, permissive: Bool) -> String? {
        let sample = Data(data.prefix(maxSniffBytes))
        let initialBytes = Array(sample.prefix(256))
        let evenNulls = initialBytes.enumerated().filter {
            $0.offset.isMultiple(of: 2) && $0.element == 0
        }.count
        let oddNulls = initialBytes.enumerated().filter {
            !$0.offset.isMultiple(of: 2) && $0.element == 0
        }.count
        let encodings: [String.Encoding]
        if sample.starts(with: [0xFF, 0xFE]) || sample.starts(with: [0xFE, 0xFF]) {
            encodings = [.utf16, .utf16LittleEndian, .utf16BigEndian, .utf8]
        } else if oddNulls > evenNulls && oddNulls > 4 {
            encodings = [.utf16LittleEndian, .utf16BigEndian, .utf8]
        } else if evenNulls > oddNulls && evenNulls > 4 {
            encodings = [.utf16BigEndian, .utf16LittleEndian, .utf8]
        } else {
            encodings = [.utf8, .utf16, .utf16LittleEndian, .utf16BigEndian]
        }
        for encoding in encodings {
            if let text = String(data: sample, encoding: encoding), textLooksReadable(text) {
                return text
            }
        }
        guard permissive else { return nil }
        guard let text = String(data: sample, encoding: .isoLatin1), textLooksReadable(text) else {
            return nil
        }
        return text
    }

    private static func textLooksReadable(_ text: String) -> Bool {
        guard !text.isEmpty else { return true }
        let scalars = text.unicodeScalars
        let disallowed = scalars.filter {
            CharacterSet.controlCharacters.contains($0)
                && !CharacterSet.whitespacesAndNewlines.contains($0)
        }.count
        return Double(disallowed) / Double(scalars.count) < 0.02
    }

    private static func inferredTextExtension(_ text: String) -> String {
        let sample = String(text.prefix(maxSniffCharacters))
        let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
            (trimmed.hasPrefix("{") || trimmed.hasPrefix("[")),
            (try? JSONSerialization.jsonObject(with: data)) != nil
        {
            return "json"
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype") || lower.hasPrefix("<plist") {
            return lower.hasPrefix("<plist") ? "plist" : "xml"
        }
        if trimmed.hasPrefix("#!") { return "sh" }
        if lower.range(
            of: #"^(select|insert|update|delete|create|alter|drop)\s+"#, options: .regularExpression
        ) != nil {
            return "sql"
        }
        if trimmed.contains("\t"), hasDelimitedRows(trimmed, separator: "\t") { return "tsv" }
        if trimmed.contains(","), hasDelimitedRows(trimmed, separator: ",") { return "csv" }
        return "txt"
    }

    private static func hasDelimitedRows(_ text: String, separator: Character) -> Bool {
        let rows = text.split(whereSeparator: \.isNewline).prefix(5)
        guard rows.count >= 2 else { return false }
        let counts = rows.map { $0.filter { $0 == separator }.count }
        return counts.first.map { $0 > 0 && counts.allSatisfy { $0 == counts.first } } ?? false
    }

    private static func safeExtension(_ value: String?) -> String? {
        guard let value else { return nil }
        let safe = value.lowercased().filter { $0.isLetter || $0.isNumber }
        return safe.isEmpty ? nil : String(safe.prefix(12))
    }

    private static func binaryDescription(_ identifier: String) -> String {
        if identifier.hasPrefix("dyn.") { return "App data" }
        let tail = identifier.split(separator: ".").last.map(String.init) ?? identifier
        let words = tail.replacingOccurrences(of: "-", with: " ")
        return words.isEmpty ? "Clipboard data" : words.capitalized
    }

    private static func byteCount(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }
}
