import EdithExtensionSupport
import Observation

@MainActor @Observable
final class MusicPrivacyState {
    static let shared = MusicPrivacyState()
    private let state = SurfacePrivacyState(
        channel: .current
            ?? ExtensionSharedState(
                root: ExtensionData.root.appendingPathComponent("shared-state"),
                namespace: "music.isolated"))
    var active: Bool { state.hides(.music) }
    func hides(_ widget: SurfaceWidget) -> Bool { state.hides(widget) }
    func shutdown() { state.shutdown() }
}
