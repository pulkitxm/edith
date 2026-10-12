import EdithExtensionSupport
import Foundation

enum MicMuteSurface {
    static func snapshot(muted: Bool, error: String?) -> SurfaceSnapshot {
        .init(
            providerID: "micMute",
            rows: [
                .init(
                    "microphone", title: "Microphone", value: muted ? "Muted" : "Live",
                    icon: muted ? "mic.slash.fill" : "mic.fill")
            ],
            actions: [
                .init(
                    muted ? "unmute" : "mute", muted ? "Unmute" : "Mute",
                    muted ? "mic.fill" : "mic.slash.fill")
            ], message: error.map { String($0.prefix(2048)) })
    }
}
