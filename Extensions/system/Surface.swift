import EdithExtensionSupport
import Foundation

enum SystemSurface {
    static func snapshot(
        apps: [RunningAppSnapshot], tile: SurfaceTile, cleaning: KeyboardCleaningStatus? = nil
    ) -> SurfaceSnapshot {
        let rows: [SurfaceDataRow] =
            tile.widget == .actions
            ? []
            : apps.prefix(100).map {
                .init(
                    $0.pid.description, title: String($0.name.prefix(1024)),
                    value: $0.active ? "Active" : "", icon: "app")
            }
        return .init(
            providerID: "system", metrics: [.init("apps", "Running apps", apps.count.description)],
            rows: rows,
            actions: cleaning.map {
                [
                    .init(
                        $0.phase == .idle ? "cleanKeys" : "stopCleaning",
                        $0.phase == .idle ? "Clean keys" : "Done cleaning", "keyboard")
                ]
            } ?? [])
    }
}
