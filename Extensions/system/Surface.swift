import EdithExtensionSupport
import Foundation

enum SystemSurface {
    static func snapshot(apps: [RunningAppSnapshot], tile: SurfaceTile) -> SurfaceSnapshot {
        let rows: [SurfaceDataRow] =
            tile.widget == .actions
            ? []
            : apps.prefix(100).map {
                .init(
                    $0.pid.description, title: String($0.name.prefix(1024)),
                    detail: String(($0.bundleID ?? "").prefix(4096)),
                    value: $0.active ? "Frontmost" : "Running", icon: "app",
                    actions: [
                        .init("activate:" + $0.pid.description, "Open", "arrow.up.forward.app")
                    ])
            }
        return .init(
            providerID: "system", metrics: [.init("apps", "Running apps", apps.count.description)],
            rows: rows)
    }
}
