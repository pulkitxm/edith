import EdithExtensionSupport
import Foundation

enum PresenterSurface {
    static func snapshot(_ state: PresenterRuntimeSnapshot) -> SurfaceSnapshot {
        .init(
            providerID: "presenter",
            rows: [
                .init(
                    "presenter", title: "Presenter",
                    detail: String((state.autoReason ?? "").prefix(256)),
                    value: state.active ? "Presenting" : "Off", icon: "person.crop.rectangle")
            ],
            actions: [
                .init(
                    state.active ? "stop" : "start",
                    state.active ? "Stop presenting" : "Start presenting", "person.crop.rectangle")
            ])
    }
}
