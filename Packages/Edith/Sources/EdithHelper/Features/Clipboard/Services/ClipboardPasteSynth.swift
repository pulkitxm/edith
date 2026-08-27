import AppKit
import CoreGraphics
import EdithKit

enum ClipboardPasteSynth {
    private static let vKeyCode: CGKeyCode = 9
    private static let deleteKeyCode: CGKeyCode = 51

    static func synthesizeCommandV() {
        guard let source = CGEventSource(stateID: .hidSystemState) else { return }
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    static func synthesizeDeletes(_ count: Int) {
        guard count > 0, let source = CGEventSource(stateID: .hidSystemState) else { return }
        for _ in 0..<count {
            CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: true)?
                .post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: deleteKeyCode, keyDown: false)?
                .post(tap: .cgSessionEventTap)
        }
    }

    static func pasteTemporarily(_ text: String, restoreAfter delay: TimeInterval = 0.2) {
        let pasteboard = NSPasteboard.general
        let snapshot = ClipboardPasteboardSnapshot(pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(
            Data(), forType: .init(ClipboardPasteboardFilter.edithOwnTag))
        let transientChangeCount = pasteboard.changeCount
        synthesizeCommandV()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pasteboard.changeCount == transientChangeCount else { return }
            snapshot.restore(to: pasteboard)
        }
    }
}

struct ClipboardPasteboardSnapshot {
    struct Item {
        let values: [(NSPasteboard.PasteboardType, Data)]
    }

    let items: [Item]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            Item(
                values: item.types.compactMap { type in
                    item.data(forType: type).map { (type, $0) }
                })
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored.values { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
