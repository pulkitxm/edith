import EdithExtensionSupport
import Foundation

enum WindowSweatersSurface {
    static func snapshot(active: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "windowSweaters",
            metrics: [.init("status", "Current state", active ? "On" : "Off")],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Turn off" : "Turn on",
                    "square.dashed")
            ], updatedAt: Date())
    }
}
