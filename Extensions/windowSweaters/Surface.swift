import EdithExtensionSupport
import Foundation

enum WindowSweatersSurface {
    static func snapshot(active: Bool, pattern: String) -> SurfaceSnapshot {
        .init(
            providerID: "windowSweaters",
            rows: [
                .init(
                    "sweaters", title: "Window Sweaters", detail: String(pattern.prefix(256)),
                    value: active ? "On" : "Off", icon: "rectangle.inset.filled")
            ],
            actions: [
                .init(
                    active ? "disable" : "enable", active ? "Hide sweaters" : "Show sweaters",
                    "rectangle.inset.filled")
            ])
    }
}
