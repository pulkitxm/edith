import EdithExtensionSupport
import EdithExtensionUI
import Observation
import SwiftUI

@MainActor @Observable final class QuinjetPrivacy {
    static let shared = QuinjetPrivacy()
    private var state: SurfacePrivacyState?
    var hidesReview: Bool { state?.hides(.ability("quinjet")) ?? false }
    func start() {
        guard state == nil, let channel = ExtensionSharedState.current else { return }
        state = SurfacePrivacyState(channel: channel)
    }
    func shutdown() { state?.shutdown(); state = nil }
}

private struct TerminalLaunchEnabledKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var terminalLaunchEnabled: Bool {
        get { self[TerminalLaunchEnabledKey.self] }
        set { self[TerminalLaunchEnabledKey.self] = newValue }
    }
}
