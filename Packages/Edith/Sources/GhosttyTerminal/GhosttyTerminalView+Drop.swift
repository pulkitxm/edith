import AppKit
import GhosttyKit

extension GhosttyTerminalView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [.string, .fileURL]

    public override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }
        guard !Set(types).isDisjoint(with: Self.dropTypes) else { return [] }
        return .copy
    }

    public override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    public override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let surface else { return false }
        guard let content = Self.dropped(from: sender.draggingPasteboard) else { return false }
        window?.makeFirstResponder(self)
        content.withCString { ghostty_surface_text(surface, $0, UInt(strlen($0))) }
        return true
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
