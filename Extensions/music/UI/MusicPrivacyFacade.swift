import EdithExtensionSupport
import Foundation
import Observation

@MainActor @Observable final class EmbeddedMusicPrivacyState {
    static let shared = EmbeddedMusicPrivacyState()
    var active = false
    func hides(_ widget: SurfaceWidget) -> Bool { active && widget == .music }
}
