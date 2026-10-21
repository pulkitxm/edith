import AppKit

@MainActor
public enum MusicKeyCommand {
    public struct Handlers {
        public var playPause: () -> Void
        public var seekBy: (TimeInterval) -> Void
        public var volumeBy: (Double) -> Void

        public init(
            playPause: @escaping () -> Void,
            seekBy: @escaping (TimeInterval) -> Void,
            volumeBy: @escaping (Double) -> Void
        ) {
            self.playPause = playPause
            self.seekBy = seekBy
            self.volumeBy = volumeBy
        }
    }

    public static let seekStep: TimeInterval = 5
    public static let volumeStep: Double = 0.05

    public static func handle(
        keyCode: UInt16, modifiers: NSEvent.ModifierFlags, active: Bool,
        responder: NSResponder? = NSApp.keyWindow?.firstResponder, _ handlers: Handlers
    ) -> Bool {
        guard active, !isReceivingTextInput(responder),
            !usesKey(keyCode, responder: responder)
        else { return false }
        guard modifiers.intersection([.command, .option, .control]).isEmpty else {
            return false
        }
        switch keyCode {
        case 49: handlers.playPause()
        case 123: handlers.seekBy(-seekStep)
        case 124: handlers.seekBy(seekStep)
        case 125: handlers.volumeBy(-volumeStep)
        case 126: handlers.volumeBy(volumeStep)
        default: return false
        }
        return true
    }

    static func usesKey(_ keyCode: UInt16, responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if responder is NSTableView || responder is NSBrowser || responder is NSCollectionView {
            return (123...126).contains(keyCode)
        }
        return responder is NSControl
    }

    static func isReceivingTextInput(_ responder: NSResponder?) -> Bool {
        guard let responder else { return false }
        if InputFocus.takesKeysDirectly(responder) { return true }
        if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable }
        return responder is NSTextField
    }
}
