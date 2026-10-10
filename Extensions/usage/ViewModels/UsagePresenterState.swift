import EdithExtensionSupport
import EdithExtensionUI
import Foundation
import Observation
import SwiftUI

@MainActor @Observable
final class UsagePresenterState {
    static let shared = UsagePresenterState()
    private let privacy: SurfacePrivacyState?
    private let client: UsageUIClient?

    init(channel: ExtensionSharedState? = .current, client: UsageUIClient? = nil) {
        self.client = client
        privacy =
            client == nil
            ? SurfacePrivacyState(
                channel: channel
                    ?? ExtensionSharedState(
                        root: ExtensionData.root.appendingPathComponent("State"),
                        namespace: "usage.fixture")) : nil
    }

    private var values: [String: String] {
        (client ?? UsageUIClient.current)?.presentationValues ?? privacy?.values ?? [:]
    }
    var active: Bool {
        if let client = client ?? UsageUIClient.current, client.presentationValues == nil {
            return true
        }
        return values["active"] == "1"
    }
    var money: Bool { values["blurMoney"].map { $0 != "0" } ?? true }
    var usage: Bool { values["blurUsage"].map { $0 != "0" } ?? false }
    func hides(_ category: String) -> Bool {
        active && (values["blur" + category].map { $0 != "0" } ?? true)
    }
    func shutdown() { privacy?.shutdown() }
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
        modifier(UsageCategoryPrivacy(category: category))
    }
}

private struct UsageCategoryPrivacy: ViewModifier {
    let category: UsagePrivacyCategory
    @Environment(\.usageUIClient) private var client
    func body(content: Content) -> some View {
        let key = category == .agents ? "Agents" : "Fleet"
        let hidden: Bool
        if let client {
            let values = client.presentationValues
            hidden = values == nil || (values?["active"] == "1" && values?["blur" + key] != "0")
        } else {
            hidden = UsagePresenterState.shared.hides(key)
        }
        return content.presenterBlur(hidden)
    }
}
