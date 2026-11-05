import EdithExtensionSupport
import Foundation

enum PresenterSurface {
    static func snapshot(_ state: PresenterRuntimeSnapshot) -> SurfaceSnapshot {
        .init(
            providerID: "presenter",
            metrics: [.init("status", "Current state", state.manual ? "On" : "Off")],
            actions: [
                .init(
                    state.manual ? "stop" : "start", state.manual ? "Turn off" : "Turn on",
                    .person)
            ], updatedAt: Date())
    }
}
