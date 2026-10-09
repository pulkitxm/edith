import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class UsagePresenterState {
    static let shared = UsagePresenterState()
    private let privacy: SurfacePrivacyState

    init(channel: ExtensionSharedState? = .current) {
        privacy = SurfacePrivacyState(
            channel: channel
                ?? ExtensionSharedState(
                    root: ExtensionData.root.appendingPathComponent("State"),
                    namespace: "usage.fixture"))
    }

    var active: Bool { privacy.values["active"] == "1" }
    var money: Bool { privacy.values["blurMoney"].map { $0 != "0" } ?? true }
    var usage: Bool { privacy.values["blurUsage"].map { $0 != "0" } ?? false }
    func hides(_ category: String) -> Bool {
        active && (privacy.values["blur" + category].map { $0 != "0" } ?? true)
    }
    func shutdown() { privacy.shutdown() }
}

extension View {
    func presenterBlur(_ hidden: Bool) -> some View {
        blur(radius: hidden ? UIScale.pt(6) : 0).accessibilityHidden(hidden)
    }
}

enum UsagePrivacyCategory {
    case agents
    case fleet
}

extension View {
    func presenterBlur(_ category: UsagePrivacyCategory) -> some View {
        presenterBlur(UsagePresenterState.shared.hides(category == .agents ? "Agents" : "Fleet"))
    }
}
