import EdithExtensionSupport
import Foundation

enum KeystrokeHighlightSurface {
    static func snapshot(active: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "keystrokeHighlight",
            metrics: [.init("status", "Current state", active ? "On" : "Off")],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Turn off" : "Turn on",
                    "keyboard.badge.ellipsis")
            ], updatedAt: Date())
    }
}
