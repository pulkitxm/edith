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
                snapshot(
                    preventingSleep: store.preventingSleep,
                    requested: defaults.bool(forKey: "preventSleep"))
            },
            perform: { action in
                defaults.set(action == "enable", forKey: "preventSleep")
                store.syncPreventSleep()
            })
    }

    static func snapshot(preventingSleep: Bool, requested: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "keepAwake",
            rows: [
                .init(
                    "awake", title: "Keep awake", value: preventingSleep ? "Awake" : "Off",
                    icon: "cup.and.saucer.fill")
            ],
            actions: [
                .init(
                    requested ? "disable" : "enable", requested ? "Allow sleep" : "Keep awake",
                    "power")
            ],
            message: requested && !preventingSleep ? "The system could not prevent sleep." : nil)
    }
}
