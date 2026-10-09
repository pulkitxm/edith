import EdithExtensionSupport
import Foundation

enum KeepAwakeSurface {
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
