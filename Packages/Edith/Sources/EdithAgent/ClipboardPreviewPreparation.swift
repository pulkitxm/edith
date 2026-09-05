import AppKit
import Darwin
import EdithKit
import Foundation
import UniformTypeIdentifiers

public enum ClipboardPreviewPreparation {
    private static let maxSniffBytes = 65_536

    public static func prepare(_ capture: ClipboardCapture) throws -> ClipboardCapture {
        try Task.checkCancellation()
        let value: String?
        switch capture.ext {
        case "url":
            if let text = String(data: capture.data, encoding: .utf8),
                let url = URL(string: text), url.isFileURL
            {
                value = filePreview(for: url)
            } else {
                value = nil
            }
        case "files":
            let values = try JSONDecoder().decode([String].self, from: capture.data)
            guard values.count <= 4096 else {
                throw AgentError(.refused, "The clipboard file list is too large.")
            }
            value = fileListPreview(values.compactMap(URL.init(string:)).filter(\.isFileURL))
        case "rtf", "rtfd", "html":
            if let text = richText(capture.data, ext: capture.ext),
                ClipboardPayloadExtractor.hasRenderableText(text)
            {
                value = ClipboardPayloadExtractor.preview(for: text, fallback: capture.preview)
            } else {
                value = nil
            }
        default: value = nil
        }
        try Task.checkCancellation()
        guard let value else { return capture }
        return ClipboardCapture(
            payload: ClipboardPayload(
                data: capture.data, types: capture.types, ext: capture.ext, preview: value),
            sourceApp: capture.sourceApp, sourceBundleID: capture.sourceBundleID,
            id: capture.id, capturedAt: capture.capturedAt)
    }

    public static func copy(_ payload: ClipboardStoredPayload, plainTextOnly: Bool) throws
        -> ClipboardCopyPayload
    {
        try Task.checkCancellation()
        let entry = payload.entry
        var text: String?
        var urls: [URL]?
        switch entry.ext {
        case "rtf", "rtfd", "html":
            guard payload.data.count <= 1 << 20 || !plainTextOnly else {
                throw AgentError(
                    .refused, "Rich text larger than one megabyte must be copied with formatting.")
            }
            text = richText(payload.data, ext: entry.ext)
        case "url", "weburl":
            guard let value = String(data: payload.data, encoding: .utf8),
                let url = URL(string: value)
            else {
                throw AgentError(.failed, "The clipboard URL is invalid.")
            }
            urls = [url]
            if entry.ext == "weburl" { text = value }
        case "files":
            let values = try JSONDecoder().decode([String].self, from: payload.data)
            guard values.count <= 4096 else {
                throw AgentError(.refused, "The clipboard file list is too large.")
            }
            urls = try values.map { value in
                guard let url = URL(string: value), url.isFileURL else {
                    throw AgentError(.failed, "A clipboard file URL is invalid.")
                }
                return url
            }
        default:
            if entry.isTextual {
                text =
                    String(data: payload.data, encoding: .utf8)
                    ?? String(data: payload.data, encoding: .utf16)
            }
        }
        let onlyText = plainTextOnly && entry.isTextual
        try Task.checkCancellation()
        return ClipboardCopyPayload(
            entry: entry, data: onlyText || urls != nil ? Data() : payload.data,
            text: text,
            urls: urls, plainTextOnly: onlyText)
    }

    private static func richText(_ data: Data, ext: String) -> String? {
        guard data.count <= 1 << 20 else { return nil }
        switch ext {
        case "rtf": return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        case "rtfd": return NSAttributedString(rtfd: data, documentAttributes: nil)?.string
        default:
            guard
                let document = try? XMLDocument(
                    data: data, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever])
            else { return nil }
            for node in (try? document.nodes(forXPath: "//script|//style|//head")) ?? [] {
                node.detach()
            }
            return document.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func filePreview(for url: URL) -> String {
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
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            return nil
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxSniffBytes), !data.isEmpty,
            let text = ClipboardPayloadExtractor.decodeText(data, permissive: true),
            ClipboardPayloadExtractor.hasRenderableText(text)
        else { return nil }
        return String(
            ClipboardPayloadExtractor.preview(for: text, fallback: "Text file").prefix(320))
    }

    static func fileListPreview(_ urls: [URL]) -> String {
        let names = urls.prefix(3).map { filePreview(for: $0) }
        let remainder = urls.count - names.count
        let suffix = remainder > 0 ? ", +\(remainder) more" : ""
        return "\(urls.count) items · \(names.joined(separator: ", "))\(suffix)"
    }
}
