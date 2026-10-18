import AppKit
import SwiftUI

final class VideoPlaybackKeyView: NSView {
    private static let claimedWindows = NSHashTable<NSWindow>.weakObjects()

    var onToggle: () -> Void = {}
    private var monitor: Any?

    static func claims(_ event: NSEvent) -> Bool {
        guard let window = event.window, claimedWindows.contains(window) else { return false }
        return isPlaybackToggle(event, in: window)
    }

    static func isPlaybackToggle(_ event: NSEvent, in window: NSWindow) -> Bool {
        event.type == .keyDown && event.keyCode == 49
            && event.modifierFlags.intersection([.command, .option, .control]).isEmpty
            && window.attachedSheet == nil && !(window.firstResponder is NSText)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let window { Self.claimedWindows.remove(window) }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        Self.claimedWindows.add(window)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let window = self.window, event.window === window,
                    Self.isPlaybackToggle(event, in: window)
                else { return false }
                if !event.isARepeat { self.onToggle() }
                return true
            }
            return handled ? nil : event
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

struct VideoPlaybackKeys: NSViewRepresentable {
    let onToggle: () -> Void

    func makeNSView(context: Context) -> VideoPlaybackKeyView {
        let view = VideoPlaybackKeyView()
        view.onToggle = onToggle
        return view
    }

    func updateNSView(_ view: VideoPlaybackKeyView, context: Context) {
        view.onToggle = onToggle
    }
}
