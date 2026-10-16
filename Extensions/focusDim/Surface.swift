import EdithExtensionSupport
import Foundation

enum FocusDimSurface {
    static func snapshot(active: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "focusDim",
            metrics: [.init("status", "Current state", active ? "On" : "Off")],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Turn off" : "Turn on",
                    "circle.lefthalf.filled")
            ], updatedAt: Date())
    }
}
