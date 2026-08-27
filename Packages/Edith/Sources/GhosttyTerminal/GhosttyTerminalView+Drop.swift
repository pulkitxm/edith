import AppKit
import GhosttyKit

public struct TerminalDropPayload: Sendable {
    public let files: [URL]
    public let temporaryFiles: Set<URL>

    public static let pasteboardTypes: [NSPasteboard.PasteboardType] = [
        .fileURL, .string, .png, .tiff, .init("public.jpeg"), .init("com.compuserve.gif"),
        .init("public.heic"),
    ]

    public static func files(from pasteboard: NSPasteboard) -> TerminalDropPayload? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            return TerminalDropPayload(files: urls, temporaryFiles: [])
        }
        guard let image = NSImage(pasteboard: pasteboard),
            let data = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data),
            let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EdithTerminalDrops", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent(
                "image-\(UUID().uuidString.lowercased()).png")
            try png.write(to: url, options: .atomic)
            return TerminalDropPayload(files: [url], temporaryFiles: [url])
        } catch {
            return nil
        }
    }

    public func removeTemporaryFiles() {
        for url in temporaryFiles { try? FileManager.default.removeItem(at: url) }
    }
}

extension GhosttyTerminalView {
    static let dropTypes = Set(TerminalDropPayload.pasteboardTypes)

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        guard !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        window?.makeFirstResponder(self)
        if let payload = TerminalDropPayload.files(from: sender.draggingPasteboard) {
            if onDropFiles?(payload) == true { return true }
            return insertText(payload.files.map { Self.quote($0.path) }.joined(separator: " "))
        }
        guard let content = Self.dropped(from: sender.draggingPasteboard) else { return false }
        return insertText(content)
    }

    static func dropped(from pasteboard: NSPasteboard) -> String? {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty {
            let paths = urls.map { quote($0.isFileURL ? $0.path : $0.absoluteString) }
            return paths.joined(separator: " ")
        }
        guard let text = pasteboard.string(forType: .string), !text.isEmpty else { return nil }
        return text
    }

    static func quote(_ path: String) -> String {
        guard path.contains(where: { !$0.isLetter && !$0.isNumber && !"/._-".contains($0) })
        else {
            return path
        }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
