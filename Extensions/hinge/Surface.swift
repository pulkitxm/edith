import EdithExtensionSupport
import Foundation

enum HingeSurface {
    static func snapshot(active: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "hinge",
            metrics: [.init("status", "Current state", active ? "On" : "Off")],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Turn off" : "Turn on",
                    .lidAwake)
            ], updatedAt: Date())
    }
}
