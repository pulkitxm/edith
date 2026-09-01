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

    private var baseMIMEType: String {
        mime.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? mime
    }
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
}
