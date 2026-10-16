import EdithExtensionSupport
import Foundation

enum KeepAwakeSurface {
    @MainActor
    static func execute(
        _ command: String, payload: Data, store: KeepAwakeStore, defaults: UserDefaults
    ) async throws -> Data {
        try await SurfaceCommandService.execute(
            providerID: "keepAwake", command: command, payload: payload,
            snapshot: { _ in
                snapshot(requested: defaults.bool(forKey: AppStorageKeys.General.preventSleep))
            },
            perform: { action in
                defaults.set(action == "enable", forKey: AppStorageKeys.General.preventSleep)
                store.syncPreventSleep()
            })
    }

    static func snapshot(requested: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "keepAwake",
            metrics: [.init("status", "Current state", requested ? "On" : "Off")],
            actions: [
                .init(
                    requested ? "disable" : "enable", requested ? "Turn off" : "Turn on",
                    "moon.zzz")
            ])
    }
}
