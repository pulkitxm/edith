import AppKit
import CryptoKit
import Foundation

public enum ClipboardRepository {
    public static func withIndexLock<T>(_ body: () throws -> T) rethrows -> T {
        try? FileManager.default.createDirectory(
            at: ClipboardPaths.dir, withIntermediateDirectories: true)
        let descriptor = open(ClipboardPaths.lockFile.path, O_RDONLY | O_CREAT, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else { return try body() }
        defer { _ = flock(descriptor, LOCK_UN) }
        return try body()
    }

    public static func blobBytesOnDisk() -> Int {
        let fm = FileManager.default
        guard
            let files = try? fm.contentsOfDirectory(
                at: ClipboardPaths.blobsDir, includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        return files.reduce(0) { total, file in
            total + ((try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        }
    }

    public static func loadEntries() -> [ClipboardEntry] {
        guard let data = try? Data(contentsOf: ClipboardPaths.indexFile),
            let text = String(data: data, encoding: .utf8)
        else { return [] }
        return ClipboardIndex.decode(text)
    }

    public static func saveEntries(_ entries: [ClipboardEntry]) throws {
        try FileManager.default.createDirectory(
            at: ClipboardPaths.dir, withIntermediateDirectories: true)
        let text = ClipboardIndex.encode(entries)
        try Data(text.utf8).write(to: ClipboardPaths.indexFile, options: .atomic)
    }

    @discardableResult
    public static func appendEntry(_ entry: ClipboardEntry) -> Bool {
        guard FileManager.default.fileExists(atPath: ClipboardPaths.indexFile.path),
            let line = ClipboardIndex.encodeLine(entry),
            let handle = try? FileHandle(forWritingTo: ClipboardPaths.indexFile)
        else { return false }
        defer { try? handle.close() }
        guard (try? handle.seekToEnd()) != nil,
            (try? handle.write(contentsOf: Data(line.utf8))) != nil
        else { return false }
        return true
    }

    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func writeBlob(_ data: Data, sha256: String, ext: String) throws {
        try FileManager.default.createDirectory(
            at: ClipboardPaths.blobsDir, withIntermediateDirectories: true)
        let url = ClipboardPaths.blobFile(sha256: sha256, ext: ext)
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        try data.write(to: url)
    }

    public static func blobData(for entry: ClipboardEntry) -> Data? {
        try? Data(contentsOf: ClipboardPaths.blobFile(sha256: entry.sha256, ext: entry.ext))
    }

    public static func pruneEntriesMissingBlobs() {
        let entries = loadEntries()
        let kept = entries.filter {
            FileManager.default.fileExists(
                atPath: ClipboardPaths.blobFile(sha256: $0.sha256, ext: $0.ext).path)
        }
        guard kept.count != entries.count else { return }
        try? saveEntries(kept)
    }

    public static func pruneOrphanBlobs(keeping entries: [ClipboardEntry]) {
        let referenced = Set(entries.map { "\($0.sha256).\($0.ext)" })
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: ClipboardPaths.blobsDir.path)
        else { return }
        for file in files where !referenced.contains(file) {
            try? fm.removeItem(at: ClipboardPaths.blobsDir.appendingPathComponent(file))
        }
    }

    public static func plainText(for entry: ClipboardEntry, data: Data) -> String? {
        switch entry.ext {
        case "rtf": return NSAttributedString(rtf: data, documentAttributes: nil)?.string
        case "rtfd": return NSAttributedString(rtfd: data, documentAttributes: nil)?.string
        case "html": return NSAttributedString(html: data, documentAttributes: nil)?.string
        case "url", "files", "png", "tiff", "jpg", "jpeg", "gif", "heic", "heif", "webp",
            "svg", "bmp", "ico", "avif", "image", "pdf", "ps", "eps", "mp3", "m4a",
            "wav", "aiff", "flac", "ogg", "mp4", "mov", "m4v", "avi", "webm", "zip",
            "gz", "bz2", "xz", "tar", "7z", "rar", "data", "color":
            return nil
        default:
            guard ClipboardTextKinds.isText(entry.ext) else { return nil }
            return String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .utf16)
        }
    }

    @discardableResult
    public static func copyToPasteboard(
        _ entry: ClipboardEntry, asPlainText: Bool, pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let data = blobData(for: entry) else { return false }
        pasteboard.clearContents()
        if asPlainText, entry.isTextual {
            let text = plainText(for: entry, data: data) ?? entry.preview ?? ""
            pasteboard.setString(text, forType: .string)
        } else {
            write(data: data, entry: entry, to: pasteboard)
        }
        pasteboard.setData(
            Data(), forType: NSPasteboard.PasteboardType(ClipboardPasteboardFilter.edithOwnTag))
        return true
    }

    private static func write(data: Data, entry: ClipboardEntry, to pasteboard: NSPasteboard) {
        switch entry.ext {
        case "png":
            pasteboard.setData(data, forType: .png)
        case "tiff":
            pasteboard.setData(data, forType: .tiff)
        case "jpg", "jpeg", "gif", "heic", "heif", "webp", "svg", "bmp", "ico", "avif",
            "image", "pdf", "ps", "eps", "mp3", "m4a", "wav", "aiff", "flac", "ogg",
            "mp4", "mov", "m4v", "avi", "webm", "zip", "gz", "bz2", "xz", "tar", "7z",
            "rar", "data", "color":
            let type =
                entry.types.first.map { NSPasteboard.PasteboardType($0) }
                ?? NSPasteboard.PasteboardType("public.data")
            pasteboard.setData(data, forType: type)
        case "rtf":
            pasteboard.setData(data, forType: .rtf)
            if let text = plainText(for: entry, data: data) {
                pasteboard.setString(text, forType: .string)
            }
        case "rtfd":
            let type =
                entry.types.first.map { NSPasteboard.PasteboardType($0) }
                ?? NSPasteboard.PasteboardType("com.apple.flat-rtfd")
            pasteboard.setData(data, forType: type)
            if let text = plainText(for: entry, data: data) {
                pasteboard.setString(text, forType: .string)
            }
        case "html":
            pasteboard.setData(data, forType: .html)
            if let text = plainText(for: entry, data: data) {
                pasteboard.setString(text, forType: .string)
            }
        case "url":
            if let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                pasteboard.writeObjects([url as NSURL])
            }
        case "files":
            if let strings = try? JSONDecoder().decode([String].self, from: data) {
                pasteboard.writeObjects(strings.compactMap(URL.init(string:)).map { $0 as NSURL })
            }
        case "weburl":
            if let string = String(data: data, encoding: .utf8), let url = URL(string: string) {
                pasteboard.writeObjects([url as NSURL])
                pasteboard.setString(string, forType: .string)
            }
        default:
            if let rawType = entry.types.first {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(rawType))
            }
            if let string = String(data: data, encoding: .utf8) {
                pasteboard.setString(string, forType: .string)
            }
        }
    }
}
