import EdithExtensionSupport
import Foundation

enum FocusDimSurface {
    static func snapshot(active: Bool, intensity: Double) -> SurfaceSnapshot {
        .init(
            providerID: "focusDim",
            rows: [
                .init(
                    "dim", title: "Focus Dim",
                    detail: "Intensity " + Int(min(1, max(0, intensity)) * 100).description + "%",
                    value: active ? "Dimming" : "Off", icon: "circle.lefthalf.filled")
            ],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Stop dimming" : "Dim windows",
                    "circle.lefthalf.filled")
            ])
    }
}
