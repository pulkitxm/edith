import EdithExtensionSupport
import Foundation

enum KeystrokeHighlightSurface {
    static func snapshot(active: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "keystrokeHighlight",
            rows: [
                .init(
                    "keys", title: "Keystroke Highlight",
                    value: active ? "Showing keystrokes" : "Off", icon: "keyboard")
            ],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Hide keystrokes" : "Show keystrokes",
                    "keyboard")
            ])
    }
}
