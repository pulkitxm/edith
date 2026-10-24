import EdithExtensionSupport
import EdithExtensionUI
import AppKit

@MainActor
public enum EmbeddedMusicKeyCommand {
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
        responder: NSResponder? = NSApp?.keyWindow?.firstResponder, _ handlers: Handlers
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
        if responder is DirectKeyboardInputResponder { return true }
        if let text = responder as? NSTextView { return text.isFieldEditor || text.isEditable }
        return responder is NSTextField
    }
}

@MainActor
enum EmbeddedMusicKeyMonitor {
    private static var monitor: Any?
    private static var holders = 0

    static var isInstalled: Bool { monitor != nil }

    static func acquire() {
        holders += 1
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let handled = MainActor.assumeIsolated {
                guard !videoClaims(event) else { return false }
                return dispatch(keyCode: event.keyCode, modifiers: event.modifierFlags)
            }
            return handled ? nil : event
        }
    }

    static func release() {
        holders = max(0, holders - 1)
        guard holders == 0, let monitor else { return }
        NSEvent.removeMonitor(monitor)
        self.monitor = nil
    }

    static func dispatch(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let accounts = EmbeddedMusicAccounts.shared
        switch accounts.selected {
        case .local:
            let remote = EmbeddedMusicRemote.shared
            return EmbeddedMusicKeyCommand.handle(
                keyCode: keyCode, modifiers: modifiers, active: remote.current != nil,
                .init(
                    playPause: { remote.playPause() },
                    seekBy: { remote.nudgeSeek($0) },
                    volumeBy: { remote.nudgeVolume($0) }))
        case .spotify:
            let spotify = accounts.spotify
            return EmbeddedMusicKeyCommand.handle(
                keyCode: keyCode, modifiers: modifiers, active: spotify.connected,
                .init(
                    playPause: { spotify.send(["action": "toggle"]) },
                    seekBy: { spotify.seek(by: $0) },
                    volumeBy: { spotify.setVolume(spotify.volume + $0) }))
        default:
            return false
        }
    }

    private static func videoClaims(_ event: NSEvent) -> Bool {
        guard event.keyCode == 49, let view = event.window?.contentView else { return false }
        return containsVideoKeyView(view)
    }

    private static func containsVideoKeyView(_ view: NSView) -> Bool {
        String(describing: type(of: view)) == "VideoPlaybackKeyView"
            || view.subviews.contains(where: containsVideoKeyView)
    }
}
