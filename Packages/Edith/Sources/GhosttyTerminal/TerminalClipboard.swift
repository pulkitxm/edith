import AppKit
import Foundation
import GhosttyKit
import UniformTypeIdentifiers

struct TerminalClipboardEntry: Equatable {
    let mime: String
    let data: Data

    init(mime: String, data: Data) {
        self.mime = mime
        self.data = data
    }

    init?(_ content: ghostty_clipboard_content_s) {
        guard let mime = content.mime, let bytes = content.data else { return nil }
        self.mime = String(cString: mime)
        data = Data(bytes: bytes, count: content.len)
    }

    var pasteboardType: NSPasteboard.PasteboardType {
        switch baseMIMEType {
        case "text/plain": return .string
        case "text/html": return .html
        case "text/rtf", "application/rtf": return .rtf
        default:
            if let type = UTType(mimeType: baseMIMEType) {
                return NSPasteboard.PasteboardType(type.identifier)
            }
            return NSPasteboard.PasteboardType(mime)
        }
    }

    var baseMIMEType: String {
        mime.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? mime
    }
}

struct TerminalClipboardRead: Equatable {
    let entries: [TerminalClipboardEntry]
    let availableMIMEs: [String]
}

enum TerminalClipboard {
    static func entries(
        from content: UnsafePointer<ghostty_clipboard_content_s>?, count: Int
    ) -> [TerminalClipboardEntry] {
        guard let content, count > 0 else { return [] }
        return (0..<count).compactMap { TerminalClipboardEntry(content[$0]) }
    }

    static func write(_ entries: [TerminalClipboardEntry], to pasteboard: NSPasteboard) {
        var unique: [NSPasteboard.PasteboardType: TerminalClipboardEntry] = [:]
        var orderedTypes: [NSPasteboard.PasteboardType] = []
        for entry in entries {
            let type = entry.pasteboardType
            if unique[type] == nil { orderedTypes.append(type) }
            unique[type] = entry
        }
        guard !orderedTypes.isEmpty else { return }
        pasteboard.declareTypes(orderedTypes, owner: nil)
        for type in orderedTypes {
            guard let entry = unique[type] else { continue }
            if type == .string, let value = String(data: entry.data, encoding: .utf8) {
                pasteboard.setString(value, forType: type)
            } else {
                pasteboard.setData(entry.data, forType: type)
            }
        }
    }

    static func read(
        requestedMIMEs: [String], listAvailable: Bool, from pasteboard: NSPasteboard
    ) -> TerminalClipboardRead? {
        var seen = Set<String>()
        let entries = requestedMIMEs.compactMap { mime -> TerminalClipboardEntry? in
            guard seen.insert(mime).inserted, let data = data(for: mime, from: pasteboard) else {
                return nil
            }
            return TerminalClipboardEntry(mime: mime, data: data)
        }
        let available = listAvailable ? availableMIMEs(from: pasteboard) : []
        guard !entries.isEmpty || listAvailable else { return nil }
        return TerminalClipboardRead(entries: entries, availableMIMEs: available)
    }

    static func complete(
        _ request: TerminalClipboardRead, surface: ghostty_surface_t,
        state: UnsafeMutableRawPointer?, confirmed: Bool = false, remember: Bool = false
    ) {
        var strings: [UnsafeMutablePointer<CChar>] = []
        var buffers: [UnsafeMutableRawPointer] = []
        defer {
            strings.forEach { free($0) }
            buffers.forEach { $0.deallocate() }
        }

        var contents: [ghostty_clipboard_content_s] = []
        for entry in request.entries {
            guard let mime = strdup(entry.mime) else { continue }
            strings.append(mime)
            let buffer = UnsafeMutableRawPointer.allocate(
                byteCount: max(entry.data.count, 1), alignment: 1)
            buffers.append(buffer)
            entry.data.withUnsafeBytes { source in
                guard let baseAddress = source.baseAddress else { return }
                buffer.copyMemory(from: baseAddress, byteCount: source.count)
            }
            contents.append(
                ghostty_clipboard_content_s(
                    mime: mime, data: buffer.assumingMemoryBound(to: CChar.self),
                    len: entry.data.count))
        }

        let available: [UnsafePointer<CChar>?] = request.availableMIMEs.compactMap { mime in
            guard let value = strdup(mime) else { return nil }
            strings.append(value)
            return UnsafePointer(value)
        }
        contents.withUnsafeBufferPointer { contentBuffer in
            available.withUnsafeBufferPointer { availableBuffer in
                var result = ghostty_clipboard_complete_s(
                    contents: contentBuffer.baseAddress,
                    contents_len: contentBuffer.count,
                    available: availableBuffer.baseAddress,
                    available_len: availableBuffer.count,
                    confirmed: confirmed,
                    remember: remember)
                ghostty_surface_complete_clipboard_request(surface, &result, state)
            }
        }
    }

    private static func data(for mime: String, from pasteboard: NSPasteboard) -> Data? {
        let base = mime.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased()
        switch base {
        case "text/plain":
            if let files = fileURLs(from: pasteboard), !files.isEmpty {
                return Data(
                    files.map { GhosttyTerminalView.quote($0.path) }.joined(separator: " ").utf8)
            }
            return pasteboard.string(forType: .string).map { Data($0.utf8) }
        case "text/uri-list":
            guard let files = fileURLs(from: pasteboard), !files.isEmpty else { return nil }
            return Data(files.map { "\($0.absoluteString)\r\n" }.joined().utf8)
        default:
            return pasteboard.data(
                forType: TerminalClipboardEntry(mime: mime, data: Data()).pasteboardType)
        }
    }

    private static func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    }

    private static func availableMIMEs(from pasteboard: NSPasteboard) -> [String] {
        let types = pasteboard.types ?? []
        var result: [String] = []
        var seen = Set<String>()
        let hasFiles = types.contains(.fileURL)
        let mapped = types.compactMap { type -> String? in
            guard let mime = UTType(type.rawValue)?.preferredMIMEType else { return nil }
            return mime.hasPrefix("text/plain") ? "text/plain" : mime
        }
        if hasFiles || mapped.contains("text/plain") {
            result.append("text/plain")
            seen.insert("text/plain")
        }
        if hasFiles {
            result.append("text/uri-list")
            seen.insert("text/uri-list")
        }
        for mime in mapped where seen.insert(mime).inserted {
            result.append(mime)
        }
        return result
    }
}
