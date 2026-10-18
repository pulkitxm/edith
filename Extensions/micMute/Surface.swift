import EdithExtensionSupport
import Foundation

enum MicMuteSurface {
    static func snapshot(muted: Bool) -> SurfaceSnapshot {
        .init(
            providerID: "micMute",
            metrics: [.init("status", "Microphone", muted ? "Muted" : "On")],
            actions: [.init("toggle", "Toggle mute", "mic.slash")],
            updatedAt: Date())
    }
}
